import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// H4 (trap virtualization, first step): an ecall taken in VS-mode must trap to
/// M (mtvec) cleanly. MRET into VS-mode, ecall, handler sets x5=0x5AD.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final config = RiverCoreConfig(
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvPriv, rvH],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
  );

  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x1 << 12) | 0x73;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  int orr(int rd, int rs1, int rs2) =>
      (rs2 << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x33;
  const ecall = 0x00000073;
  const jalLoop = 0x0000006F;

  String words(List<int> ws) {
    final sb = StringBuffer();
    for (final w in ws) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return sb.toString().trimRight();
  }

  test(
    'ecall in VS-mode traps to mtvec',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      final prog = words([
        addi(11, 0, 0x2c), //  0 x11 = 0x2c (VS code)
        csrw(0x341, 11), //    1 csrw mepc, x11
        addi(12, 0, 1), //     2
        slli(12, 12, 11), //   3 x12 = 0x800 (MPP=S)
        addi(13, 0, 1), //     4
        slli(13, 13, 39), //   5 x13 = MPV
        orr(12, 12, 13), //    6 x12 = 0x8000000800
        csrw(0x300, 12), //    7 csrw mstatus, x12
        addi(14, 0, 0x40), //  8 x14 = 0x40 (mtvec)
        csrw(0x305, 14), //    9 csrw mtvec, x14
        0x30200073, //        10 @0x28 mret -> VS-mode, pc=0x2c
        ecall, //             11 @0x2c VS ecall -> trap to mtvec
        0x00000013, //        12 @0x30 (skipped)
        0x00000013, //        13 @0x34
        0x00000013, //        14 @0x38
        0x00000013, //        15 @0x3c
        addi(5, 0, 0x5AD), // 16 @0x40 handler: x5 = 0x5AD
        jalLoop, //           17 @0x44 loop
      ]);
      return coreTest(
        '@0\n$prog\n',
        {Register.x5: 0x5AD},
        config,
        nextPc: 0x44,
      );
    },
  );
}
