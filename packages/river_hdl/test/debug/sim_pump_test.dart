import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Validates the manual `Simulator.tick()` pump that river_sim's
/// remote_bitbang mode uses instead of a free-running `Simulator.run()`.
///
/// The pump must (a) advance the clock so the design runs, and (b) yield to the
/// Dart event loop each tick so concurrent async work (the JTAG socket) is
/// serviced. A free-running `Simulator.run()` chains ticks via microtasks and
/// starves I/O; the pump below breaks that with a zero-duration timer.
void main() {
  test(
    'Simulator.tick() pump advances a clocked counter and yields to I/O',
    () async {
      await Simulator.reset();
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic(name: 'reset');
      final count = Logic(name: 'count', width: 16);
      Sequential(clk, [
        If(reset, then: [count < 0], orElse: [count < count + 1]),
      ]);

      reset.inject(1);

      // A concurrent task that only makes progress if the pump yields to the
      // event loop (real timers), standing in for the socket read loop.
      var concurrentTicks = 0;
      var running = true;
      unawaited(() async {
        while (running) {
          await Future<void>.delayed(Duration.zero);
          concurrentTicks++;
        }
      }());

      // Manual pump: NO Simulator.run().
      var prevClk = 0;
      var cycles = 0;
      for (var i = 0; i < 400 && cycles < 20; i++) {
        await Simulator.tick();
        if (i == 1) reset.inject(0);
        final c = (clk.value.isValid && clk.value.toBool()) ? 1 : 0;
        if (c == 1 && prevClk == 0) cycles++;
        prevClk = c;
        await Future<void>.delayed(Duration.zero);
      }
      running = false;

      expect(
        cycles,
        greaterThanOrEqualTo(20),
        reason: 'the pump must advance the clock',
      );
      expect(
        count.value.toInt(),
        greaterThanOrEqualTo(18),
        reason: 'the clocked counter must increment under the pump',
      );
      // ~1 concurrent turn per pump iteration (loop runs ~40 iterations for 20
      // cycles), so a healthy count near `cycles` proves I/O is not starved.
      expect(
        concurrentTicks,
        greaterThanOrEqualTo(20),
        reason: 'concurrent async work must run (I/O is not starved)',
      );

      // NOTE: with a hand-pumped simulator there is no `Simulator.run()` loop, so
      // `await Simulator.simulationEnded` would hang. Just stop pumping.
      Simulator.endSimulation();
    },
  );
}
