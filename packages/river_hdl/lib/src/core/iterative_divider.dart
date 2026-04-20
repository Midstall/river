import 'package:rohd/rohd.dart';

/// Shared multi-cycle unsigned integer divider (radix-2 restoring).
///
/// One division in flight at a time, matching the in-order exec unit: a div/rem
/// mop parks the pipeline at its mopStep and waits for [done]. Replaces the eight
/// combinational `/` and `%` trees (one per div/divu/divw/divuw/rem/remu/remw/
/// remuw), each thousands of LUT4s, with one core costing a few hundred and one
/// shift-subtract per cycle.
///
/// Signedness, word-width (`*w`), div-by-zero, and the INT_MIN/-1 overflow corner
/// are handled by the caller (this core sees only unsigned magnitudes with a
/// non-zero divisor); see `alu_ops.dart` for the reference semantics.
///
/// Handshake (level-based): hold [start] high with [dividend]/[divisor] valid;
/// while idle the core latches operands and begins. After [width] cycles [done]
/// rises and [quotient]/[remainder] hold until [start] drops.
class IterativeDivider extends Module {
  final int width;

  Logic get busy => output('busy');
  Logic get done => output('done');
  Logic get quotient => output('quotient');
  Logic get remainder => output('remainder');

  IterativeDivider(
    Logic clk,
    Logic reset,
    Logic start,
    Logic dividend,
    Logic divisor, {
    this.width = 64,
    super.name = 'iterative_divider',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    dividend = addInput('dividend', dividend, width: width);
    divisor = addInput('divisor', divisor, width: width);

    final busy = addOutput('busy');
    final done = addOutput('done');
    final quotient = addOutput('quotient', width: width);
    final remainder = addOutput('remainder', width: width);

    // State machine: 0 = idle, 1 = run, 2 = done.
    const sIdle = 0, sRun = 1, sDone = 2;
    final state = Logic(name: 'state', width: 2);
    // Iterations remaining; counts width down to 0. width fits in bitLength.
    final cntWidth = width.bitLength;
    final cnt = Logic(name: 'cnt', width: cntWidth);
    final rem = Logic(name: 'rem', width: width);
    final quot = Logic(name: 'quot', width: width);
    final divsr = Logic(name: 'divsr', width: width);

    // One restoring step: shift the running remainder left by 1, pulling in the
    // top quotient bit, then conditionally subtract the divisor. remCat is the
    // (width+1)-bit shifted remainder (rem*2 + quot[msb]); the post-subtract
    // remainder is < divsr <= 2^width-1, so it fits back in width bits.
    final remCat = [rem, quot[width - 1]].swizzle();
    final divExt = divsr.zeroExtend(width + 1);
    final ge = remCat.gte(divExt);
    final remNext = mux(ge, remCat - divExt, remCat).slice(width - 1, 0);
    final quotNext = (quot << 1) | ge.zeroExtend(width);

    Sequential(clk, [
      If(
        reset,
        then: [state < sIdle, cnt < 0, rem < 0, quot < 0, divsr < 0],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                start,
                then: [
                  rem < 0,
                  quot < dividend,
                  divsr < divisor,
                  cnt < width,
                  state < sRun,
                ],
              ),
            ]),
            CaseItem(Const(sRun, width: 2), [
              rem < remNext,
              quot < quotNext,
              cnt < cnt - 1,
              // cnt == 1 is the width-th (final) iteration this cycle.
              If(cnt.eq(1), then: [state < sDone]),
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
    quotient <= quot;
    remainder <= rem;
  }
}
