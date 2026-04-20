import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// DDR3 combined write-delay x read-setting leveling sweep firmware (creek
/// OrangeCrab). Tests whether any (write-DQS-delay, read-setting) combo makes a
/// write round-trip. If every pass shows SCANDONE0, no combo works and the
/// problem is analog.
///
/// Train-control registers (8-byte strided, decoded on bus[5:3], at
/// [trainCtrlBase] = dramBase + dramSize = 0x88000000 on creek):
///   reg0 +0x00 RDTAP      target (7-bit DELAYF read tap, 0..127)
///   reg1 +0x08 CTL        bit0 SET (load RDTAP target into the delay walk)
///   reg2 +0x10 RDSLACK    read-window slack cycles
///   reg4 +0x20 READCLKSEL 3-bit DQSBUFM read-gate select
///   reg7 +0x38 WRDLY      write-DQS delay, 4 bits PER LANE. Writing it latches
///                         the tap AND flips the apply toggle, so firmware then
///                         OWNS the write delay (overrides write-leveling).
///                         Both lanes set the same: value = (tap<<4)|tap.
/// DRAM array base = [dramBase] (0x80000000).
///
/// FOUR nested RUNTIME loops (body emitted once, no Dart unroll), 8*4*4*2 = 256:
///   WRDLY tap in 0..7                (OUTER, 8) - write reg7=(tap<<4)|tap
///   RDTAP in {0,32,64,96}            (4)        - write reg0 + pulse reg1 SET
///   READCLKSEL in {0,2,4,6}          (4)        - write reg4
///   RDSLACK in {2,4}                 (INNER, 2) - write reg2
/// Each register program is followed by a fixed-delay countdown, not a STATUS
/// busy-poll, so the sweep cannot hang on a flag that never fires.
///
/// Per combo: fresh write of three distinct words to the DRAM base
///   0x11112222 -> dramBase+0   0x33334444 -> dramBase+4   0x55556666 -> +8
/// a warm-up `lw`, then read back and compare all three (bne per word). First
/// match prints `HIT W<wrdly> R<rdtap> C<rcs> S<slk> V<rb0>`. Each pass ends
/// `SCANDONE<matchcount_hex>` then loops forever (UART-glitch tolerance).
///
/// The printer is INLINE (no subroutine): a subroutine-based printer streamed a
/// stuck constant on silicon. 12345678 prints first as a liveness check.
///
/// Register allocation (printer reads x13/x14, clobbers x15..x18):
///   x13 = uartBase   x14 = print value   x15..x18 = printer scratch
///   x10/x11/x12 = address/data scratch (printer never touches them)
///   x27 = WRDLY tap   x26 = RDTAP   x25 = READCLKSEL   x24 = RDSLACK (counters)
///   x4/x5/x6 = read-back words   x20 = match count   x21 = found flag
///   x22 = fixed-delay countdown scratch (separate from the counters)
class RiverDdrDiag extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDdrDiag({
    required this.isa,
    required int uartBase,
    required int dramBase,
    required int trainCtrlBase,
    int clockHz = 48000000,
    int baud = 115200,
  }) {
    // Train-control register addresses (8-byte strided, decoded on bus[5:3]).
    final regRdtap = trainCtrlBase + 0x00; // reg0 (7-bit DELAYF read tap)
    final regCtl = trainCtrlBase + 0x08; // reg1 (bit0 SET)
    final regRdslack = trainCtrlBase + 0x10; // reg2 (read-window slack)
    final regReadClkSel =
        trainCtrlBase + 0x20; // reg4 (3-bit DQS read-gate sel)
    final regWrDly = trainCtrlBase + 0x38; // reg7 (write-DQS delay, per lane)

    // The three distinct words written + checked at the DRAM base each combo.
    const w0 = 0x11112222;
    const w1 = 0x33334444;
    const w2 = 0x55556666;

    // Sweep extents (runtime, body emitted once). Counters STEP by the listed
    // increment and stop at the listed (exclusive) top:
    //   WRDLY      tap   0..7    step 1  top 8   -> 8 values
    //   RDTAP            0..96   step 32 top 128 -> {0,32,64,96}, 4 values
    //   READCLKSEL       0..6    step 2  top 8   -> {0,2,4,6},    4 values
    //   RDSLACK          2,4     step 2  top 6   -> {2,4},        2 values
    const wrdlyTop = 8;
    const rdtapStep = 32;
    const rdtapTop = 128;
    const rcsStep = 2;
    const rcsTop = 8;
    const slkStart = 2;
    const slkStep = 2;
    const slkTop = 6;

    // Fixed-delay countdown after each control-register program. No STATUS
    // busy-poll, so the sweep can never hang on a flag.
    const fixedDelay = 2000;

    // ns16550a setup (the divisor gates the transmitter). x13 holds uartBase for
    // the whole program (the inline hex/crlf printers read it).
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

    // 1. Liveness: this line must read 12345678 so we know the core is alive.
    //    Printed FIRST, via the INLINE printer, BEFORE any control access.
    register(Register.x14).bind(li(0x12345678));
    _printHexX14();
    _crlf();

    // Combined WRDLY x read-grid sweep. x27=WRDLY tap, x26=RDTAP, x25=READCLKSEL,
    // x24=RDSLACK, x4/x5/x6=read-back words, x20=match count, x21=found flag.
    final sweepTop = label('swtop');

    // Reset the per-pass trackers at the top of every pass.
    register(Register.x20).bind(li(0)); // match count
    register(Register.x21).bind(li(0)); // found flag

    // ---- WRDLY (OUTER) ----
    register(Register.x27).bind(li(0)); // WRDLY tap
    final wrdlyTopLbl = label('swwrdly');

    // Program reg7 WRDLY = (tap<<4)|tap (both lanes), then fixed delay.
    register(Register.x10).bind(li(regWrDly));
    register(
      Register.x11,
    ).bind(or(slli(register(Register.x27), 4), register(Register.x27)));
    sw(register(Register.x10), register(Register.x11));
    _fixedDelay(fixedDelay);

    // ---- RDTAP ----
    register(Register.x26).bind(li(0)); // RDTAP
    final rdtapTopLbl = label('swrdtap');

    // Program reg0 RDTAP target = x26, then pulse reg1 CTL bit0 SET to load the
    // delay walk. Then a FIXED delay (no STATUS busy-poll).
    register(Register.x10).bind(li(regRdtap));
    sw(register(Register.x10), register(Register.x26));
    register(Register.x10).bind(li(regCtl));
    register(Register.x11).bind(li(0x1)); // SET
    sw(register(Register.x10), register(Register.x11));
    _fixedDelay(fixedDelay);

    // ---- READCLKSEL ----
    register(Register.x25).bind(li(0)); // READCLKSEL
    final rcsTopLbl = label('swrcs');

    // Program reg4 READCLKSEL = x25. Then a FIXED delay.
    register(Register.x10).bind(li(regReadClkSel));
    sw(register(Register.x10), register(Register.x25));
    _fixedDelay(fixedDelay);

    // ---- RDSLACK (INNER) ----
    register(Register.x24).bind(li(slkStart)); // RDSLACK starts at 2
    final slkTopLbl = label('swslk');

    // Program reg2 RDSLACK = x24. Then a FIXED delay.
    register(Register.x10).bind(li(regRdslack));
    sw(register(Register.x10), register(Register.x24));
    _fixedDelay(fixedDelay);

    // FRESH WRITE of the three distinct words to the DRAM base (plain `sw`, the
    // same path ddrtest uses).
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x11).bind(li(w0));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0x4));
    register(Register.x11).bind(li(w1));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0x8));
    register(Register.x11).bind(li(w2));
    sw(register(Register.x10), register(Register.x11));

    // Warm-up read (absorb write->read turnaround), then read the three words
    // into x4..x6. Plain `lw` acks even on a bad eye (rdTimeout floor), no hang.
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x12).bind(lw(register(Register.x10))); // warm-up
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x4).bind(lw(register(Register.x10))); // rb0
    register(Register.x10).bind(li(dramBase + 0x4));
    register(Register.x5).bind(lw(register(Register.x10))); // rb1
    register(Register.x10).bind(li(dramBase + 0x8));
    register(Register.x6).bind(lw(register(Register.x10))); // rb2

    // MATCH = all three readback words equal. Any mismatch bne's to mFail,
    // skipping the hit handling.
    final mFail = label('swmfail');
    register(Register.x11).bind(li(w0));
    bne(register(Register.x4), register(Register.x11), mFail);
    register(Register.x11).bind(li(w1));
    bne(register(Register.x5), register(Register.x11), mFail);
    register(Register.x11).bind(li(w2));
    bne(register(Register.x6), register(Register.x11), mFail);

    // All three matched: count it, and on the first match print HIT with the
    // actual readback (x4 must read 11112222), then latch the found flag.
    register(
      Register.x20,
    ).bind(addi(register(Register.x20), 1)); // match count++
    final notFirst = label('swnotfirst');
    bne(
      register(Register.x21),
      register(Register.x0),
      notFirst,
    ); // already found
    register(Register.x21).bind(li(1)); // latch found
    _printStr('HIT W');
    register(Register.x14).bind(mv(register(Register.x27))); // WRDLY tap
    _printHexX14();
    _printStr(' R');
    register(Register.x14).bind(mv(register(Register.x26))); // RDTAP
    _printHexX14();
    _printStr(' C');
    register(Register.x14).bind(mv(register(Register.x25))); // READCLKSEL
    _printHexX14();
    _printStr(' S');
    register(Register.x14).bind(mv(register(Register.x24))); // RDSLACK
    _printHexX14();
    _printStr(' V');
    register(
      Register.x14,
    ).bind(mv(register(Register.x4))); // ACTUAL readback rb0
    _printHexX14();
    _crlf();
    placeLabel(notFirst);
    placeLabel(mFail);

    // ---- INNER step: RDSLACK += 2; repeat while < slkTop ({2,4}) ----
    register(Register.x24).bind(addi(register(Register.x24), slkStep));
    register(Register.x11).bind(li(slkTop));
    blt(register(Register.x24), register(Register.x11), slkTopLbl);

    // ---- READCLKSEL step: += 2; repeat while < rcsTop ({0,2,4,6}) ----
    register(Register.x25).bind(addi(register(Register.x25), rcsStep));
    register(Register.x11).bind(li(rcsTop));
    blt(register(Register.x25), register(Register.x11), rcsTopLbl);

    // ---- RDTAP step: += 32; repeat while < rdtapTop ({0,32,64,96}) ----
    register(Register.x26).bind(addi(register(Register.x26), rdtapStep));
    register(Register.x11).bind(li(rdtapTop));
    blt(register(Register.x26), register(Register.x11), rdtapTopLbl);

    // ---- WRDLY (OUTER) step: += 1; repeat while < wrdlyTop (0..7) ----
    register(Register.x27).bind(addi(register(Register.x27), 1));
    register(Register.x11).bind(li(wrdlyTop));
    blt(register(Register.x27), register(Register.x11), wrdlyTopLbl);

    // 3. End of pass: print SCANDONE<matchcount_hex>.
    _printStr('SCANDONE');
    register(Register.x14).bind(mv(register(Register.x20)));
    _printHexX14();
    _crlf();

    // 4. Loop forever (a fresh sweep streams each pass; FPGA reconfig eats the
    // first UART bytes, so streaming clean copies is the readable path).
    jal(sweepTop);
  }

  /// Fixed-delay countdown loop (no STATUS poll). Counts [count] down in x22,
  /// a dedicated register clear of the loop counters and printer registers.
  void _fixedDelay(int count) {
    register(Register.x22).bind(li(count));
    final delay = label('dly');
    register(Register.x22).bind(addi(register(Register.x22), -1));
    bne(register(Register.x22), register(Register.x0), delay);
  }

  /// Prints x14 as eight uppercase hex digits, MSB first. Inline at every
  /// callsite. Reads x13 (uartBase) and x14; clobbers x15..x18.
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

  /// Transmits an ASCII string byte by byte (immediates only, no data table).
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

  /// Raw machine code for a monitor load frame.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
