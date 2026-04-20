import 'package:rohd/rohd.dart';

/// Shared multi-cycle unsigned integer multiplier (radix-2^[radix] shift-add).
///
/// One multiply in flight at a time, matching the in-order exec unit: a mul/mulh*
/// mop parks the pipeline at its mopStep and waits for [done]. Replaces the
/// single-cycle 64x64 multiply whose partial-product reduction tree costs
/// thousands of LUT4s on small FPGAs. Here one small [width]x[radix] multiply (a
/// couple of MULT18X18D tiles) is reused across cycles, leaving one chunk-multiply
/// plus one accumulate-add per cycle.
///
/// Both operands unsigned; the full 2*[width]-bit product is on [product]. The
/// caller handles signed/MULH/MULHSU/MULHU/MULW via two sign-correction subtracts.
///
/// Algorithm (radix-2^[radix] right-shifting accumulator shift-add): process
/// multiplier b [radix] bits at a time from the LSB. State is a narrow
/// ([width]+[radix]-bit) accumulator `acc` plus finalized low product bits in
/// `res`. Each step:
///     sum   = acc + a * mr[radix-1:0]       // ([width]+[radix])-bit add
///     res   = {sum[radix-1:0], res} >> radix // finalized radix bits into res top
///     acc   = sum >> radix                   // carry the high part forward
///     mr  >>= radix                          // consume the radix multiplier bits
///   After [width]/[radix] steps the product is {acc[width-1:0], res-bits}.
///
/// Leaner than a left-shifting multiplicand scheme: accumulator is only
/// [width]+[radix] bits (not 2*[width]) and there is no 2*[width]-bit shifting
/// multiplicand register, so the per-cycle add and state FFs stay narrow.
///
/// Handshake (level-based, mirrors IterativeDivider): hold [start] high with
/// [a]/[b] valid; while idle the core latches operands and begins. After
/// ceil([width]/[radix]) cycles [done] rises and [product] holds the result until
/// [start] drops.
class IterativeMultiplier extends Module {
  final int width;
  final int radix;

  Logic get busy => output('busy');
  Logic get done => output('done');

  /// Full unsigned product, 2*[width] bits.
  Logic get product => output('product');

  IterativeMultiplier(
    Logic clk,
    Logic reset,
    Logic start,
    Logic a,
    Logic b, {
    this.width = 64,
    this.radix = 16,
    super.name = 'iterative_multiplier',
  }) {
    if (width % radix != 0) {
      throw ArgumentError(
        'width ($width) must be a multiple of radix ($radix)',
      );
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    a = addInput('a', a, width: width);
    b = addInput('b', b, width: width);

    final busy = addOutput('busy');
    final done = addOutput('done');
    final pw = width * 2;
    final product = addOutput('product', width: pw);

    final steps = width ~/ radix;

    // State machine: 0 = idle, 1 = run, 2 = done.
    const sIdle = 0, sRun = 1, sDone = 2;
    final state = Logic(name: 'state', width: 2);
    final cntWidth = (steps + 1).bitLength;
    final cnt = Logic(name: 'cnt', width: cntWidth);

    // md holds the (fixed) multiplicand a. mr is the remaining multiplier b,
    // consumed [radix] bits per cycle from the LSB via a right shift.
    final md = Logic(name: 'md', width: width);
    final mr = Logic(name: 'mr', width: width);

    // Narrow running accumulator holding the high carry across steps. Post-shift
    // bound: sum = acc + a*chunk < 2^(width+radix+1), so (sum>>radix) < 2^(width+1),
    // fitting width+1 bits. Narrower than the width+radix add keeps state FFs and
    // the feedback adder small.
    final accw = width + 1; // stored accumulator width (post-shift bound)
    final sw = width + radix + 1; // intermediate sum width (no overflow)
    final acc = Logic(name: 'acc', width: accw);
    // Finalized low product bits, collected radix at a time from the top so the
    // first-produced bits end up least significant once all steps are done.
    final res = Logic(name: 'res', width: pw);

    // Per-step: chunk = low radix bits of mr; chunkProd = md * chunk, an
    // (width+radix)-bit product. sum = acc + chunkProd, computed at sw bits so it
    // cannot overflow. The low radix bits of sum are finalized product bits; acc
    // carries (sum >> radix) forward, which fits in accw bits (see bound above).
    final chunk = mr.slice(radix - 1, 0); // radix-bit multiplier slice
    final chunkProd = (md.zeroExtend(sw) * chunk.zeroExtend(sw));
    final sum = acc.zeroExtend(sw) + chunkProd;
    // Shift the finalized low radix bits into res from the TOP; res is filled
    // top-down over `steps` shifts so the first chunk lands in the lowest bits.
    final resNext = [
      sum.slice(radix - 1, 0),
      res.slice(pw - 1, radix),
    ].swizzle();
    final accNext = sum.slice(sw - 1, radix); // (sw-radix)==accw bits
    final mrNext = mr >>> radix;

    // Final product: after `steps` shifts of `res`, the low product bits occupy
    // res[pw-1 : pw-width] and `acc` holds the top width bits. Assemble from the
    // next-state (accNext/resNext) on the final step so product and `done` align.
    final lowBitsFinal = resNext.slice(pw - 1, pw - width);
    final finalProductNext = [
      accNext.slice(width - 1, 0),
      lowBitsFinal,
    ].swizzle();

    Sequential(clk, [
      If(
        reset,
        then: [
          state < sIdle,
          cnt < 0,
          md < 0,
          mr < 0,
          acc < 0,
          res < 0,
          product < 0,
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                start,
                then: [
                  acc < 0,
                  res < 0,
                  md < a,
                  mr < b,
                  cnt < steps,
                  state < sRun,
                ],
              ),
            ]),
            CaseItem(Const(sRun, width: 2), [
              acc < accNext,
              res < resNext,
              mr < mrNext,
              cnt < cnt - 1,
              // cnt == 1 is the final (steps-th) accumulate this cycle. Latch the
              // assembled product so it is stable while done is held.
              If(cnt.eq(1), then: [state < sDone, product < finalProductNext]),
            ]),
            CaseItem(Const(sDone, width: 2), [
              If(~start, then: [state < sIdle]),
            ]),
          ]),
        ],
      ),
    ]);

    busy <= state.eq(sRun);
    done <= state.eq(sDone);
    // product is a registered output, latched on the final accumulate step above
    // and held stable while done is asserted (the caller reads it then).
  }
}
