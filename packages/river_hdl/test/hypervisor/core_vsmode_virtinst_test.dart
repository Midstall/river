import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// H4 (trap virtualization): VS-mode access to an HS-only hypervisor CSR raises
/// a virtual-instruction exception (cause 22). MRET into VS-mode, `csrr hstatus`
/// must trap to mtvec; the handler reads mcause and confirms it is 22.
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
  int csrr(int csr, int rd) => (csr << 20) | (0x2 << 12) | (rd << 7) | 0x73;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  int orr(int rd, int rs1, int rs2) =>
      (rs2 << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x33;
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

  final stateenConfig = RiverCoreConfig(
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [
      rv64i,
      rv32i,
      rvZicsr,
      rvZifencei,
      rvPriv,
      rvH,
      rvSmstateen,
      rvSsstateen,
    ],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
  );

  // VS-mode sstateen access that mstateen0.SE0 permits but hstateen0.SE0 blocks
  // (hstateen0 resets to 0) must raise virtual-instruction, not illegal. The
  // exec catches it before the CSR access, so the VS redirect never applies.
  test(
    'VS-mode csrr sstateen0 (hstateen blocks) raises virtual-instruction (22)',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      final prog = words([
        addi(11, 0, 0x38), //  0 x11 = 0x38 (VS code)
        csrw(0x341, 11), //    1 csrw mepc, x11
        addi(12, 0, 1), //     2
        slli(12, 12, 11), //   3 MPP=S
        addi(13, 0, 1), //     4
        slli(13, 13, 39), //   5 MPV
        orr(12, 12, 13), //    6 x12 = 0x8000000800
        csrw(0x300, 12), //    7 csrw mstatus, x12
        addi(14, 0, 0x4c), //  8 x14 = 0x4c (mtvec)
        csrw(0x305, 14), //    9 csrw mtvec, x14
        addi(15, 0, 1), //    10
        slli(15, 15, 63), //  11 x15 = 1<<63 (mstateen0.SE0)
        csrw(0x30c, 15), //   12 csrw mstateen0, x15 (SE0=1; hstateen0 SE0=0)
        0x30200073, //        13 @0x34 mret -> VS-mode
        csrr(0x10c, 6), //    14 @0x38 VS: csrr x6, sstateen0 -> virtual-instr
        0x00000013, //        15 @0x3c (skipped)
        0x00000013, //        16 @0x40
        0x00000013, //        17 @0x44
        0x00000013, //        18 @0x48
        csrr(0x342, 5), //    19 @0x4c handler: x5 = mcause
        jalLoop, //           20 @0x50 loop
      ]);
      return coreTest(
        '@0\n$prog\n',
        {Register.x5: 22}, // mcause == virtual-instruction
        stateenConfig,
        nextPc: 0x50,
      );
    },
  );

  test(
    'VS-mode csrr hstatus raises virtual-instruction (cause 22)',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      final prog = words([
        addi(11, 0, 0x2c), //  0 x11 = 0x2c (VS code)
        csrw(0x341, 11), //    1 csrw mepc, x11
        addi(12, 0, 1), //     2
        slli(12, 12, 11), //   3 MPP=S
        addi(13, 0, 1), //     4
        slli(13, 13, 39), //   5 MPV
        orr(12, 12, 13), //    6 x12 = 0x8000000800
        csrw(0x300, 12), //    7 csrw mstatus, x12
        addi(14, 0, 0x40), //  8 x14 = 0x40 (mtvec)
        csrw(0x305, 14), //    9 csrw mtvec, x14
        0x30200073, //        10 @0x28 mret -> VS-mode
        csrr(
          0x600,
          6,
        ), //    11 @0x2c VS: csrr x6, hstatus -> virtual-instruction
        0x00000013, //        12 @0x30 (skipped)
        0x00000013, //        13 @0x34
        0x00000013, //        14 @0x38
        0x00000013, //        15 @0x3c
        csrr(0x342, 5), //    16 @0x40 handler: x5 = mcause
        jalLoop, //           17 @0x44 loop
      ]);
      return coreTest(
        '@0\n$prog\n',
        {Register.x5: 22}, // mcause == virtual-instruction
        config,
        nextPc: 0x44,
      );
    },
  );
}
