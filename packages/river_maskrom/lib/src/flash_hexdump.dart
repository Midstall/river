import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// One flash window to hex-dump: [length] bytes read by lbu XIP starting at the
/// absolute [base], preceded by an optional [header] line (e.g. "FLASH @0:").
/// The [length] should be a multiple of 16 so the dump ends on a line boundary.
class HexdumpRegion {
  /// Absolute base address of the window (the flash XIP address to lbu from).
  final int base;

  /// How many bytes to dump from [base]. Multiple of 16 for a clean tail.
  final int length;

  /// Optional header line emitted (with CRLF) before this region's hex dump.
  final String? header;

  const HexdumpRegion({required this.base, required this.length, this.header});
}

/// A flash bring-up monitor: configures the ns16550a UART, then reads
/// [dumpBytes] from the SPI flash XIP region at [flashBase] and streams them as
/// a classic hex dump (`OOOOOOOO: HH HH ...`, offset then 16 bytes), then prints
/// `DUMP DONE\r\n` and spins. Proves the maskrom copied this image out of flash
/// to SRAM, the image executes from SRAM, and the flash XIP read path works.
///
/// UART writes poll the LSR THRE bit so the loop paces itself to the
/// transmitter. Position-independent (PC-relative control flow); only [flashBase]
/// and [uartBase] are absolute.
///
/// Register convention (monitor owns the machine, all caller-saved):
///   x13 = UART base           x14 = LSR scratch
///   x11 = byte scratch        x10 = flash read cursor (absolute)
///   x12 = flash end pointer   x15 = running flash offset (line label)
///   x16 = byte read from flash x17 = column counter (0..15) x18 = nibble scratch
///
/// A non-empty [regions] instead dumps each region in sequence with its
/// [HexdumpRegion.header] line: the multi-region diagnostic probe, running
/// entirely from ROM with no flash-write or maskrom-copy dependency.
class RiverFlashHexdump extends Module {
  @override
  final RiscVIsaConfig isa;

  /// Base of the SPI flash XIP region. The dump reads [dumpBytes] from here.
  /// Ignored when [regions] is non-empty.
  final int flashBase;

  /// How many flash bytes to dump (default 512 = 32 lines of 16). Ignored when
  /// [regions] is non-empty.
  final int dumpBytes;

  /// Bytes per hex-dump line.
  static const int bytesPerLine = 16;

  int _labelSeq = 0;

  RiverFlashHexdump({
    required this.isa,
    required int uartBase,
    this.flashBase = 0x20000000,
    this.dumpBytes = 512,
    int clockHz = 12000000,
    int baud = 115200,
    List<HexdumpRegion> regions = const [],
  }) {
    // Configure the ns16550a for 8N1 at the requested baud. Harbor's UART gates
    // its transmitter on a non-zero divisor (which resets to 0), so this setup
    // is mandatory on real hardware, not just cosmetic. Baud = clockHz/divisor.
    final divisor = (clockHz ~/ baud).clamp(1, 0xffff);
    register(Register.x13).bind(li(uartBase)); // UART base
    register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8 data bits, 1 stop
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(divisor & 0xff)); // DLL (divisor low)
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(
      Register.x11,
    ).bind(li((divisor >> 8) & 0xff)); // DLM (divisor high)
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, 8N1 (latch divisor)
    sb(register(Register.x13), register(Register.x11), offset: 3);

    // Dump every region in sequence. A single-region call (the classic
    // bring-up image) collapses to one synthesized region; a multi-region call
    // (the diagnostic probe) dumps each with its own header line.
    final dumpRegions = regions.isNotEmpty
        ? regions
        : [HexdumpRegion(base: flashBase, length: dumpBytes)];
    for (final region in dumpRegions) {
      _dumpRegion(region);
    }

    // Trailer: "DUMP DONE\r\n".
    for (final ch in 'DUMP DONE\r\n'.codeUnits) {
      _sendImm(ch);
    }

    // Done: spin forever.
    final done = label('done');
    jal(done);
  }

  /// Emits the hex dump of a single [region]: its optional header line first,
  /// then "OFFSET: HH HH ..\r\n" lines covering [HexdumpRegion.length] bytes
  /// read by lbu XIP from [HexdumpRegion.base].
  void _dumpRegion(HexdumpRegion region) {
    // Optional header line for this region, e.g. "FLASH @0:\r\n".
    if (region.header != null) {
      for (final ch in '${region.header}\r\n'.codeUnits) {
        _sendImm(ch);
      }
    }

    // Set up the dump cursors. x10 walks the flash, x12 marks the end, x15 is
    // the running offset (relative to the region base) used for the line label.
    register(Register.x10).bind(li(region.base)); // read cursor (absolute)
    register(Register.x12).bind(li(region.base + region.length)); // end
    register(Register.x15).bind(li(0)); // running offset

    // One line per 16 bytes.
    final lineLoop = label('line');
    // Print the 8-hex-digit offset of this line, then ": ".
    _sendHexWord(Register.x15);
    _sendImm(0x3a); // ':'
    _sendImm(0x20); // ' '

    // 16 bytes, space-separated.
    register(Register.x17).bind(li(0)); // column counter
    final byteLoop = label('byte');
    register(Register.x16).bind(lbu(register(Register.x10))); // flash[cursor]
    _sendHexByte(Register.x16);
    _sendImm(0x20); // ' '
    register(Register.x10).bind(addi(register(Register.x10), 1));
    register(Register.x17).bind(addi(register(Register.x17), 1));
    register(Register.x18).bind(li(bytesPerLine));
    bne(register(Register.x17), register(Register.x18), byteLoop);

    // End of line.
    _sendImm(0x0d); // '\r'
    _sendImm(0x0a); // '\n'

    // Advance the running offset and loop until the whole region is dumped.
    register(Register.x15).bind(addi(register(Register.x15), bytesPerLine));
    bne(register(Register.x10), register(Register.x12), lineLoop);
  }

  /// Polls LSR (offset 5) bit 5 (THRE), then writes x11 to THR (offset 0).
  void _sendX11() {
    final wait = label('txw${_labelSeq++}');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x14).bind(andi(lsr, 0x20));
    beq(register(Register.x14), register(Register.x0), wait);
    sb(register(Register.x13), register(Register.x11));
  }

  /// Sends the immediate byte [ch].
  void _sendImm(int ch) {
    register(Register.x11).bind(li(ch & 0xff));
    _sendX11();
  }

  /// Sends the low nibble of [value] (0..15) as an ASCII hex digit. Maps
  /// 0..9 -> '0'+n and 10..15 -> 'a'+(n-10). Uses x18 as scratch, clobbers x11.
  void _sendHexNibble(DataField value) {
    // ASCII hex digit, computed branchlessly so there is no two-writes-to-one-
    // register-across-a-branch pattern (the ADL's dead-store pass drops the
    // first write of such a pair, not seeing that a jump skips the second).
    //
    //   n         = value & 0xf
    //   ltTen     = (n < 10) ? 1 : 0          (slti)
    //   geTenMask = ltTen - 1                  (0 if n<10, 0xFFFF.. if n>=10)
    //   adj       = geTenMask & 0x27           (0 for digits, 0x27 for a-f)
    //   ascii     = n + 0x30 + adj             ('0'+n, or 'a'+(n-10))
    final n = andi(value, 0xf);
    register(Register.x18).bind(n);
    final ltTen = slti(register(Register.x18), 10);
    final geTenMask = addi(ltTen, -1);
    final adj = andi(geTenMask, 0x27);
    final base = addi(register(Register.x18), 0x30);
    register(Register.x11).bind(add(base, adj));
    _sendX11();
  }

  /// Sends the byte in register [reg] as two ASCII hex digits (high then low).
  void _sendHexByte(Register reg) {
    _sendHexNibble(srli(register(reg), 4)); // high nibble
    _sendHexNibble(register(reg)); // low nibble (masked inside)
  }

  /// Sends the low 32 bits of register [reg] as 8 ASCII hex digits, MSB first.
  void _sendHexWord(Register reg) {
    for (var shift = 28; shift >= 0; shift -= 4) {
      _sendHexNibble(srli(register(reg), shift));
    }
  }

  /// Raw machine code for baking into a boot ROM's init data.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());

  /// An ELF wrapping the program at [entryPoint], for the emulator/HDL sim.
  Uint8List emitElfBytes({required int entryPoint}) {
    final section = emitToSection(name: '.text', baseAddress: entryPoint);
    final writer = ElfWriter(
      entryPoint: entryPoint,
      elfClass: isa.mxlen == RiscVMxlen.rv64
          ? ElfWriterClass.elf64
          : ElfWriterClass.elf32,
    );
    writer.addSection(section, address: entryPoint);
    return Uint8List.fromList(writer.write());
  }
}
