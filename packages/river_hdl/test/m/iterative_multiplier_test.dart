import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/iterative_multiplier.dart';
import 'package:test/test.dart';

/// Build one [IterativeMultiplier] settled out of reset, plus the input nets so
/// a test can drive many vectors through it back to back.
class _Harness {
  final int width;
  final int radix;
  final Logic clk;
  final Logic reset;
  final Logic start;
  final Logic a;
  final Logic b;
  final IterativeMultiplier dut;

  _Harness._(
    this.width,
    this.radix,
    this.clk,
    this.reset,
    this.start,
    this.a,
    this.b,
    this.dut,
  );

  static Future<_Harness> make(int width, int radix) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final a = Logic(name: 'a', width: width);
    final b = Logic(name: 'b', width: width);
    final dut = IterativeMultiplier(
      clk,
      reset,
      start,
      a,
      b,
      width: width,
      radix: radix,
    );
    reset.inject(1);
    start.inject(0);
    a.inject(0);
    b.inject(0);
    await dut.build();
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    return _Harness._(width, radix, clk, reset, start, a, b, dut);
  }

  /// Drive one multiply and return the full 2*width-bit unsigned product.
  Future<BigInt> mul(BigInt x, BigInt y) async {
    a.inject(LogicValue.ofBigInt(x, width));
    b.inject(LogicValue.ofBigInt(y, width));
    start.inject(1);
    var guard = 0;
    while (!dut.done.value.toBool()) {
      await clk.nextPosedge;
      if (++guard > width + 16) {
        fail('multiplier did not assert done within ${width + 16} cycles');
      }
    }
    final p = dut.product.value.toBigInt();
    start.inject(0);
    await clk.nextPosedge;
    return p;
  }
}

Future<void> _check(_Harness h, BigInt x, BigInt y) async {
  final p = await h.mul(x, y);
  expect(p, x * y, reason: 'product $x * $y (w=${h.width}, radix=${h.radix})');
}

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('width=8 radix=4 exhaustive', () async {
    final h = await _Harness.make(8, 4);
    for (var a = 0; a < 256; a++) {
      for (var b = 0; b < 256; b++) {
        await _check(h, BigInt.from(a), BigInt.from(b));
      }
    }
  });

  test('width=16 radix=8 edge + sweep', () async {
    final h = await _Harness.make(16, 8);
    final max = (BigInt.one << 16) - BigInt.one;
    final edges = [
      BigInt.zero,
      BigInt.one,
      BigInt.two,
      BigInt.from(0x7FFF),
      BigInt.from(0x8000),
      BigInt.from(0xFFFE),
      max,
    ];
    for (final a in edges) {
      for (final b in edges) {
        await _check(h, a, b);
      }
    }
  });

  test('width=32 radix=16 edge + pseudorandom', () async {
    final h = await _Harness.make(32, 16);
    final max = (BigInt.one << 32) - BigInt.one;
    final edges = [
      BigInt.zero,
      BigInt.one,
      BigInt.from(0x7FFFFFFF),
      BigInt.from(0x80000000),
      max,
    ];
    for (final a in edges) {
      for (final b in edges) {
        await _check(h, a, b);
      }
    }
    var s = 0x12345678;
    int next() {
      s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
      return s;
    }

    for (var i = 0; i < 200; i++) {
      final a = (BigInt.from(next()) << 1 | BigInt.from(next() & 1)) & max;
      final b = (BigInt.from(next()) << 1 | BigInt.from(next() & 1)) & max;
      await _check(h, a, b);
    }
  });

  test('width=64 radix=16 edge + pseudorandom', () async {
    final h = await _Harness.make(64, 16);
    final m64 = (BigInt.one << 64) - BigInt.one;
    final edges = [
      BigInt.zero,
      BigInt.one,
      BigInt.two,
      BigInt.parse('0x7FFFFFFFFFFFFFFF'),
      BigInt.parse('0x8000000000000000'),
      BigInt.parse('0xFFFFFFFF00000000'),
      BigInt.parse('0x00000000FFFFFFFF'),
      m64,
    ];
    for (final a in edges) {
      for (final b in edges) {
        await _check(h, a, b);
      }
    }
    var s = BigInt.from(0xCAFEBABE);
    BigInt next() {
      s =
          (s * BigInt.from(6364136223846793005) +
              BigInt.from(1442695040888963407)) &
          m64;
      return s;
    }

    for (var i = 0; i < 200; i++) {
      await _check(h, next(), next());
    }
  });
}
