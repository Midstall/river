import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// A serial boot monitor for SRAM-class systems: the development workflow
/// for boards where re-synthesizing the bitstream per program is too slow.
///
/// On boot it configures the ns16550a, prints [banner], then loops:
///
///   host -> board: len_lo len_hi payload[len] checksum
///   board -> host: 'K' on a checksum match (then jumps to the payload at
///                  [ramBase]), 'E' on a mismatch (then waits again)
///
/// The checksum is the byte-sum of the payload, modulo 256. A length of zero
/// is a no-op (useful for resynchronizing). The monitor jumps into the loaded
/// program, and a program that wants the monitor back jumps to the boot ROM
/// base (the monitor re-initializes everything on entry).
///
/// Register convention (all caller-saved, the monitor owns the machine):
/// x13 = UART base, x10 = write cursor, x11 = byte scratch, x12 = length,
/// x14 = LSR scratch, x15 = running checksum, x6 = end pointer, x5 = jump
/// target.
class RiverSerialMonitor extends Module {
  @override
  final RiscVIsaConfig isa;

  /// Banner printed once at boot.
  final String banner;

  int _labelSeq = 0;

  RiverSerialMonitor({
    required this.isa,
    required int uartBase,
    required int ramBase,
    int clockHz = 12000000,
    int baud = 115200,
    this.banner = 'River boot\r\n',
  }) {
    // Configure the ns16550a for 8N1 at the requested baud (the transmitter
    // and receiver are both gated on a non-zero divisor).
    final divisor = (clockHz ~/ baud).clamp(1, 0xffff);
    register(Register.x13).bind(li(uartBase));
    register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(divisor & 0xff)); // DLL
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(Register.x11).bind(li((divisor >> 8) & 0xff)); // DLM
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, latch divisor
    sb(register(Register.x13), register(Register.x11), offset: 3);

    for (final ch in banner.codeUnits) {
      _sendImm(ch);
    }

    final mainLoop = label('main');

    // Length, little endian. A zero length resynchronizes.
    _recvByte(); // x11 = len_lo
    register(Register.x12).bind(andi(register(Register.x11), 0xff));
    _recvByte(); // x11 = len_hi
    register(
      Register.x12,
    ).bind(or(register(Register.x12), slli(register(Register.x11), 8)));
    beq(register(Register.x12), register(Register.x0), mainLoop);

    // Payload: write to RAM, summing as we go.
    register(Register.x10).bind(li(ramBase));
    register(Register.x15).bind(li(0));
    register(
      Register.x6,
    ).bind(add(register(Register.x10), register(Register.x12)));
    final payloadLoop = label('payload');
    _recvByte();
    sb(register(Register.x10), register(Register.x11));
    register(
      Register.x15,
    ).bind(add(register(Register.x15), register(Register.x11)));
    register(Register.x10).bind(addi(register(Register.x10), 1));
    bne(register(Register.x10), register(Register.x6), payloadLoop);

    // Checksum byte, then verdict.
    _recvByte();
    register(Register.x15).bind(andi(register(Register.x15), 0xff));
    final fail = Label('fail');
    bne(register(Register.x11), register(Register.x15), fail);
    _sendImm(0x4B); // 'K'
    register(Register.x5).bind(li(ramBase));
    jalr(register(Register.x5));

    placeLabel(fail);
    _sendImm(0x45); // 'E'
    jal(mainLoop);
  }

  /// Receives one byte into x11: poll LSR (offset 5) bit 0 (data ready),
  /// then read RBR (offset 0).
  void _recvByte() {
    final wait = label('rxw${_labelSeq++}');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x14).bind(andi(lsr, 0x01));
    beq(register(Register.x14), register(Register.x0), wait);
    register(Register.x11).bind(lbu(register(Register.x13)));
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

  /// Raw machine code for baking into a boot ROM's init data.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
