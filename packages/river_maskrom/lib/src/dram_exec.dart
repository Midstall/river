import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// Proves the core can FETCH AND EXECUTE from DRAM, not just load/store data
/// there. The other DRAM tests ([RiverDdrTest], [RiverDdrProbe]) only exercise
/// the data path; booting Weir is the first time PC ever enters DRAM (the FSBL
/// copies main to 0x80000000 and jumps), which this isolates.
///
/// Sequence: configure the UART, print "DEXEC\r\n" (boot ROM ran), copy
/// [stubBytes] (a position-independent print-and-spin stub, e.g. a built
/// [RiverHelloWorld] with `loop: true`) word by word into DRAM, then `jalr` to
/// it. Stub banner streams => fetch from DRAM works; dead after "DEXEC" => the
/// core cannot fetch from DRAM.
///
/// [stubBytes] must be already-built machine code (`await stub.build()` then
/// `stub.generateBinary()`); a Module's binary is empty until built.
class RiverDramExec extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDramExec({
    required this.isa,
    required int uartBase,
    required int dramBase,
    required List<int> stubBytes,
    int clockHz = 48000000,
    int baud = 115200,
  }) {
    // Pad to a whole number of 32-bit words.
    final words = <int>[];
    for (var i = 0; i < stubBytes.length; i += 4) {
      var w = 0;
      for (var b = 0; b < 4; b++) {
        if (i + b < stubBytes.length) w |= stubBytes[i + b] << (8 * b);
      }
      words.add(w & 0xffffffff);
    }

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

    // Marker: the boot ROM program reached the copy stage.
    _print('DEXEC\r\n');

    // Copy the stub into DRAM. Keep the destination base in x10 and use the sw
    // immediate offset (12-bit signed) for each word; chunk the base forward
    // every 256 words so the offsets never exceed the +2047 range.
    const chunk = 256;
    for (var start = 0; start < words.length; start += chunk) {
      register(Register.x10).bind(li(dramBase + start * 4));
      for (var i = start; i < words.length && i < start + chunk; i++) {
        register(Register.x11).bind(li(words[i]));
        sw(
          register(Register.x10),
          register(Register.x11),
          offset: (i - start) * 4,
        );
        // Progress marker every 8 words: emit '.' so the copy STREAMS its
        // progress on HW and we can see exactly which write it hangs on (the
        // count of dots x8 = the hang word index). x11/x10 are reloaded next
        // iteration; the marker only touches x13(uart)/x14/x15/x16.
        if ((i & 7) == 7) {
          final poll = label('cpoll$i');
          final lsr = lbu(register(Register.x13), offset: 5);
          register(Register.x16).bind(andi(lsr, 0x20));
          beq(register(Register.x16), register(Register.x0), poll);
          register(Register.x15).bind(li(0x2E)); // '.'
          sb(register(Register.x13), register(Register.x15));
          // Restore x10 base (the marker didn't touch it, but keep explicit).
          register(Register.x10).bind(li(dramBase + start * 4));
        }
      }
    }

    // Marker: the sustained-write COPY loop completed (isolates a copy/write hang
    // from a verify/read hang).
    _print('COPIED\r\n');

    // COPY-VERIFY (isolates DDR-read-corruption from the ifetch/CDC path): read
    // the copied stub back as data and compare. A mismatch => the DDR read
    // corrupted the code; all match => the code is correct in DRAM, so silence
    // after the jump is the instruction-fetch (CDC ifetch) path. Up to 64 words.
    final vN = words.length < 64 ? words.length : 64;
    for (var i = 0; i < vN; i++) {
      register(Register.x10).bind(li(dramBase + i * 4));
      register(Register.x14).bind(lw(register(Register.x10))); // readback
      register(Register.x11).bind(li(words[i])); // expected
      final good = label('cv$i');
      beq(register(Register.x14), register(Register.x11), good);
      // Report EVERY mismatch and CONTINUE (no spin) so we see the corruption
      // extent: only word0 (write->read turnaround) or all words.
      register(
        Register.x24,
      ).bind(addi(register(Register.x14), 0)); // save readback
      register(Register.x12).bind(li(i));
      _print('CB i=');
      _printHex(Register.x12);
      _print(' e=');
      register(Register.x25).bind(li(words[i]));
      _printHex(Register.x25);
      _print(' r=');
      _printHex(Register.x24);
      _print('\r\n');
      placeLabel(good);
    }
    _print('CVDONE\r\n');

    // Jump into DRAM. If the core can fetch from DRAM, the stub takes over and
    // streams "DRAM EXEC OK" forever.
    register(Register.x10).bind(li(dramBase));
    jalr(register(Register.x10));
  }

  /// Prints the low 32 bits of [reg] as 8 hex digits (clobbers x15..x18).
  void _printHex(Register reg) {
    register(Register.x14).bind(addi(register(reg), 0));
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
    final poll = label('hp');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x16).bind(andi(lsr, 0x20));
    beq(register(Register.x16), register(Register.x0), poll);
    sb(register(Register.x13), register(Register.x15));
    register(Register.x18).bind(addi(register(Register.x18), -4));
    bge(register(Register.x18), register(Register.x0), nibble);
  }

  /// THRE-polled UART print, one unrolled poll loop per byte.
  void _print(String message) {
    for (var i = 0; i < message.length; i++) {
      final poll = label('p');
      final lsr = lbu(register(Register.x13), offset: 5);
      register(Register.x14).bind(andi(lsr, 0x20));
      beq(register(Register.x14), register(Register.x0), poll);
      register(Register.x11).bind(li(message.codeUnitAt(i)));
      sb(register(Register.x13), register(Register.x11));
    }
  }

  /// Raw machine code for baking into a boot ROM's init data.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
