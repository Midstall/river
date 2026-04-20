import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// Boot-ROM diagnostic mirroring the bundled-flash boot (copy flash -> SRAM,
/// jump) but instrumented at every boundary so one boot localizes which layer
/// breaks when the real bundle is silent.
///
/// UART sequence:
///   "A\r\n"                 boot + UART alive
///   "F:\r\n" + 64-byte dump lbu XIP read from [flashSource]
///   "B\r\n"                 flash dump done (read path did not hang)
///   (copy [copyWords] words flash -> SRAM, exactly as the maskrom does)
///   "S:\r\n" + 64-byte dump read SRAM back: proves the copy landed
///   "C\r\n"                 copy done
///   "J\r\n"                 about to jalr into SRAM
///   <jumps to copyDest>     firmware takes over the UART here
///
/// Last thing seen localizes the break: no output = structural (PLL/reset/UART);
/// stall after "A" = flash read hangs; zero/garbage flash dump = flash-read lane
/// wrong on silicon; stall after "J" = the jalr into SRAM is broken.
///
/// All control flow is PC-relative; only [uartBase]/[flashSource]/[copyDest] are
/// absolute.
class RiverBundleSelfTest extends Module {
  @override
  final RiscVIsaConfig isa;

  /// Absolute flash XIP address the firmware lives at (flash base + offset).
  final int flashSource;

  /// Absolute SRAM address the maskrom copies into and jumps to.
  final int copyDest;

  /// Number of 32-bit words to copy (the maskrom's copySize / 4).
  final int copyWords;

  /// Bytes dumped from each window (flash and SRAM). Multiple of 16.
  final int probeBytes;

  int _labelSeq = 0;

  RiverBundleSelfTest({
    required this.isa,
    required int uartBase,
    required this.flashSource,
    required this.copyDest,
    required this.copyWords,
    this.probeBytes = 64,
    int clockHz = 12000000,
    int baud = 115200,
  }) {
    // Configure the ns16550a for 8N1 at the requested baud (mandatory on real
    // hardware: the UART gates TX on a non-zero divisor that resets to 0).
    final divisor = (clockHz ~/ baud).clamp(1, 0xffff);
    register(Register.x13).bind(li(uartBase));
    register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(divisor & 0xff));
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(Register.x11).bind(li((divisor >> 8) & 0xff));
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);

    _sendStr('A\r\n'); // boot + UART alive

    _sendStr('F:\r\n');
    _dumpWindow(flashSource, probeBytes); // flash read on silicon
    _sendStr('B\r\n');

    _copyWords(flashSource, copyDest, copyWords); // mirror the maskrom copy

    _sendStr('S:\r\n');
    _dumpWindow(copyDest, probeBytes); // copy landed real bytes?
    _sendStr('C\r\n');

    _sendStr('J\r\n');
    fence();
    register(Register.x5).bind(li(copyDest));
    jalr(register(Register.x5)); // run the firmware, exactly like the maskrom

    // Safety trap if the jump ever returns.
    final trap = label('trap');
    jal(trap);
  }

  /// Copy [nwords] words from flash [src] to SRAM [dst] via lw/sw, the exact
  /// word-aligned loop the maskrom runs (same flash-read lane path as the boot).
  void _copyWords(int src, int dst, int nwords) {
    // Single loop-carried pointer (x10); dst recomputed each iteration as
    // x10 + (dst - src). A separate `dst += 4` read only across the back-edge is
    // dropped by the non-loop-aware dead-code pass. Scratch avoids x13 (UART base
    // held by _send*); use x16 (delta) / x17 (dst) / x15 (word).
    register(Register.x10).bind(li(src));
    register(Register.x16).bind(li(dst - src));
    register(Register.x12).bind(li(src + nwords * 4));
    final loop = label('copy${_labelSeq++}');
    register(Register.x15).bind(lw(register(Register.x10)));
    register(
      Register.x17,
    ).bind(add(register(Register.x10), register(Register.x16)));
    sw(register(Register.x17), register(Register.x15));
    register(Register.x10).bind(addi(register(Register.x10), 4));
    bne(register(Register.x10), register(Register.x12), loop);
  }

  /// Hex-dump [length] bytes from absolute [base] via lbu: "OOOOOOOO: HH ..\r\n".
  void _dumpWindow(int base, int length) {
    register(Register.x10).bind(li(base)); // read cursor
    register(Register.x12).bind(li(base + length)); // end
    register(Register.x15).bind(li(0)); // running offset for the label
    final lineLoop = label('line${_labelSeq++}');
    _sendHexWord(Register.x15);
    _sendImm(0x3a); // ':'
    _sendImm(0x20); // ' '
    register(Register.x17).bind(li(0)); // column counter
    final byteLoop = label('byte${_labelSeq++}');
    register(Register.x16).bind(lbu(register(Register.x10)));
    _sendHexByte(Register.x16);
    _sendImm(0x20);
    register(Register.x10).bind(addi(register(Register.x10), 1));
    register(Register.x17).bind(addi(register(Register.x17), 1));
    register(Register.x18).bind(li(16));
    bne(register(Register.x17), register(Register.x18), byteLoop);
    _sendImm(0x0d);
    _sendImm(0x0a);
    register(Register.x15).bind(addi(register(Register.x15), 16));
    bne(register(Register.x10), register(Register.x12), lineLoop);
  }

  void _sendStr(String s) {
    for (final ch in s.codeUnits) {
      _sendImm(ch);
    }
  }

  /// Polls LSR (offset 5) bit 5 (THRE), then writes x11 to THR (offset 0).
  void _sendX11() {
    final wait = label('txw${_labelSeq++}');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x14).bind(andi(lsr, 0x20));
    beq(register(Register.x14), register(Register.x0), wait);
    sb(register(Register.x13), register(Register.x11));
  }

  void _sendImm(int ch) {
    register(Register.x11).bind(li(ch & 0xff));
    _sendX11();
  }

  /// Branchless nibble-to-ASCII (avoids the ADL dead-store-across-branch bug).
  void _sendHexNibble(DataField value) {
    final n = andi(value, 0xf);
    register(Register.x18).bind(n);
    final ltTen = slti(register(Register.x18), 10);
    final geTenMask = addi(ltTen, -1);
    final adj = andi(geTenMask, 0x27);
    final base = addi(register(Register.x18), 0x30);
    register(Register.x11).bind(add(base, adj));
    _sendX11();
  }

  void _sendHexByte(Register reg) {
    _sendHexNibble(srli(register(reg), 4));
    _sendHexNibble(register(reg));
  }

  void _sendHexWord(Register reg) {
    for (var shift = 28; shift >= 0; shift -= 4) {
      _sendHexNibble(srli(register(reg), shift));
    }
  }

  /// Raw machine code for baking into a boot ROM's init data.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
