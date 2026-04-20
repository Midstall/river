import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// A DDR diagnostic payload: after a printer self-test line (12345678), it
/// writes one BL8 line twice with different patterns and prints every
/// readback as hex.
///
/// Where [RiverDdrTest] only says pass/fail, the hex output names the
/// failure: readbacks that track the written pattern isolate the bug to
/// the read path (shifted half-words mean slot pairing or rdSlack, one
/// word repeated means beat select), while identical junk across both
/// passes means writes never reach the array at all.
class RiverDdrProbe extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDdrProbe({
    required this.isa,
    required int uartBase,
    required int dramBase,
    int clockHz = 48000000,
    int baud = 115200,
  }) {
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

    // Printer self-test: this line must read 12345678 on the terminal.
    register(Register.x14).bind(li(0x12345678));
    _printHexX14();
    _crlf();

    // Read-priming test. Hypothesis: the read rise beat (q0) mis-captures the
    // write->read turnaround on the FIRST read of an unprimed column, and a
    // prior read settles it. Write one word to a fresh line, then read it THREE
    // times in a row with NO writes between. If the readback converges to the
    // written 0xC1C10005, priming is the cure (-> controller issues a dummy read
    // or discards the first captured beat-pair). If all three stay wrong, the
    // capture is unconditionally broken for unprimed columns.
    register(Register.x10).bind(li(dramBase + 0x60));
    register(Register.x11).bind(li(0xC1C10005));
    sw(register(Register.x10), register(Register.x11));
    for (var i = 0; i < 3; i++) {
      register(Register.x14).bind(lw(register(Register.x10)));
      _printHexX14();
      _crlf();
    }
    _crlf();

    // Control: a DIFFERENT fresh line written full (4 words), read word 0 three
    // times. Expect 0xD3D30000 (or convergence) to compare partial vs full.
    for (var i = 0; i < 4; i++) {
      register(Register.x10).bind(li(dramBase + 0x70 + i * 4));
      register(Register.x11).bind(li(0xD3D30000 + i * 0x1111));
      sw(register(Register.x10), register(Register.x11));
    }
    register(Register.x10).bind(li(dramBase + 0x70));
    for (var i = 0; i < 3; i++) {
      register(Register.x14).bind(lw(register(Register.x10)));
      _printHexX14();
      _crlf();
    }
    _crlf();

    final done = label('done');
    jal(done);
  }

  /// Prints x14 as eight uppercase hex digits, MSB first. Loops over the
  /// shift amount in x18; x17 holds the '9'+1 threshold for the A-F
  /// adjustment.
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
