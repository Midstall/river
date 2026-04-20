import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// Minimal DDR write-read-verify probe with plainly-readable output, so the DDR
/// state at a given clock is unambiguous. Output lines:
///   1. `DDRVERIFY 12345678` - UART/core liveness.
///   2. `ST <s0..s3>` - train-control STATUS (reg3) read 4x. Bit10 (0x400,
///      DLL_LOCK) set means the PHY DLL locked (init reached); 0 means the DDR
///      never calibrated (so all-zeros readback is just uninitialised DRAM).
///   3. `WREF ...` - the reference pattern.
///   4. `R <w0..w3>` x[iters] - fresh write, warm-up read, then readback per
///      pass. == pattern => works; all-zeros => write not landing; varying =>
///      marginal. Repeated to expose the error rate and consistency.
///   5. `RET <w0..w3>` - write, long delay, read (coarse retention/refresh hint).
///   6. `DONE`, then spin.
///
/// No STATUS busy-poll, so it can never hang on a flag that never fires.
/// Register discipline: printers clobber x14..x18 and read x13 (uartBase);
/// x4..x7 readback, x10 addr, x11 write value, x28/x29 loop scratch.
class RiverDdrVerify extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDdrVerify({
    required this.isa,
    required int uartBase,
    required int dramBase,
    required int trainCtrlBase,
    int clockHz = 48000000,
    int baud = 115200,
    int iters = 8,
  }) {
    final regStatus = trainCtrlBase + 0x18; // reg3 STATUS (read-only)

    // Four distinctive words (not 0, not all-equal, so zeros/garbage stand out).
    const p0 = 0xA5A5A5A5;
    const p1 = 0x5A5A5A5A;
    const p2 = 0xDEADBEEF;
    const p3 = 0xCAFEF00D;

    // ns16550a setup (x13 holds uartBase for the whole program).
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

    // 1. Liveness.
    _printStr('DDRVERIFY ');
    register(Register.x14).bind(li(0x12345678));
    _printHexX14();
    _crlf();

    // Give the DDR PHY init/DLL time to settle before we look at STATUS.
    _fixedDelay(200000);

    // 2. STATUS (reg3) read four times - DLL lock + valid/burst flags.
    _printStr('ST ');
    for (var i = 0; i < 4; i++) {
      register(Register.x10).bind(li(regStatus));
      register(Register.x14).bind(lw(register(Register.x10)));
      _printHexX14();
      _printChar(0x20);
    }
    _crlf();

    // 3. Reference pattern line.
    _printStr('WREF ');
    for (final w in const [p0, p1, p2, p3]) {
      register(Register.x14).bind(li(w));
      _printHexX14();
      _printChar(0x20);
    }
    _crlf();

    // 4. Write-read-verify loop.
    register(Register.x28).bind(li(iters)); // pass counter
    final loopTop = label('vtop');

    _writePattern(dramBase, p0, p1, p2, p3);
    _readAndPrint(dramBase, 'R ');

    register(Register.x28).bind(addi(register(Register.x28), -1));
    bne(register(Register.x28), register(Register.x0), loopTop);

    // 4b. Isolated mid-address write+read (word 64 = dramBase+0x100). A clean
    //     single access here plus a garbage post-bulk read at the same address
    //     (SMP below) pins corruption on the bulk WRITE STREAM, not the address.
    _writePattern(
      dramBase + 0x100,
      0x11110040,
      0x22220041,
      0x33330042,
      0x44440043,
    );
    _readAndPrint(dramBase + 0x100, 'M64 ');

    // 5. BULK STREAM: 4KB sequential write then two read-verify passes drive 512
    //    back-to-back two-beat dcache refills (the streaming path Weir hits that
    //    the single-word loop does not). word[i] = 0x0BAD0000|i. B0/B1 ERR=<n> =
    //    mismatch count per pass; 0 = clean, differing B0 vs B1 = transient.
    _bulkStream(dramBase, 1024);

    // 5b. Write-vs-read discriminator: a single low-rate read of mid-stream words
    //     64..67 (a fresh refill; the 4KB bulk evicted them from the dcache).
    //     Correct => the bulk write landed and the bulk READ is the bug; wrong =>
    //     the bulk WRITE corrupted the array.
    _readAndPrint(dramBase + 0x100, 'SMP ');

    // 5c. Address-bit walk: write a distinct value to dramBase+(1<<k) for
    //     k=2..24 and read each back; any bit that reads wrong is aliased
    //     (unwired/mis-mapped). Prints AWALK=<failmask> (bit k set => addr bit k
    //     broken) + A0=<dramBase+0 readback> to catch a low write aliasing onto 0.
    _addrWalk(dramBase);

    // 5d. N-sweep: write+verify n words for rising n (`N<n>=<err>`). Words 0..127
    //     are all bank0/row0 (bank = wordIndex[9:7]); word 128 enters bank1, 1024
    //     enters row1. Clean at n<=128 but broken at n=1024 => corruption crosses
    //     banks/rows; breaking at n<128 => a same-row count effect.
    _rangeCheck(dramBase, 8, 0x01110000, 'N8');
    _rangeCheck(dramBase, 32, 0x02220000, 'N32');
    _rangeCheck(dramBase, 64, 0x03330000, 'N64');
    _rangeCheck(dramBase, 128, 0x04440000, 'N128');
    _rangeCheck(dramBase, 256, 0x05550000, 'N256');
    _rangeCheck(dramBase, 512, 0x06660000, 'N512');

    // 5e. SRAM control: the same loop against on-chip SRAM (0x08000000, no DDR
    //     path). SRAM also wrong => the bug is the core store-address path (loop
    //     pointer); SRAM clean => the DDR genuinely aliases loop-addressed writes.
    _rangeCheck(0x08000000, 8, 0x07770000, 'SR8');
    _rangeCheck(0x08000000, 512, 0x08880000, 'SR512');

    // 6. Retention hint: write, long compute-only delay, then read.
    _writePattern(dramBase, p0, p1, p2, p3);
    _fixedDelay(4000000);
    _readAndPrint(dramBase, 'RET ');

    _printStr('DONE');
    _crlf();

    // Spin forever.
    final spin = label('spin');
    jal(spin);
  }

  /// Store the 4 words at dramBase+0/4/8/C. Uses x10 (addr), x11 (value).
  void _writePattern(int dramBase, int w0, int w1, int w2, int w3) {
    final words = [w0, w1, w2, w3];
    for (var i = 0; i < 4; i++) {
      register(Register.x10).bind(li(dramBase + i * 4));
      register(Register.x11).bind(li(words[i]));
      sw(register(Register.x10), register(Register.x11));
    }
  }

  /// Warm-up read then read the 4 words into x4..x7 and print `<prefix><w0..w3>`.
  void _readAndPrint(int dramBase, String prefix) {
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x14).bind(lw(register(Register.x10))); // warm-up
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x4).bind(lw(register(Register.x10)));
    register(Register.x10).bind(li(dramBase + 0x4));
    register(Register.x5).bind(lw(register(Register.x10)));
    register(Register.x10).bind(li(dramBase + 0x8));
    register(Register.x6).bind(lw(register(Register.x10)));
    register(Register.x10).bind(li(dramBase + 0xC));
    register(Register.x7).bind(lw(register(Register.x10)));
    _printStr(prefix);
    for (final r in const [
      Register.x4,
      Register.x5,
      Register.x6,
      Register.x7,
    ]) {
      register(Register.x14).bind(mv(register(r)));
      _printHexX14();
      _printChar(0x20);
    }
    _crlf();
  }

  /// Sequential 4-byte write of `n` words (word[i] = 0x0BAD0000|i) to dramBase,
  /// then two read-verify passes counting mismatches. Drives back-to-back dcache
  /// refills (the streaming path). x10 addr, x28 index, x29 limit, x20 err,
  /// x11 expected, x4 readback - all safe across the printers (x13..x18).
  void _bulkStream(int dramBase, int n) {
    // Write pass.
    register(Register.x10).bind(li(dramBase));
    register(Register.x28).bind(li(0));
    register(Register.x29).bind(li(n));
    final wl = label('bwl');
    register(Register.x11).bind(li(0x0BAD0000));
    register(
      Register.x11,
    ).bind(or(register(Register.x11), register(Register.x28)));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(addi(register(Register.x10), 4));
    register(Register.x28).bind(addi(register(Register.x28), 1));
    blt(register(Register.x28), register(Register.x29), wl);

    // Two read-verify passes.
    for (var pass = 0; pass < 2; pass++) {
      register(Register.x10).bind(li(dramBase));
      register(Register.x28).bind(li(0));
      register(Register.x20).bind(li(0)); // error count
      final rl = label('brl$pass');
      register(Register.x4).bind(lw(register(Register.x10)));
      register(Register.x11).bind(li(0x0BAD0000));
      register(
        Register.x11,
      ).bind(or(register(Register.x11), register(Register.x28)));
      final ok = Label('bok$pass');
      beq(register(Register.x4), register(Register.x11), ok);
      register(Register.x20).bind(addi(register(Register.x20), 1)); // mismatch
      placeLabel(ok);
      register(Register.x10).bind(addi(register(Register.x10), 4));
      register(Register.x28).bind(addi(register(Register.x28), 1));
      blt(register(Register.x28), register(Register.x29), rl);
      _printStr('B$pass ERR=');
      register(Register.x14).bind(mv(register(Register.x20)));
      _printHexX14();
      _crlf();
    }
  }

  /// Address-bit walk. Writes a distinct value to dramBase + (1<<k) for k in
  /// [2..24], reads each back, and builds a fail-mask of which one-hot address
  /// bits ALIAS (readback != written => that DRAM address bit is unwired /
  /// mis-mapped). Prints `A0=<v>` (the dramBase+0 sentinel readback - changes if
  /// a low write aliased onto it) then `AWALK=<mask>` (bit k set => addr bit k
  /// broken; 0 => all walked address bits are wired). x10 addr, x11 val, x28 k,
  /// x5 (1<<k) scratch, x4 readback, x20 mask, x6 limit - safe across printers.
  void _addrWalk(int dramBase) {
    const kLo = 2, kHi = 24;
    // Sentinel at dramBase+0 - a low write aliasing here shows up as A0 != this.
    register(Register.x10).bind(li(dramBase));
    register(Register.x11).bind(li(0x5EED0000));
    sw(register(Register.x10), register(Register.x11));

    // Write pass: [dramBase | (1<<k)] = 0x0CDE0000 | k.
    register(Register.x28).bind(li(kLo));
    register(Register.x6).bind(li(kHi + 1));
    final wl = label('aw_w');
    register(Register.x5).bind(li(1));
    register(
      Register.x5,
    ).bind(sll(register(Register.x5), register(Register.x28)));
    register(Register.x10).bind(li(dramBase));
    register(
      Register.x10,
    ).bind(or(register(Register.x10), register(Register.x5)));
    register(Register.x11).bind(li(0x0CDE0000));
    register(
      Register.x11,
    ).bind(or(register(Register.x11), register(Register.x28)));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x28).bind(addi(register(Register.x28), 1));
    blt(register(Register.x28), register(Register.x6), wl);

    // Read pass: fail-mask into x20.
    register(Register.x20).bind(li(0));
    register(Register.x28).bind(li(kLo));
    register(Register.x6).bind(li(kHi + 1));
    final rl = label('aw_r');
    register(Register.x5).bind(li(1));
    register(
      Register.x5,
    ).bind(sll(register(Register.x5), register(Register.x28)));
    register(Register.x10).bind(li(dramBase));
    register(
      Register.x10,
    ).bind(or(register(Register.x10), register(Register.x5)));
    register(Register.x4).bind(lw(register(Register.x10)));
    register(Register.x11).bind(li(0x0CDE0000));
    register(
      Register.x11,
    ).bind(or(register(Register.x11), register(Register.x28)));
    final ok = Label('aw_ok');
    beq(register(Register.x4), register(Register.x11), ok);
    // Mismatch: mask |= (1<<k).
    register(Register.x5).bind(li(1));
    register(
      Register.x5,
    ).bind(sll(register(Register.x5), register(Register.x28)));
    register(
      Register.x20,
    ).bind(or(register(Register.x20), register(Register.x5)));
    placeLabel(ok);
    register(Register.x28).bind(addi(register(Register.x28), 1));
    blt(register(Register.x28), register(Register.x6), rl);

    register(Register.x10).bind(li(dramBase));
    register(Register.x4).bind(lw(register(Register.x10)));
    _printStr('A0=');
    register(Register.x14).bind(mv(register(Register.x4)));
    _printHexX14();
    _crlf();
    _printStr('AWALK=');
    register(Register.x14).bind(mv(register(Register.x20)));
    _printHexX14();
    _crlf();
  }

  /// Write `n` words (word[i] = passBase|i) to dramBase (tight), verify (tight),
  /// print `<lbl>=<err>`. x10 addr, x28 idx, x29 limit, x20 err, x11 exp, x4 rd.
  void _rangeCheck(int dramBase, int n, int passBase, String lbl) {
    register(Register.x10).bind(li(dramBase));
    register(Register.x28).bind(li(0));
    register(Register.x29).bind(li(n));
    final wl = label('nw_$lbl');
    register(Register.x11).bind(li(passBase));
    register(
      Register.x11,
    ).bind(or(register(Register.x11), register(Register.x28)));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(addi(register(Register.x10), 4));
    register(Register.x28).bind(addi(register(Register.x28), 1));
    blt(register(Register.x28), register(Register.x29), wl);

    register(Register.x10).bind(li(dramBase));
    register(Register.x28).bind(li(0));
    register(Register.x20).bind(li(0));
    final rl = label('nr_$lbl');
    register(Register.x4).bind(lw(register(Register.x10)));
    register(Register.x11).bind(li(passBase));
    register(
      Register.x11,
    ).bind(or(register(Register.x11), register(Register.x28)));
    final ok = Label('nok_$lbl');
    beq(register(Register.x4), register(Register.x11), ok);
    register(Register.x20).bind(addi(register(Register.x20), 1));
    placeLabel(ok);
    register(Register.x10).bind(addi(register(Register.x10), 4));
    register(Register.x28).bind(addi(register(Register.x28), 1));
    blt(register(Register.x28), register(Register.x29), rl);
    _printStr('$lbl=');
    register(Register.x14).bind(mv(register(Register.x20)));
    _printHexX14();
    _crlf();
  }

  void _fixedDelay(int count) {
    register(Register.x22).bind(li(count));
    final delay = label('dly');
    register(Register.x22).bind(addi(register(Register.x22), -1));
    bne(register(Register.x22), register(Register.x0), delay);
  }

  /// Prints x14 as eight uppercase hex digits, MSB first. Clobbers x15..x18,
  /// reads x13 (uartBase) and x14 (the value).
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

  /// Transmits a single byte, polling the LSR THRE bit first.
  void _printChar(int ch) {
    final poll = label('p');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x16).bind(andi(lsr, 0x20));
    beq(register(Register.x16), register(Register.x0), poll);
    register(Register.x15).bind(li(ch));
    sb(register(Register.x13), register(Register.x15));
  }

  void _printStr(String s) {
    for (final ch in s.codeUnits) {
      _printChar(ch);
    }
  }

  void _crlf() {
    for (final ch in const [0x0D, 0x0A]) {
      _printChar(ch);
    }
  }

  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
