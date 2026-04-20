import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/icache.dart';
import 'package:test/test.dart';

/// Unit test for RiverICache with a simple combinational backing "memory":
/// every fill word returns its own address, so a request to word-aligned addr A
/// must eventually return data == A.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> runCase({required bool dual}) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic();
    final req0En = Logic();
    final req0Addr = Logic(width: 32);
    final req1En = dual ? Logic() : null;
    final req1Addr = dual ? Logic(width: 32) : null;
    final memDone = Logic();
    final memValid = Logic();
    final memRdata = Logic(width: 32);
    final flush = Logic();

    final ic = RiverICache(
      clk,
      reset,
      req0En: req0En,
      req0Addr: req0Addr,
      req1En: req1En,
      req1Addr: req1Addr,
      memDone: memDone,
      memValid: memValid,
      memRdata: memRdata,
      flush: flush,
      xlen: 32,
      lineWords: 4,
      numLines: 8,
      dualPort: dual,
    );
    await ic.build();

    // Combinational backing memory: word at addr returns addr.
    memDone <= ic.memEn;
    memValid <= ic.memEn;
    memRdata <= ic.memAddr;

    reset.inject(1);
    req0En.inject(0);
    req0Addr.inject(0);
    flush.inject(0);
    if (dual) {
      req1En!.inject(0);
      req1Addr!.inject(0);
    }
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    Future<int> fetch0(int addr) async {
      req0En.inject(1);
      req0Addr.inject(addr);
      for (var i = 0; i < 50; i++) {
        await clk.nextNegedge;
        if (ic.done0.value.toBool()) {
          final d = ic.rdata0.value.toInt();
          req0En.inject(0);
          return d;
        }
      }
      req0En.inject(0);
      throw StateError('port0 fetch of $addr timed out');
    }

    // Miss → fill → hit.
    expect(await fetch0(0x100), 0x100);
    await clk.nextPosedge;
    // Same line, different word → hit (fast).
    expect(await fetch0(0x104), 0x104);
    await clk.nextPosedge;
    expect(await fetch0(0x10C), 0x10C);
    await clk.nextPosedge;
    // Different line → miss → fill → hit.
    expect(await fetch0(0x200), 0x200);
    await clk.nextPosedge;

    if (dual) {
      // Both ports, same line (0x100 already cached): both hit same cycle.
      req0En.inject(1);
      req0Addr.inject(0x100);
      req1En!.inject(1);
      req1Addr!.inject(0x104);
      var ok = false;
      for (var i = 0; i < 10; i++) {
        await clk.nextNegedge;
        if (ic.done0.value.toBool() && ic.done1.value.toBool()) {
          expect(ic.rdata0.value.toInt(), 0x100);
          expect(ic.rdata1.value.toInt(), 0x104);
          ok = true;
          break;
        }
      }
      req0En.inject(0);
      req1En.inject(0);
      expect(ok, isTrue, reason: 'dual same-line hit did not fire');
      await clk.nextPosedge;
    }

    // Flush invalidates → 0x100 misses again (still returns correct data).
    flush.inject(1);
    await clk.nextPosedge;
    flush.inject(0);
    await clk.nextPosedge;
    expect(await fetch0(0x100), 0x100);

    await Simulator.endSimulation();
  }

  test('icache single-port miss/fill/hit/flush', () => runCase(dual: false));
  test('icache dual-port same-line both hit', () => runCase(dual: true));
}
