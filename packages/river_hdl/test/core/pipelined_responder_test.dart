import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

import 'pipelined_responder.dart';

/// Drives [PipelinedReadResponder] with a free-running, hold-until-accepted
/// master: `reqValid` stays high, `reqAddr` advances only when the request is
/// accepted (`reqValid & reqReady`). Responses are in order, so the k-th
/// collected word must equal mem[k*4]. Returns (collectedWords, cyclesUsed,
/// sawBackpressure).
Future<(List<int>, int, bool)> runResponder(
  Map<int, int> mem, {
  required int count,
  int latency = 4,
  int maxOutstanding = 16,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final reqValid = Logic();
  final reqAddr = Logic(width: 32);

  final port = FetchReadInterface(32, 32);
  port.reqValid <= reqValid;
  port.reqAddr <= reqAddr;

  final dut = PipelinedReadResponder(
    clk,
    reset,
    port,
    mem,
    latency: latency,
    maxOutstanding: maxOutstanding,
  );
  await dut.build();

  reset.inject(1);
  reqValid.inject(0);
  reqAddr.inject(0);
  Simulator.registerAction(15, () => reset.put(0));
  Simulator.setMaxSimTime(40000 + latency * 400);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  reqValid.inject(1);
  var curAddr = 0;
  reqAddr.inject(curAddr);
  final collected = <int>[];
  var cycles = 0;
  var sawBackpressure = false;
  var guard = 0;
  while (collected.length < count && guard < 8000 + latency * 200) {
    guard++;
    cycles++;
    // Settle: sample whether the upcoming posedge will accept the held request.
    await clk.nextNegedge;
    final ready = port.reqReady.value;
    final willAccept = ready.isValid && ready.toBool();
    if (!willAccept) sawBackpressure = true;
    await clk.nextPosedge;
    final rv = port.rspValid.value;
    if (rv.isValid && rv.toBool()) {
      collected.add(port.rspData.value.toInt());
    }
    if (willAccept) {
      curAddr += 4;
      reqAddr.inject(curAddr);
    }
  }

  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return (collected, cycles, sawBackpressure);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // 12 distinct words at 0x00, 0x04, ...
  final seq = [for (var i = 0; i < 12; i++) (0x00000013 | ((i + 1) << 20))];
  final mem = {for (var i = 0; i < seq.length; i++) i * 4: seq[i]};

  // Pipelined, no back-pressure (maxOutstanding >= latency): responses must be
  // in order AND arrive ~1/cycle, so total cycles ~ latency + count (NOT the
  // count*(latency+1) a single-outstanding port would take).
  for (final latency in [0, 1, 2, 4, 8]) {
    test(
      'pipelined: in-order + ~1/cycle throughput at latency $latency',
      () async {
        const count = 8;
        final (got, cycles, sawBp) = await runResponder(
          mem,
          count: count,
          latency: latency,
          maxOutstanding: 16,
        );
        expect(got.length, count);
        for (var i = 0; i < count; i++) {
          expect(got[i], seq[i], reason: 'word $i at latency $latency');
        }
        // No back-pressure expected when maxOutstanding >> latency.
        expect(sawBp, isFalse, reason: 'unexpected back-pressure');
        // Pipelined bound: a single-outstanding port would need
        // count*(latency+1); assert we are far under that.
        expect(
          cycles,
          lessThanOrEqualTo(count + latency + 4),
          reason: 'not pipelined at latency $latency (took $cycles cycles)',
        );
      },
      timeout: Timeout(Duration(seconds: 40 + latency * 2)),
    );
  }

  // Back-pressure: maxOutstanding < latency forces reqReady low at times. The
  // stream must still be correct and complete (no deadlock, no reorder).
  test('back-pressure: maxOutstanding < latency stays correct', () async {
    const count = 10;
    final (got, cycles, sawBp) = await runResponder(
      mem,
      count: count,
      latency: 6,
      maxOutstanding: 2,
    );
    expect(got.length, count);
    for (var i = 0; i < count; i++) {
      expect(got[i], seq[i], reason: 'word $i under back-pressure');
    }
    expect(sawBp, isTrue, reason: 'cap=2 < latency=6 should back-pressure');
    // Capacity 2 over a 6-cycle pipe: throughput ~2/6, so noticeably slower
    // than the unthrottled case but still far better than fully serial.
    expect(
      cycles,
      greaterThan(count + 6 + 4),
      reason: 'back-pressure should slow it vs the unthrottled bound',
    );
  });
}
