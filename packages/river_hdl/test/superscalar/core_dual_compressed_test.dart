import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// RV64GC dual-issue: variable-length (compressed) instructions co-dispatch two
/// per cycle through the CompressedFetchBuffer + aligner, decode as RVC, and
/// execute out-of-order. This is the macro (RC1.ma) superscalar path.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // The actual shipped RC1.ma macro config (RV64GC + bit-manip, OoO dual). Using
  // the factory here doubles as a build+run smoke for the macro tier.
  RiverCoreConfig dualCConfig() => RiverCoreConfigV1.macro(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
  );

  // RVC encodings (quadrant 1/2 forms used here).
  int cli(int rd, int imm) =>
      0x4000 | (((imm >> 5) & 1) << 12) | (rd << 7) | ((imm & 0x1f) << 2) | 1;
  int cmv(int rd, int rs2) => 0x8000 | (rd << 7) | (rs2 << 2) | 2;
  int cadd(int rd, int rs2) => 0x9000 | (rd << 7) | (rs2 << 2) | 2;
  int caddi(int rd, int imm) =>
      (((imm >> 5) & 1) << 12) | (rd << 7) | ((imm & 0x1f) << 2) | 1;
  int cslli(int rd, int sh) => (rd << 7) | ((sh & 0x1f) << 2) | 2;

  /// Lay a (value,byteLen) instruction stream into a mem string, padding with a
  /// 32-bit-nop tail. Returns (memString, firstNopPc).
  (String, int) lay(List<(int, int)> instrs, {int nopTail = 16}) {
    final bytes = <int>[];
    for (final (v, len) in instrs) {
      for (var b = 0; b < len; b++) {
        bytes.add((v >> (8 * b)) & 0xFF);
      }
    }
    final firstNopPc = bytes.length;
    for (var i = 0; i < nopTail; i++) {
      for (final b in [0x13, 0x00, 0x00, 0x00]) {
        bytes.add(b);
      }
    }
    final sb = StringBuffer('@0\n');
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return ('$sb\n', firstNopPc);
  }

  test('dual: independent compressed c.li pairs retire', () {
    final (mem, nopPc) = lay([
      for (var k = 8; k <= 15; k++) (cli(k, k - 7), 2),
    ]);
    return coreTest(
      mem,
      {for (var k = 8; k <= 15; k++) Register.values[k]: k - 7},
      dualCConfig(),
      // A few nops into the tail (a PC the dual-commit core lands on, before it
      // could run off the end). nopPc is the first nop; +8 = 2 nops in.
      nextPc: nopPc + 8,
    );
  });

  test('dual: compressed arithmetic with intra-bundle hazards', () {
    // x8=5; x9=3; x10=0; x10=x8(5); x10+=x9(8); x8+=4(9); x9<<=1(6); fills.
    final (mem, nopPc) = lay([
      (cli(8, 5), 2),
      (cli(9, 3), 2),
      (cli(10, 0), 2),
      (cmv(10, 8), 2),
      (cadd(10, 9), 2),
      (caddi(8, 4), 2),
      (cslli(9, 1), 2),
      (cli(11, 4), 2),
      (cli(12, 5), 2),
      (cli(13, 6), 2),
      (cli(14, 7), 2),
      (cli(15, 8), 2),
    ]);
    return coreTest(
      mem,
      {
        Register.x8: 9,
        Register.x9: 6,
        Register.x10: 8,
        Register.x11: 4,
        Register.x12: 5,
        Register.x13: 6,
        Register.x14: 7,
        Register.x15: 8,
      },
      dualCConfig(),
      nextPc: nopPc + 8,
    );
  });

  test('dual: mixed compressed + 32-bit stream', () {
    int addi(int rd, int rs1, int imm) =>
        ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
    final (mem, nopPc) = lay([
      (cli(8, 1), 2),
      (addi(9, 0, 2), 4),
      (cli(10, 3), 2),
      (cli(11, 4), 2),
      (addi(12, 0, 5), 4),
      (cli(13, 6), 2),
      (addi(14, 0, 7), 4),
      (cli(15, 8), 2),
    ]);
    return coreTest(
      mem,
      {for (var k = 8; k <= 15; k++) Register.values[k]: k - 7},
      dualCConfig(),
      nextPc: nopPc + 8,
    );
  });
}
