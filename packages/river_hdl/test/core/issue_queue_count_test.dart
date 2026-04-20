import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Direct unit test for the issue-queue occupancy `count`. Regression guard for
/// the bug where `count` was driven by scattered `count<count+1` (enqueue) and
/// `count<count-1` (dispatch) conditional assignments: when an enqueue and a
/// dispatch fire the SAME cycle (sustained 1/cycle allocation), those conflict
/// (X / last-write-wins) and wedge `enqReady` forever. The fix is a single net
/// update. This test streams ready ALU ops so enqueue+dispatch overlap every
/// cycle; without the fix the queue stops dispatching after a couple of cycles.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('IQ count survives same-cycle enqueue+dispatch (net update)', () async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic();
    final enqValid0 = Logic();

    Logic z(int w) => Const(0, width: w);
    final iq = IssueQueue(
      clk,
      reset,
      // slot 0: a ready ALU op
      enqValid0: enqValid0,
      enqTag0: z(7),
      enqPsrc10: z(7),
      enqPsrc20: z(7),
      enqPdst0: z(7),
      enqImm0: z(64),
      enqPc0: z(64),
      enqFunct0: z(7),
      enqFuType0: Const(FuType.alu.index, width: 2),
      enqWritesRd0: Const(1),
      enqIsStore0: Const(0),
      enqMemSize0: z(3),
      enqBranchCond0: z(3),
      enqIsJump0: Const(0),
      enqIsJalr0: Const(0),
      enqUseImm0: Const(1),
      enqCsrOp0: z(3),
      enqCsrAddr0: z(12),
      enqSignExtend0: Const(0),
      // slot 1: unused
      enqValid1: Const(0),
      enqTag1: z(7),
      enqPsrc11: z(7),
      enqPsrc21: z(7),
      enqPdst1: z(7),
      enqImm1: z(64),
      enqPc1: z(64),
      enqFunct1: z(7),
      enqFuType1: Const(FuType.alu.index, width: 2),
      enqWritesRd1: Const(0),
      enqIsStore1: Const(0),
      enqMemSize1: z(3),
      enqBranchCond1: z(3),
      enqIsJump1: Const(0),
      enqIsJalr1: Const(0),
      enqUseImm1: Const(0),
      enqCsrOp1: z(3),
      enqCsrAddr1: z(12),
      enqSignExtend1: Const(0),
      // operands: both sources ready (so each entry can dispatch immediately)
      enqSrc1Value0: z(64),
      enqSrc2Value0: z(64),
      enqSrc1Ready0: Const(1),
      enqSrc2Ready0: Const(1),
      enqSrc1Value1: z(64),
      enqSrc2Value1: z(64),
      enqSrc1Ready1: Const(0),
      enqSrc2Ready1: Const(0),
      // no wakeups
      wakeupValid0: Const(0),
      wakeupTag0: z(7),
      wakeupValue0: z(64),
      wakeupValid1: Const(0),
      wakeupTag1: z(7),
      wakeupValue1: z(64),
      // all FUs free
      aluBusy0: Const(0),
      aluBusy1: Const(0),
      memBusy: Const(0),
      branchBusy: Const(0),
      csrBusy: Const(0),
      flush: Const(0),
    );
    await iq.build();

    reset.inject(1);
    enqValid0.inject(0);
    Simulator.registerAction(15, () => reset.put(0));
    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }

    // Enqueue ONLY when the IQ says it can accept (enqReady), exactly like the
    // core's back-pressure. The conflicting-count bug under-counts on each
    // enqueue+dispatch overlap, so `count` underflows, wraps to a huge value,
    // and `enqReady` (= count < depth-1) sticks low. Then enqueue stops, the
    // queue drains, and dispatch dies. The net-update count keeps enqReady
    // correct, so dispatch sustains ~1/cycle.
    enqValid0.inject(1);
    var dispatches = 0;
    const cycles = 40;
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
      final d = iq.dispatchAluValid0.value;
      if (d.isValid && d.toBool()) dispatches++;
      final er = iq.enqReady.value;
      enqValid0.inject(er.isValid && er.toBool() ? 1 : 0);
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;

    expect(
      dispatches,
      greaterThan(cycles - 8),
      reason: 'IQ wedged: only $dispatches/$cycles dispatches (count bug)',
    );
  });
}
