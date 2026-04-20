import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Golden test for the shared MicrocodeAlu (Phase 1 of the microcode exec
/// rewrite). Drives every integer ALU funct over a battery of operand pairs and
/// checks the result against a Dart 64-bit golden, so the shared datapath is
/// proven bit-for-bit before the exec is rewritten to use it. See
/// project_microcode_exec_rewrite.
void main() {
  const m = 0xFFFFFFFFFFFFFFFF; // 64-bit mask

  // 64-bit golden for each MicroOpAluFunct, computed with Dart's native 64-bit
  // (wrapping) int arithmetic. signExt32 sign-extends a 32-bit value.
  int signExt32(int v) {
    v &= 0xFFFFFFFF;
    return (v & 0x80000000) != 0 ? v | (m << 32) : v;
  }

  int golden(int funct, int a, int b) {
    switch (funct) {
      case MicroOpAluFunct.add:
        return (a + b) & m;
      case MicroOpAluFunct.sub:
        return (a - b) & m;
      case MicroOpAluFunct.and:
        return a & b;
      case MicroOpAluFunct.or:
        return a | b;
      case MicroOpAluFunct.xor:
        return a ^ b;
      case MicroOpAluFunct.masked:
        return a & ~b;
      case MicroOpAluFunct.sll:
        return (a << (b & 63)) & m;
      case MicroOpAluFunct.srl:
        return a >>> (b & 63);
      case MicroOpAluFunct.sra:
        return a >> (b & 63); // Dart >> on a 64-bit int is arithmetic
      case MicroOpAluFunct.addw:
        return signExt32((a + b) & 0xFFFFFFFF);
      case MicroOpAluFunct.subw:
        return signExt32((a - b) & 0xFFFFFFFF);
      case MicroOpAluFunct.sllw:
        return signExt32(((a & 0xFFFFFFFF) << (b & 31)) & 0xFFFFFFFF);
      case MicroOpAluFunct.srlw:
        return signExt32((a & 0xFFFFFFFF) >>> (b & 31));
      case MicroOpAluFunct.sraw:
        return signExt32(signExt32(a & 0xFFFFFFFF) >> (b & 31) & 0xFFFFFFFF);
      case MicroOpAluFunct.slt:
        return signExt32(a) < signExt32(b) ? 1 : 0; // placeholder, overridden
      case MicroOpAluFunct.sltu:
        return 0; // overridden
      case MicroOpAluFunct.czeroEqz:
        return b == 0 ? 0 : a;
      case MicroOpAluFunct.czeroNez:
        return b == 0 ? a : 0;
      default:
        return 0;
    }
  }

  // Signed/unsigned compares use full 64-bit semantics, done via BigInt to avoid
  // Dart-int sign ambiguity at the 2^63 boundary.
  int sltGolden(int a, int b) {
    final sa = LogicValue.ofInt(a, 64).toBigInt(); // unsigned BigInt
    final sb = LogicValue.ofInt(b, 64).toBigInt();
    BigInt asSigned(BigInt u) =>
        u >= (BigInt.one << 63) ? u - (BigInt.one << 64) : u;
    return asSigned(sa) < asSigned(sb) ? 1 : 0;
  }

  int sltuGolden(int a, int b) {
    final ua = LogicValue.ofInt(a, 64).toBigInt();
    final ub = LogicValue.ofInt(b, 64).toBigInt();
    return ua < ub ? 1 : 0;
  }

  final functs = [
    MicroOpAluFunct.add,
    MicroOpAluFunct.sub,
    MicroOpAluFunct.and,
    MicroOpAluFunct.or,
    MicroOpAluFunct.xor,
    MicroOpAluFunct.masked,
    MicroOpAluFunct.sll,
    MicroOpAluFunct.srl,
    MicroOpAluFunct.sra,
    MicroOpAluFunct.addw,
    MicroOpAluFunct.subw,
    MicroOpAluFunct.sllw,
    MicroOpAluFunct.srlw,
    MicroOpAluFunct.sraw,
    MicroOpAluFunct.slt,
    MicroOpAluFunct.sltu,
    MicroOpAluFunct.czeroEqz,
    MicroOpAluFunct.czeroNez,
  ];

  final operands = <List<int>>[
    [0, 0],
    [1, 1],
    [5, 3],
    [3, 5],
    [0xDEADBEEF, 0x12345678],
    [0x8000000000000000, 1], // INT_MIN, -1-ish edge
    [0x7FFFFFFFFFFFFFFF, 1],
    [0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF], // -1, -1
    [0x00000000FFFFFFFF, 0x40], // 32-bit boundary, shamt 64
    [0xFEDCBA9876543210, 0],
    [100, 63],
    [0xF0F0F0F0, 4],
  ];

  test(
    'MicrocodeAlu matches the 64-bit golden for every funct/operand',
    () async {
      final a = Logic(name: 'a', width: 64);
      final b = Logic(name: 'b', width: 64);
      final funct = Logic(name: 'funct', width: MicroOpAluFunct.width);
      final dut = MicrocodeAlu(a, b, funct, mxlen: RiscVMxlen.rv64);
      await dut.build();

      for (final fn in functs) {
        for (final ops in operands) {
          a.put(ops[0]);
          b.put(ops[1]);
          funct.put(fn);
          final exp = switch (fn) {
            MicroOpAluFunct.slt => sltGolden(ops[0], ops[1]),
            MicroOpAluFunct.sltu => sltuGolden(ops[0], ops[1]),
            _ => golden(fn, ops[0], ops[1]),
          };
          expect(
            dut.result.value,
            LogicValue.ofInt(exp, 64),
            reason:
                'funct=$fn a=0x${ops[0].toRadixString(16)} '
                'b=0x${ops[1].toRadixString(16)} '
                'got=0x${dut.result.value.toBigInt().toRadixString(16)} '
                'exp=0x${LogicValue.ofInt(exp, 64).toBigInt().toRadixString(16)}',
          );
        }
      }
    },
  );
}
