// Width-generic combinational building blocks: bit manipulation (Zbb/Zba/Zbs)
// plus the M-family multiply/divide helpers (BmMulSet, bmDiv*/bmRem*), shared
// by the in-order ALU (exec.dart) and the out-of-order ALU (fu_alu.dart) so
// both datapaths compute the same results. `w` is the operand width in bits.
import 'package:rohd/rohd.dart';

/// Population count (number of set bits), result [w] bits wide.
Logic bmPopcount(Logic x, int w) =>
    [for (var i = 0; i < w; i++) x[i].zeroExtend(w)].reduce((a, b) => a + b);

/// Count leading zeros: smear the highest set bit downward, then w - popcount.
Logic bmClz(Logic x, int w) {
  var y = x;
  for (var s = 1; s < w; s <<= 1) {
    y = y | (y >>> s);
  }
  return Const(w, width: w) - bmPopcount(y, w);
}

/// Count trailing zeros: popcount of the trailing-zero mask `(x-1) & ~x`.
Logic bmCtz(Logic x, int w) => bmPopcount((x - Const(1, width: w)) & ~x, w);

/// Signed less-than: differing signs pick a's sign bit, same signs use the
/// unsigned comparison.
Logic bmSignedLt(Logic a, Logic b, int w) {
  final sa = a[w - 1];
  final differ = sa ^ b[w - 1];
  return mux(differ, sa, a.lt(b));
}

/// Rotate right by `b mod w` (complement shift masked to stay in [0, w)).
Logic bmRotr(Logic a, Logic b, int w) {
  final s = b & Const(w - 1, width: w);
  final cs = (Const(w, width: w) - s) & Const(w - 1, width: w);
  return (a >>> s) | (a << cs);
}

/// Rotate left by `b mod w`.
Logic bmRotl(Logic a, Logic b, int w) {
  final s = b & Const(w - 1, width: w);
  final cs = (Const(w, width: w) - s) & Const(w - 1, width: w);
  return (a << s) | (a >>> cs);
}

/// orc.b: each byte becomes 0xFF if any bit is set, else 0x00.
Logic bmOrcb(Logic x, int w) => [
  for (var i = 0; i < w ~/ 8; i++)
    mux(
      x.slice(i * 8 + 7, i * 8).or(),
      Const(0xFF, width: 8),
      Const(0, width: 8),
    ),
].reversed.toList().swizzle();

/// rev8: reverse byte order.
Logic bmRev8(Logic x, int w) =>
    [for (var i = 0; i < w ~/ 8; i++) x.slice(i * 8 + 7, i * 8)].swizzle();

Logic _abs(Logic x, int w) => mux(x[w - 1], ~x + Const(1, width: w), x);

/// One shared multiplier for the whole mul family. A single ZERO-extended
/// product (which synthesis folds to a w*w array, unlike sign-extended
/// operands) yields every flavor through the modular identity
///
///   high_ss = hiUU - (a<0 ? b : 0) - (b<0 ? a : 0)   (mod 2^w)
///   high_su = hiUU - (a<0 ? b : 0)
///
/// so mulh/mulhsu/mulhu cost two w-wide subtractors instead of three
/// separate 2w-wide multiplier arrays. `low` serves mul and mulw.
class BmMulSet {
  /// Low w bits of the product (identical for every signedness flavor).
  late final Logic low;

  /// High w bits, both operands signed (mulh).
  late final Logic highSS;

  /// High w bits, a signed and b unsigned (mulhsu).
  late final Logic highSU;

  /// High w bits, both unsigned (mulhu).
  late final Logic highUU;

  BmMulSet(Logic a, Logic b, int w) {
    final z = Const(0, width: w);
    final uu = a.zeroExtend(w * 2) * b.zeroExtend(w * 2);
    low = uu.slice(w - 1, 0);
    highUU = uu.slice(w * 2 - 1, w);
    highSU = highUU - mux(a[w - 1], b, z);
    highSS = highSU - mux(b[w - 1], a, z);
  }
}

/// Unsigned divide with RISC-V div-by-zero result (all ones). The divisor is
/// forced to 1 when zero so the hardware divider never divides by zero.
Logic bmDivU(Logic a, Logic b, int w) {
  final z = Const(0, width: w);
  return mux(b.eq(z), ~z, a / mux(b.eq(z), Const(1, width: w), b));
}

/// Unsigned remainder with RISC-V div-by-zero result (the dividend).
Logic bmRemU(Logic a, Logic b, int w) {
  final z = Const(0, width: w);
  return mux(b.eq(z), a, a % mux(b.eq(z), Const(1, width: w), b));
}

/// Signed divide (truncating toward zero). div-by-zero => all ones;
/// overflow (INT_MIN / -1) => INT_MIN.
Logic bmDivS(Logic a, Logic b, int w) {
  final z = Const(0, width: w);
  final allOnes = ~z; // also == -1
  final intMin = Const(1, width: w) << (w - 1);
  final ub = _abs(b, w);
  final q = _abs(a, w) / mux(ub.eq(z), Const(1, width: w), ub);
  final res = mux(a[w - 1] ^ b[w - 1], ~q + Const(1, width: w), q);
  return mux(b.eq(z), allOnes, mux(a.eq(intMin) & b.eq(allOnes), intMin, res));
}

/// Signed remainder (sign of dividend). div-by-zero => dividend; overflow => 0.
Logic bmRemS(Logic a, Logic b, int w) {
  final z = Const(0, width: w);
  final allOnes = ~z;
  final intMin = Const(1, width: w) << (w - 1);
  final ub = _abs(b, w);
  final r = _abs(a, w) % mux(ub.eq(z), Const(1, width: w), ub);
  final res = mux(a[w - 1], ~r + Const(1, width: w), r);
  return mux(b.eq(z), a, mux(a.eq(intMin) & b.eq(allOnes), z, res));
}

// Iterative-divider result fixups. The in-order core runs one shared multi-cycle
// IterativeDivider over unsigned magnitudes, then applies the same sign/edge
// handling as bmDiv*/bmRem* here on the magnitude quotient [q] (= |a|/|b|, b
// forced non-zero) or remainder [r]. Results match bmDiv*/bmRem* bit for bit.

/// Unsigned magnitude |x| of a signed w-bit value, exposed so the divider's
/// pre-stage can feed magnitudes. |INT_MIN| wraps to INT_MIN, whose unsigned
/// value 2^(w-1) is the correct magnitude.
Logic bmAbs(Logic x, int w) => _abs(x, w);

/// Unsigned divide fixup: div-by-zero yields all ones, else the quotient.
Logic divFixupU(Logic a, Logic b, Logic q, int w) {
  final z = Const(0, width: w);
  return mux(b.eq(z), ~z, q);
}

/// Unsigned remainder fixup: div-by-zero yields the dividend, else the remainder.
Logic remFixupU(Logic a, Logic b, Logic r, int w) {
  final z = Const(0, width: w);
  return mux(b.eq(z), a, r);
}

/// Signed divide fixup over magnitude quotient [q] (= |a|/|b|): apply the result
/// sign, then div-by-zero (all ones) and INT_MIN/-1 overflow (INT_MIN) corners.
Logic divFixupS(Logic a, Logic b, Logic q, int w) {
  final z = Const(0, width: w);
  final allOnes = ~z;
  final intMin = Const(1, width: w) << (w - 1);
  final res = mux(a[w - 1] ^ b[w - 1], ~q + Const(1, width: w), q);
  return mux(b.eq(z), allOnes, mux(a.eq(intMin) & b.eq(allOnes), intMin, res));
}

/// Signed remainder fixup over magnitude remainder [r] (= |a| % |b|): sign of
/// dividend, then div-by-zero (dividend) and INT_MIN/-1 overflow (0) corners.
Logic remFixupS(Logic a, Logic b, Logic r, int w) {
  final z = Const(0, width: w);
  final allOnes = ~z;
  final intMin = Const(1, width: w) << (w - 1);
  final res = mux(a[w - 1], ~r + Const(1, width: w), r);
  return mux(b.eq(z), a, mux(a.eq(intMin) & b.eq(allOnes), z, res));
}
