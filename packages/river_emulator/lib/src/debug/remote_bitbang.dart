import 'dart:async';
import 'dart:io';

import 'package:river/river.dart';

import '../core.dart';
import 'debug_module.dart';
import 'jtag_dtm.dart';

/// Adapts a [RiverCore] to the [DebugTarget] interface so the software Debug
/// Module can halt it and inspect its registers and memory.
class RiverDebugTarget implements DebugTarget, DebugHook {
  final RiverCore core;
  bool _halted = false;

  /// Debug PC. The run loop saves the hart's PC here when it halts and resumes
  /// from here, so a debugger that writes dpc (regno 0x7b1) redirects execution
  /// (the fuzzer sets it to each program's entry before resuming). These are
  /// Debug-Mode CSRs the normal CSR file does not hold.
  int dpc = 0;

  /// dcsr (0x7b0): debugver=4 (0.13.2), prv=3 (machine), cause set on halt.
  /// OpenOCD reads this during resume_prep (the "priv register") and writes the
  /// ebreak/step bits, so it must be a real readable/writable register.
  int _dcsr = 0x40000003;

  RiverDebugTarget(this.core) {
    // Let the core enter Debug Mode on an armed ebreak instead of trapping.
    core.debugHook = this;
  }

  @override
  bool get halted => _halted;

  @override
  bool ebreakEntersDebug(PrivilegeMode mode) {
    final bit = switch (mode) {
      PrivilegeMode.machine => 15, // dcsr.ebreakm
      PrivilegeMode.supervisor => 13, // dcsr.ebreaks
      PrivilegeMode.user => 12, // dcsr.ebreaku
    };
    return ((_dcsr >> bit) & 1) == 1;
  }

  @override
  void enterDebug(int dpcValue, int cause) {
    dpc = dpcValue;
    _halted = true;
    // Latch the halt cause (8:6) and force debugver; keep ebreak*/step config.
    _dcsr = (_dcsr & 0xFFFFFE3F) | ((cause & 0x7) << 6) | 0x40000000;
  }

  @override
  void requestHalt() {
    _halted = true;
    // Halt cause = 3 (haltreq); keep the other dcsr bits, force debugver.
    _dcsr = (_dcsr & 0xFFFFFE3F) | (3 << 6) | 0x40000000;
  }

  @override
  void requestResume() => _halted = false;

  @override
  int readGpr(int index) => core.xregs[Register.values[index]] ?? 0;

  @override
  void writeGpr(int index, int value) {
    if (index != 0) core.xregs[Register.values[index]] = value;
  }

  @override
  int readCsr(int address) {
    if (address == 0x7b1) return dpc; // dpc
    if (address == 0x7b0) return _dcsr; // dcsr
    return core.csrs.read(address, core);
  }

  @override
  void writeCsr(int address, int value) {
    if (address == 0x7b1) {
      dpc = value;
      return;
    }
    if (address == 0x7b0) {
      // debugver (31:28) is read-only (=4) and cause (8:6) is hardware-set;
      // force the former and preserve the latter on every write.
      _dcsr = (value & 0x0FFFFE3F) | 0x40000000 | (_dcsr & 0x000001C0);
      return;
    }
    core.csrs.write(address, value, core);
  }

  @override
  Future<int> readMem(int address, int size) =>
      core.mmu.read(address, size, pageTranslate: false);

  @override
  Future<void> writeMem(int address, int value, int size) =>
      core.mmu.write(address, value, size, pageTranslate: false);
}

/// An OpenOCD `remote_bitbang` protocol server. It speaks the same wire
/// protocol as a JTAG adapter, driving a software [SoftJtagDtm] (TAP + DTM) which
/// in turn reaches a [SoftDebugModule]. This lets OpenOCD, and therefore
/// Heimdall, connect to the emulator exactly as it would to silicon or the
/// HDL simulation, so the same verification flow validates all three.
///
/// OpenOCD config:
/// ```
/// adapter driver remote_bitbang
/// remote_bitbang host localhost
/// remote_bitbang port 44853
/// ```
///
/// Protocol bytes: `0`-`7` set {TCK,TMS,TDI}; `R` read TDO ('0'/'1'); `Q` quit;
/// `r`/`s`/`t`/`u` are (t)rst/(s)rst reset combos; `B`/`b` blink (ignored).
class RemoteBitbangServer {
  final SoftJtagDtm dtm;
  final int port;

  ServerSocket? _server;
  Socket? _client;
  bool _running = false;
  int _prevTck = 0;

  static const defaultPort = 44853;

  RemoteBitbangServer(this.dtm, {this.port = defaultPort});

  /// The actual bound port (useful when constructed with `port: 0`).
  int? get boundPort => _server?.port;

  /// Bind the listening socket. Call before [serve] so [boundPort] is known.
  Future<void> bind() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _running = true;
  }

  /// Bind (if needed) and serve until [stop]. Typically started with
  /// `unawaited`.
  Future<void> start() async {
    if (_server == null) await bind();
    await serve();
  }

  /// Accept and handle clients until [stop]. Requires [bind] first.
  Future<void> serve() async {
    await for (final client in _server!) {
      if (!_running) break;
      _client = client;
      client.setOption(SocketOption.tcpNoDelay, true);
      // A write that races with the peer (OpenOCD) disconnecting surfaces its
      // error asynchronously on the socket's done future, not at the add() call
      // site. With no handler it becomes an unhandled async error that tears
      // down the whole isolate, so a debugger reconnecting between fuzz
      // iterations crashes the emulator. Absorb it here so the server just
      // moves on to the next connection.
      unawaited(client.done.catchError((Object _) => client));
      try {
        await _handle(client);
      } catch (_) {
        // Drop the connection on any protocol/IO error; keep serving.
      }
      try {
        await client.close();
      } catch (_) {
        // Already gone; nothing to clean up.
      }
      _client = null;
    }
  }

  Future<void> stop() async {
    _running = false;
    await _client?.close();
    await _server?.close();
    _server = null;
    _client = null;
  }

  Future<void> _handle(Socket client) async {
    await for (final data in client) {
      if (!_running) break;
      for (final byte in data) {
        if (byte >= 0x30 && byte <= 0x37) {
          // '0'-'7': {TCK,TMS,TDI}. Clock the TAP on a TCK rising edge.
          final v = byte - 0x30;
          final tck = (v >> 2) & 1;
          final tms = (v >> 1) & 1;
          final tdi = v & 1;
          if (tck == 1 && _prevTck == 0) await dtm.clock(tms, tdi);
          _prevTck = tck;
        } else if (byte == 0x52) {
          // 'R': read TDO. Guard the write: if the peer has already gone the
          // add() can fail, and we drop this connection so serve() accepts the
          // next one instead of letting the error escape.
          try {
            client.add([dtm.tdo == 1 ? 0x31 : 0x30]);
          } catch (_) {
            return;
          }
        } else if (byte == 0x74 || byte == 0x75) {
          // 't'/'u': TRST asserted -> reset the TAP.
          dtm.reset();
        } else if (byte == 0x51) {
          // 'Q': quit
          await client.close();
          return;
        }
        // 'r','s','B','b' and others: no-op.
      }
    }
  }
}

/// Build and start a remote-bitbang debug server for [core] on [port].
/// Returns the server (already listening in the background).
Future<RemoteBitbangServer> startRiverDebugServer(
  RiverCore core, {
  int port = RemoteBitbangServer.defaultPort,
  int idcode = 0x10000001,
}) async {
  final dm = SoftDebugModule(RiverDebugTarget(core));
  final dtm = SoftJtagDtm(dm, idcode: idcode);
  final server = RemoteBitbangServer(dtm, port: port);
  await server.bind(); // so boundPort is available immediately
  unawaited(server.serve());
  return server;
}
