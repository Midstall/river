import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// The diagnostic twin of [RiverDdrTest]: same coverage (a full BL8 line,
/// a neighboring line, column/row/bank crossings, then a byte-merge), but
/// every readback is printed as hex instead of pass/fail, so a failing
/// region names itself. Expected output: C0DE0000/1111/.../7777, then
/// C0DE5500 (merged word) and 00000055 (lbu of the merged byte).
class RiverDdrSweepProbe extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDdrSweepProbe({
    required this.isa,
    required int uartBase,
    required int dramBase,
    int clockHz = 48000000,
    int baud = 115200,
  }) {
    final offsets = [0x0, 0x4, 0x8, 0xC, 0x10, 0x800, 0x100000, 0x4000000];
    int patternFor(int i) => 0xC0DE0000 + i * 0x1111;

    // ns16550a setup (the divisor gates the transmitter).
    final divisor = (clockHz ~/ baud).clamp(1, 0xffff);
    register(Register.x13).bind(li(uartBase));
    register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(divisor & 0xff)); // DLL
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(Register.x11).bind(li((divisor >> 8) & 0xff)); // DLM
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);

    for (var i = 0; i < offsets.length; i++) {
      register(Register.x10).bind(li(dramBase + offsets[i]));
      register(Register.x11).bind(li(patternFor(i)));
      sw(register(Register.x10), register(Register.x11));
    }
    for (var i = 0; i < offsets.length; i++) {
      register(Register.x10).bind(li(dramBase + offsets[i]));
      register(Register.x14).bind(lw(register(Register.x10)));
      _printHexX14();
      _crlf();
    }
    _crlf();

    // Sub-word lane map: sb 0x55 into each byte lane of four fresh words,
    // sh 0xBEEF into both halves of two more, print every merged word.
    // Expected: C0DE0055, C0DE5511, C0552222, 55DE3333, C0DEBEEF,
    // BEEF5555.
    for (var i = 0; i < 4; i++) {
      register(Register.x10).bind(li(dramBase + 0x40 + i * 4));
      register(Register.x11).bind(li(0xC0DE0000 + i * 0x1111));
      sw(register(Register.x10), register(Register.x11));
      register(Register.x11).bind(li(0x55));
      sb(register(Register.x10), register(Register.x11), offset: i);
      register(Register.x14).bind(lw(register(Register.x10)));
      _printHexX14();
      _crlf();
    }
    for (var i = 0; i < 2; i++) {
      register(Register.x10).bind(li(dramBase + 0x50 + i * 4));
      register(Register.x11).bind(li(0xC0DE0000 + (4 + i) * 0x1111));
      sw(register(Register.x10), register(Register.x11));
      register(Register.x11).bind(li(0xBEEF));
      sh(register(Register.x10), register(Register.x11), offset: i * 2);
      register(Register.x14).bind(lw(register(Register.x10)));
      _printHexX14();
      _crlf();
    }

    final done = label('done');
    jal(done);
  }

  /// Prints x14 as eight uppercase hex digits, MSB first.
  void _printHexX14() {
    register(Register.x17).bind(li(0x3A));
    register(Register.x18).bind(li(28));
    final nibble = label('nib');
    register(
      Register.x15,
    ).bind(srl(register(Register.x14), register(Register.x18)));
    register(Register.x15).bind(andi(register(Register.x15), 0xF));
    register(Register.x15).bind(addi(register(Register.x15), 0x30));
    final noAdjust = Label('noadj');
    blt(register(Register.x15), register(Register.x17), noAdjust);
    register(Register.x15).bind(addi(register(Register.x15), 7));
    placeLabel(noAdjust);
    final poll = label('p');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x16).bind(andi(lsr, 0x20));
    beq(register(Register.x16), register(Register.x0), poll);
    sb(register(Register.x13), register(Register.x15));
    register(Register.x18).bind(addi(register(Register.x18), -4));
    bge(register(Register.x18), register(Register.x0), nibble);
  }

  void _crlf() {
    for (final ch in const [0x0D, 0x0A]) {
      final poll = label('p');
      final lsr = lbu(register(Register.x13), offset: 5);
      register(Register.x16).bind(andi(lsr, 0x20));
      beq(register(Register.x16), register(Register.x0), poll);
      register(Register.x15).bind(li(ch));
      sb(register(Register.x13), register(Register.x15));
    }
  }

  /// Raw machine code for a monitor load frame.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
