import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/iterative_divider.dart';
import 'package:test/test.dart';

/// Build one [IterativeDivider] of [width] bits, settled out of reset, plus the
/// input nets so a test can drive many vectors through it back to back.
class _Harness {
  final int width;
  final Logic clk;
  final Logic reset;
  final Logic start;
  final Logic dividend;
  final Logic divisor;
  final IterativeDivider dut;

  _Harness._(
    this.width,
    this.clk,
    this.reset,
    this.start,
    this.dividend,
    this.divisor,
    this.dut,
  );

  static Future<_Harness> make(int width) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final dividend = Logic(name: 'dividend', width: width);
    final divisor = Logic(name: 'divisor', width: width);
    final dut = IterativeDivider(
      clk,
      reset,
      start,
      dividend,
      divisor,
      width: width,
    );
    reset.inject(1);
    start.inject(0);
    dividend.inject(0);
    divisor.inject(LogicValue.ofInt(1, width));
    await dut.build();
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    return _Harness._(width, clk, reset, start, dividend, divisor, dut);
  }

  /// Drive one division and return (quotient, remainder). Divisor must be >= 1.
  Future<(BigInt, BigInt)> div(BigInt a, BigInt b) async {
    dividend.inject(LogicValue.ofBigInt(a, width));
    divisor.inject(LogicValue.ofBigInt(b, width));
    start.inject(1);
    // Wait for done (latency ~ width + a few cycles; cap generously).
    var guard = 0;
    while (!dut.done.value.toBool()) {
      await clk.nextPosedge;
      if (++guard > width + 16) {
        fail('divider did not assert done within ${width + 16} cycles');
      }
    }
    final q = dut.quotient.value.toBigInt();
    final r = dut.remainder.value.toBigInt();
    // Release and let the core return to idle before the next vector.
    start.inject(0);
    await clk.nextPosedge;
    return (q, r);
  }
}

/// Reference unsigned quotient/remainder (BigInt is truncating toward zero, and
/// both operands are non-negative here, so this is unsigned div/mod).
(BigInt, BigInt) _ref(BigInt a, BigInt b) => (a ~/ b, a % b);

Future<void> _check(_Harness h, BigInt a, BigInt b) async {
  final (q, r) = await h.div(a, b);
  final (eq, er) = _ref(a, b);
  expect(q, eq, reason: 'quotient $a / $b (w=${h.width})');
  expect(r, er, reason: 'remainder $a % $b (w=${h.width})');
}

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('width=8 exhaustive-ish (edge a x edge/all b)', () async {
    final h = await _Harness.make(8);
    const aVals = [0, 1, 2, 7, 99, 127, 128, 200, 254, 255];
    for (final a in aVals) {
      for (var b = 1; b <= 255; b++) {
        await _check(h, BigInt.from(a), BigInt.from(b));
      }
    }
  });

  test('width=32 edge cross product + pseudorandom', () async {
    final h = await _Harness.make(32);
    final max = (BigInt.one << 32) - BigInt.one;
    final edges = <BigInt>[
      BigInt.zero,
      BigInt.one,
      BigInt.two,
      BigInt.from(7),
      BigInt.from(1000000),
      BigInt.from(0x7FFFFFFF),
      BigInt.from(0x80000000),
      max,
    ];
    for (final a in edges) {
      for (final b in edges) {
        if (b == BigInt.zero) continue;
        await _check(h, a, b);
      }
    }
    // Deterministic LCG sweep (no Math.random for reproducibility).
    var s = 0x12345678;
    int next() {
      s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
      return s;
    }

    for (var i = 0; i < 200; i++) {
      final a = BigInt.from(next()) << 1 | BigInt.from(next() & 1);
      final b = BigInt.from((next() % 0xFFFFFFFF) + 1);
      await _check(h, a & max, b & max);
    }
  });

  test('width=64 edge cross product + pseudorandom', () async {
    final h = await _Harness.make(64);
    final max = (BigInt.one << 64) - BigInt.one;
    final edges = <BigInt>[
      BigInt.zero,
      BigInt.one,
      BigInt.two,
      BigInt.from(7),
      BigInt.parse('0x7FFFFFFFFFFFFFFF'),
      BigInt.parse('0x8000000000000000'),
      BigInt.parse('0xFFFFFFFF00000000'),
      max,
    ];
    for (final a in edges) {
      for (final b in edges) {
        if (b == BigInt.zero) continue;
        await _check(h, a, b);
      }
    }
    var s = BigInt.from(0xCAFEBABE);
    final m64 = (BigInt.one << 64) - BigInt.one;
    BigInt next() {
      s =
          (s * BigInt.from(6364136223846793005) +
              BigInt.from(1442695040888963407)) &
          m64;
      return s;
    }

    for (var i = 0; i < 200; i++) {
      final a = next();
      final b = (next() & m64) | BigInt.one; // ensure non-zero
      await _check(h, a, b);
    }
  });
}
