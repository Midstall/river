import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// H3 corner: every G-stage *leaf* must be user-accessible. Here the data page's
/// G-leaf has U=0, so the HLV must take a guest page fault and trap to mtvec.
/// The handler sets x5=0x5AD, proving the fault propagated (and exercising the
/// HLV fault -> trap path).
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
  int csrr(int csr, int rd) => (csr << 20) | (0x2 << 12) | (rd << 7) | 0x73;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  int orr(int rd, int rs1, int rs2) =>
      (rs2 << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x33;
  int lui(int rd, int imm20) => (imm20 << 12) | (rd << 7) | 0x37;
  int hlvw(int rd, int rs1) =>
      (0x34 << 25) | (rs1 << 15) | (0x4 << 12) | (rd << 7) | 0x73;
  const jalLoop = 0x0000006F; // jal x0, 0 -> branch to self

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

  String pte(int v) {
    final sb = StringBuffer();
    for (var b = 0; b < 8; b++) {
      sb.write(((v >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return sb.toString().trimRight();
  }

  test(
    'HLV faults when the G-stage leaf is not user-accessible',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      final prog = words([
        csrw(0x280, 10), //  0 csrw vsatp, a0
        addi(14, 0, 0x50), //1
        addi(15, 0, 1), //   2
        slli(15, 15, 63), //3
        orr(14, 14, 15), //  4 x14 = hgatp
        csrw(0x680, 14), //  5 csrw hgatp, x14
        addi(6, 0, 0x40), // 6 x6 = 0x40 (mtvec handler)
        csrw(0x305, 6), //   7 csrw mtvec, x6
        lui(13, 0x20), //    8 x13 = 0x20000
        hlvw(
          11,
          13,
        ), //     9 hlv.w a1, (a3) -> G-leaf U=0 -> page fault -> mtvec
        0x00000013, //      10 nop (0x28, skipped by trap)
        0x00000013,
        0x00000013,
        0x00000013,
        0x00000013,
        0x00000013, // 11-15 fill
        csrr(0x342, 5), //  16 @0x40 handler: x5 = mcause (== 21 guest load PF)
        jalLoop, //         17 @0x44 loop
      ]);
      return coreTest(
        '@0\n$prog\n'
        '@10000\n${pte(0x4401)}\n'
        '@11000\n${pte(0x4801)}\n'
        '@12100\n${pte(0xC00F)}\n'
        '@40000\n${pte(0xCAFEF00D)}\n'
        '@50000\n${pte(0x14401)}\n'
        '@51000\n${pte(0x14801)}\n'
        '@52080\n${pte(0x401F)}\n'
        '@52088\n${pte(0x441F)}\n'
        '@52090\n${pte(0x481F)}\n'
        '@52180\n${pte(0x1000F)}\n', // data-page G-leaf: V|R|W|X but U=0
        {Register.x5: 21}, // mcause == loadGuestPageFault (G-stage fault)
        config,
        initRegisters: {Register.x10: 0x8000000000000010},
        nextPc: 0x44,
      );
    },
  );
}
