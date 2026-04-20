import 'dart:async';
import 'dart:io';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// Drives the software JTAG TAP exactly as a JTAG adapter would, so the whole
/// chain (TAP -> DTM -> Debug Module -> RiverCore) is exercised end-to-end.
class JtagHost {
  final SoftJtagDtm dtm;
  JtagHost(this.dtm);

  Future<void> _clk(int tms, [int tdi = 0]) => dtm.clock(tms, tdi);

  Future<void> resetTap() async {
    for (var i = 0; i < 5; i++) {
      await _clk(1); // -> Test-Logic-Reset
    }
    await _clk(0); // -> Run-Test/Idle
  }

  /// Scan [bits] bits through the selected DR, returning the captured value.
  Future<int> scanDr(int bits, int value) async {
    await _clk(1); // Run-Test/Idle -> Select-DR
    await _clk(0); // -> Capture-DR (loads DR)
    await _clk(0); // -> Shift-DR
    var captured = 0;
    for (var i = 0; i < bits; i++) {
      final last = i == bits - 1;
      // Sample TDO while TCK is low, before the rising edge shifts the next bit
      // out (the OpenOCD remote_bitbang convention the combinational `tdo`
      // getter models). Reading after `_clk` would capture one bit too late.
      if (dtm.tdo == 1) captured |= 1 << i;
      await _clk(last ? 1 : 0, (value >> i) & 1);
    }
    await _clk(1); // Exit1-DR -> Update-DR (performs the access)
    await _clk(0); // -> Run-Test/Idle
    return captured;
  }

  Future<int> scanIr(int bits, int value) async {
    await _clk(1); // -> Select-DR
    await _clk(1); // -> Select-IR
    await _clk(0); // -> Capture-IR
    await _clk(0); // -> Shift-IR
    var captured = 0;
    for (var i = 0; i < bits; i++) {
      final last = i == bits - 1;
      // Sample TDO while TCK is low, before the rising edge (see scanDr).
      if (dtm.tdo == 1) captured |= 1 << i;
      await _clk(last ? 1 : 0, (value >> i) & 1);
    }
    await _clk(1); // -> Update-IR
    await _clk(0); // -> Run-Test/Idle
    return captured;
  }

  // DMI helpers (assume IR already == DMI 0x11). op: 1=read, 2=write.
  Future<void> dmWrite(int addr, int data) =>
      scanDr(41, (addr << 34) | ((data & 0xFFFFFFFF) << 2) | 2);

  Future<int> dmRead(int addr) async {
    await scanDr(41, (addr << 34) | 1); // issue read
    final captured = await scanDr(41, 0); // nop scan captures the result
    return (captured >> 2) & 0xFFFFFFFF;
  }
}

void main() {
  HarborMmuConfig mmu(RiscVMxlen x) => HarborMmuConfig(
    mxlen: x,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  );
  const clk = HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(10000),
  );

  RiverCore makeCore() {
    final sram = Sram(
      RiverDevice(
        name: 'sram',
        compatible: 'river,sram',
        range: BusAddressRange(0, 0xFFFF),
        clockFrequency: 10000,
      ),
    );
    final core = RiverCore(
      RiverCoreConfig(
        mxlen: RiscVMxlen.rv64,
        extensions: kRva23S64Extensions,
        type: RiverCoreType.general,
        mmu: mmu(RiscVMxlen.rv64),
        interrupts: [],
        clock: clk,
      ),
      memDevices: Map.fromEntries([sram.mem!]),
    );
    core.reset();
    return core;
  }

  group('remote bitbang debug (TAP/DTM/DM chain)', () {
    late RiverCore core;
    late RiverDebugTarget tgt;
    late SoftJtagDtm dtm;
    late JtagHost host;

    setUp(() {
      core = makeCore();
      tgt = RiverDebugTarget(core);
      dtm = SoftJtagDtm(SoftDebugModule(tgt), idcode: 0xDEADBEE3);
      host = JtagHost(dtm);
    });

    test('reads IDCODE', () async {
      await host.resetTap();
      expect(await host.scanDr(32, 0), 0xDEADBEE3);
    });

    test('dmstatus reports version and halt state; halt works', () async {
      await host.resetTap();
      await host.scanIr(5, 0x11); // select DMI

      var dmstatus = await host.dmRead(0x11);
      expect(dmstatus & 0xF, 2); // debug spec version 0.13.2
      expect((dmstatus >> 9) & 1, 0); // allhalted == 0 (running)

      await host.dmWrite(0x10, (1 << 31) | 1); // dmcontrol: haltreq | dmactive
      expect(tgt.halted, isTrue);
      dmstatus = await host.dmRead(0x11);
      expect((dmstatus >> 9) & 1, 1); // allhalted

      await host.dmWrite(0x10, (1 << 30) | 1); // resumereq | dmactive
      expect(tgt.halted, isFalse);
    });

    test('GPR write/read via abstract command', () async {
      await host.resetTap();
      await host.scanIr(5, 0x11);

      // data0 = 0x12345678 ; command = access-register, write, 32-bit, x6
      await host.dmWrite(0x04, 0x12345678);
      await host.dmWrite(0x17, (2 << 20) | (1 << 17) | (1 << 16) | 0x1006);
      expect(core.xregs[Register.x6], 0x12345678);

      // read it back into data0
      await host.dmWrite(0x17, (2 << 20) | (1 << 17) | 0x1006);
      expect(await host.dmRead(0x04), 0x12345678);
    });

    test('memory write/read via system bus', () async {
      await host.resetTap();
      await host.scanIr(5, 0x11);

      // Default sbcs selects 32-bit access. Write then read 0x2000.
      await host.dmWrite(0x39, 0x2000); // sbaddress0
      await host.dmWrite(0x3c, 0xCAFEBABE); // sbdata0 -> store
      expect(await core.mmu.read(0x2000, 4, pageTranslate: false), 0xCAFEBABE);

      // sbreadonaddr: writing sbaddress0 triggers a read into sbdata0.
      final sbcs = await host.dmRead(0x38);
      await host.dmWrite(0x38, sbcs | (1 << 20));
      await host.dmWrite(0x39, 0x2000);
      expect(await host.dmRead(0x3c), 0xCAFEBABE);
    });

    test('64-bit system-bus access combines sbdata0 + sbdata1', () async {
      await host.resetTap();
      await host.scanIr(5, 0x11);

      // Select 64-bit access (sbaccess=3). A debugger downloading a 64-bit
      // image writes sbdata1 (high) then sbdata0 (low, which triggers the
      // write). If the DM only stored sbdata0 the high word would be zeroed,
      // corrupting every other 32-bit word of the image (the bug that desynced
      // the fuzz DUT's instruction fetch).
      await host.dmWrite(0x38, 3 << 17); // sbcs.sbaccess = 3 (64-bit)
      await host.dmWrite(0x39, 0x3000); // sbaddress0
      await host.dmWrite(0x3d, 0xCAFEBABE); // sbdata1 (high 32)
      await host.dmWrite(
        0x3c,
        0xDEADBEEF,
      ); // sbdata0 (low 32) -> writes 8 bytes

      expect(
        await core.mmu.read(0x3000, 8, pageTranslate: false),
        0xCAFEBABEDEADBEEF,
      );
      // The high word must be present, not zero (the pre-fix failure mode).
      expect(await core.mmu.read(0x3004, 4, pageTranslate: false), 0xCAFEBABE);
    });

    test('ebreak enters debug halt when dcsr.ebreakm is armed', () async {
      // Arm ebreakm so an ebreak in machine mode halts into Debug Mode instead
      // of trapping to mtvec (the bug differential fuzzing surfaced: with
      // mtvec=entry the breakpoint trap looped back into the program forever).
      tgt.writeCsr(0x7b0, 1 << 15); // dcsr.ebreakm = 1

      // Program at 0x200: addi a0, x0, 42 ; ebreak
      await tgt.writeMem(0x200, 0x02A00513, 4); // addi a0,x0,42
      await tgt.writeMem(0x204, 0x00100073, 4); // ebreak

      var pc = 0x200;
      var steps = 0;
      while (!tgt.halted && steps < 20) {
        pc = await core.runPipeline(pc);
        steps++;
      }

      expect(tgt.halted, isTrue, reason: 'ebreak should halt into Debug Mode');
      expect(tgt.dpc, 0x204, reason: 'dpc = address of the ebreak');
      expect(
        core.xregs[Register.x10],
        42,
        reason: 'body executed before ebreak',
      );
      expect((tgt.readCsr(0x7b0) >> 6) & 0x7, 1, reason: 'dcsr.cause = ebreak');
    });

    test('ebreak without ebreakm armed does NOT debug-halt', () async {
      // dcsr defaults with ebreakm clear; an ebreak must trap (to mtvec), not
      // enter Debug Mode. With mtvec=0 that trap double-faults and throws, which
      // is exactly the non-halt path we are asserting.
      await tgt.writeMem(0x200, 0x00100073, 4); // ebreak
      try {
        await core.runPipeline(0x200);
      } catch (_) {
        // Expected: breakpoint trap -> mtvec=0 -> double fault. NOT a debug halt.
      }
      expect(
        tgt.halted,
        isFalse,
        reason: 'ebreak must not halt when dcsr.ebreakm is clear',
      );
    });

    test('sbcs write preserves read-only capability bits', () async {
      await host.resetTap();
      await host.scanIr(5, 0x11);

      // A debugger writes sbcs to pick an access size; its write carries the
      // read-only capability fields as zero. Those must survive, or a later
      // reconnect reads sbcs back, sees no supported access size, and abandons
      // the system bus (the iteration-1 "unsupported size" memory-write bug).
      const roMask =
          0xE0000FFF; // sbversion[31:29] | sbasize[11:5] | sbaccessN[4:0]
      final before = await host.dmRead(0x38);
      await host.dmWrite(
        0x38,
        (2 << 17) | (1 << 16),
      ); // sbaccess=2, autoincrement
      final after = await host.dmRead(0x38);
      expect(after & roMask, before & roMask); // caps unchanged
      expect((after >> 17) & 0x7, 2); // control field took the write
    });
  });

  test('IDCODE read over the remote_bitbang TCP protocol', () async {
    final core = makeCore();
    final server = await startRiverDebugServer(
      core,
      port: 0,
      idcode: 0xDEADBEE3,
    );
    // port:0 asks the OS for a free port; read it back.
    final port = server.boundPort!;

    final out = <int>[];
    void clk(int tms, int tdi, {bool read = false}) {
      final v = (tms << 1) | tdi;
      out.add(0x30 | v); // tck=0
      // Read TDO while TCK is low, before the rising edge (the OpenOCD
      // convention the combinational `tdo` getter models).
      if (read) out.add(0x52); // 'R'
      out.add(0x30 | (4 | v)); // tck=1 (rising edge shifts)
    }

    for (var i = 0; i < 5; i++) {
      clk(1, 0); // reset
    }
    clk(0, 0); // Run-Test/Idle
    clk(1, 0);
    clk(0, 0);
    clk(0, 0); // -> Shift-DR (IR defaults to IDCODE)
    for (var i = 0; i < 32; i++) {
      clk(i == 31 ? 1 : 0, 0, read: true);
    }
    clk(1, 0);
    clk(0, 0); // Update-DR, Idle
    out.add(0x51); // 'Q'

    final sock = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final resp = <int>[];
    final done = Completer<void>();
    sock.listen(
      resp.addAll,
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    sock.add(out);
    await sock.flush();
    await done.future.timeout(const Duration(seconds: 3));

    var idcode = 0;
    for (var i = 0; i < 32; i++) {
      if (resp[i] == 0x31) idcode |= 1 << i;
    }
    expect(idcode, 0xDEADBEE3);
    await server.stop();
  });
}
