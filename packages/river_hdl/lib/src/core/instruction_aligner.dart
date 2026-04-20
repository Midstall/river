import 'package:rohd/rohd.dart';

/// Variable-length instruction aligner. Extracts up to two instructions per
/// cycle from a halfword window of the instruction stream, handling the RISC-V
/// "C" (compressed) extension where instructions are 2 or 4 bytes.
///
/// This is the core of a superscalar compressed front-end. Fixed-width dual
/// fetch assumes lane1.pc == lane0.pc + 4. With compressed code lane1.pc is
/// lane0.pc + lane0.size, and the size is only known after decoding lane0's
/// first halfword. The aligner resolves both instruction boundaries
/// combinationally from one buffered window, so each decode lane gets a
/// correctly sized instruction at the right PC.
///
/// Window model: `halves` is a little-endian pack of [laneCount] 16-bit
/// halfwords, halfword 0 being the lowest address (the current 2-byte-aligned
/// fetch PC). `validHalves` is how many of them hold real stream bytes (the rest
/// are past the fetched or redirect boundary). A 32-bit instruction takes two
/// consecutive halfwords, a compressed one takes one. Resolving two back-to-back
/// 4-byte instructions needs 4 halfwords, so [laneCount] must be >= 4.
class InstructionAligner extends Module {
  /// First (lane-0) instruction, its size in HALFWORDS (1=compressed, 2=32-bit),
  /// whether it is compressed, and whether it is fully present in the window.
  Logic get instr0 => output('instr0');
  Logic get size0 => output('size0'); // 1 or 2 (halfwords)
  Logic get compressed0 => output('compressed0');
  Logic get valid0 => output('valid0');

  /// Second (lane-1) instruction, the one starting at PC + size0*2.
  Logic get instr1 => output('instr1');
  Logic get size1 => output('size1');
  Logic get compressed1 => output('compressed1');
  Logic get valid1 => output('valid1');

  final int laneCount;

  InstructionAligner(
    Logic halves,
    Logic validHalves, {
    this.laneCount = 4,
    super.name = 'instruction_aligner',
  }) : super(definitionName: 'InstructionAligner') {
    assert(
      laneCount >= 4,
      'aligner needs >= 4 halfwords to resolve two 32-bit '
      'instructions (got $laneCount)',
    );
    final cntW = validHalves.width;
    halves = addInput('halves', halves, width: laneCount * 16);
    validHalves = addInput('valid_halves', validHalves, width: cntW);

    addOutput('instr0', width: 32);
    addOutput('size0', width: 2);
    addOutput('compressed0');
    addOutput('valid0');
    addOutput('instr1', width: 32);
    addOutput('size1', width: 2);
    addOutput('compressed1');
    addOutput('valid1');

    // Split the window into halfwords (hw[0] = lowest address).
    final hw = [
      for (var i = 0; i < laneCount; i++) halves.slice(16 * i + 15, 16 * i),
    ];

    Logic isComp(Logic half) => half.slice(1, 0).neq(0x3);
    // Select halfword[idx] from the window by a small constant-or-dynamic index.
    Logic hwAt(Logic idx) {
      Logic r = hw[0];
      for (var i = 1; i < laneCount; i++) {
        r = mux(idx.eq(Const(i, width: idx.width)), hw[i], r);
      }
      return r;
    }

    // Lane 0 starts at halfword 0. hasHw0 gates the size/compressed decode: with
    // no valid halfword, hw[0] is unfetched (X) so comp0/s0 are X. AND-ing the
    // guard first keeps v0 a clean 0 (0 & X == 0), never X, which matters because
    // v0 feeds a pipeline register that an X would poison.
    final hasHw0 = validHalves.gte(Const(1, width: cntW)).named('hasHw0');
    final comp0 = isComp(hw[0]).named('comp0');
    final i0 = mux(
      comp0,
      hw[0].zeroExtend(32),
      [hw[1], hw[0]].swizzle(),
    ).named('i0');
    final s0 = mux(comp0, Const(1, width: 2), Const(2, width: 2)).named('s0');
    // Fully present iff the first halfword is valid AND the window holds >= s0.
    final v0 = (hasHw0 & s0.zeroExtend(cntW).lte(validHalves)).named('v0');

    // Lane 1 starts at halfword s0 (1 or 2).
    final base1 = s0
        .zeroExtend(cntW)
        .named('base1'); // halfword index of instr1
    final lo1 = hwAt(base1).named('lo1');
    final hi1 = hwAt((base1 + 1).named('base1p1')).named('hi1');
    final comp1 = isComp(lo1).named('comp1');
    final i1 = mux(comp1, lo1.zeroExtend(32), [hi1, lo1].swizzle()).named('i1');
    final s1 = mux(comp1, Const(1, width: 2), Const(2, width: 2)).named('s1');
    // hasLo1 gates lane-1 decode the same way: comp1/s1 are only meaningful when
    // instr1's first halfword is inside the valid window (base1 < validHalves).
    // With lane 0 present and that guard, v1 stays a clean 0 when short.
    final hasLo1 = (v0 & base1.lt(validHalves)).named('hasLo1');
    final need1 = (base1 + s1.zeroExtend(cntW)).named('need1');
    final v1 = (hasLo1 & need1.lte(validHalves)).named('v1');

    instr0 <= i0;
    size0 <= s0;
    compressed0 <= comp0;
    valid0 <= v0;
    instr1 <= i1;
    size1 <= s1;
    compressed1 <= comp1;
    valid1 <= v1;
  }
}
