import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// A CLINT validation payload for cores without trap machinery (the nano
/// tier): polls `mtime` over the bus and prints one 'T' per elapsed
/// [tickHz]-cycle interval, [ticks] times, then jumps back to the boot
/// monitor at [monitorBase] (which reprints its banner, a visible clean exit).
///
/// Elapsed time uses wrap-safe unsigned arithmetic on the low `mtime` word:
/// the loop spins while `(now - start) - delta` is negative, tested via the
/// sign bit (the DSL has only beq/bne, so ordering comparisons are built from
/// sub + srli).
///
/// Registers: x13 UART base, x12 mtime address, x10 tick start, x6 delta,
/// x7 scratch, x11/x14 UART scratch, x5 jump target.
class RiverTimerPollDemo extends Module {
  @override
  final RiscVIsaConfig isa;

  int _labelSeq = 0;

  RiverTimerPollDemo({
    required this.isa,
    required int uartBase,
    required int clintBase,
    int monitorBase = 0x00010000,
    int tickHz = 12000000,
    int ticks = 5,
  }) {
    final mtimeLo = clintBase + 0xBFF8;

    // Standalone UART re-init with the divisor HARDCODED for 115200 at a
    // 12MHz clock (12e6/115200 = 104). On the iCESugar this matches what the
    // monitor already set; a board at another clock should parametrize this
    // (or drop the re-init and rely on the monitor's configuration).
    register(Register.x13).bind(li(uartBase));
    register(Register.x11).bind(li(0x83));
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(104 & 0xff));
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(Register.x11).bind(li(0));
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03));
    sb(register(Register.x13), register(Register.x11), offset: 3);

    register(Register.x12).bind(li(mtimeLo));
    register(Register.x6).bind(li(tickHz));

    for (var t = 0; t < ticks; t++) {
      register(Register.x10).bind(lw(register(Register.x12))); // tick start
      final wait = label('wait$t');
      final now = lw(register(Register.x12));
      register(Register.x7).bind(sub(now, register(Register.x10)));
      register(
        Register.x7,
      ).bind(sub(register(Register.x7), register(Register.x6)));
      register(Register.x7).bind(srli(register(Register.x7), 31));
      bne(register(Register.x7), register(Register.x0), wait);
      _sendImm(0x54); // 'T'
    }
    _sendImm(0x0d);
    _sendImm(0x0a);

    // Hand control back to the boot monitor.
    register(Register.x5).bind(li(monitorBase));
    jalr(register(Register.x5));
  }

  /// Sends the immediate byte [ch]: poll LSR bit 5 (THRE), then write THR.
  void _sendImm(int ch) {
    final wait = label('txw${_labelSeq++}');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x14).bind(andi(lsr, 0x20));
    beq(register(Register.x14), register(Register.x0), wait);
    register(Register.x11).bind(li(ch));
    sb(register(Register.x13), register(Register.x11));
  }

  /// Raw machine code for loading via the serial monitor.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
