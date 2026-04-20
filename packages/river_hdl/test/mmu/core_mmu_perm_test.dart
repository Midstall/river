import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// MMU stage-2: leaf U-bit / SUM permission checks. A supervisor-mode load from
/// a user page (PTE.U=1) with mstatus.SUM=0 must take a load page fault. (M-mode
/// accesses bypass the U-check, which is why the other MMU tests are unaffected.)
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final config = RiverCoreConfig(
    mxlen: RiscVMxlen.rv64,
    extensions: kRva22S64Extensions,
    type: RiverCoreType.general,
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  );

  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x1 << 12) | 0x73;
  int csrr(int csr, int rd) => (csr << 20) | (0x2 << 12) | (rd << 7) | 0x73;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  int lui(int rd, int imm20) => (imm20 << 12) | (rd << 7) | 0x37;
  int ld(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x03;
  const jalLoop = 0x0000006F;
  const nop = 0x00000013;

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
    'S-mode load of a user page (U=1, no SUM) faults',
    timeout: Timeout(Duration(seconds: 120)),
    () {
      final prog = words([
        csrw(0x180, 10), //  0 csrw satp, a0 (Sv39 | root 0x10)
        addi(11, 0, 0x24), //1 x11 = 0x24 (mepc = the load region)
        csrw(0x341, 11), //  2 csrw mepc, x11
        addi(12, 0, 1), //   3
        slli(12, 12, 11), // 4 x12 = 0x800 (MPP=S, MPV=0 -> virt=0)
        csrw(0x300, 12), //  5 csrw mstatus, x12
        addi(14, 0, 0x40), //6 x14 = 0x40 (mtvec)
        csrw(0x305, 14), //  7 csrw mtvec, x14
        0x30200073, //       8 @0x20 mret -> S-mode, pc=0x24
        lui(13, 0x20), //    9 @0x24 a3 = 0x20000
        ld(5, 13, 0), //    10 @0x28 S-mode load of a U=1 page -> page fault
        nop, nop, nop, nop, nop, //  11-15 @0x2c..0x3c
        csrr(0x342, 5), //  16 @0x40 handler: x5 = mcause (== 13 loadPageFault)
        jalLoop, //         17 @0x44 loop
      ]);
      return coreTest(
        '@0\n$prog\n'
        '@10000\n${pte(0x4401)}\n'
        '@11000\n${pte(0x4801)}\n'
        // l0[0]: identity-map virtual page 0 -> PA 0 as a supervisor RX page so the
        // S-mode code (after mret) can be fetched through translation (V|R|X, U=0).
        '@12000\n${pte(0x00B)}\n'
        '@12100\n${pte(0xC01F)}\n' // l0[32] leaf: V|R|W|X|U=1 -> user page
        '@30000\n${pte(0xCAFEF00D)}\n',
        {Register.x5: 13}, // loadPageFault: S-mode denied the user page
        config,
        initRegisters: {Register.x10: 0x8000000000000010},
        nextPc: 0x44,
      );
    },
  );
}
