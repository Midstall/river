import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// OoO load page-fault path (task #73). A faulting load on the out-of-order core
/// used to HANG: the MemoryUnit's request FSM waits for a bus ack that never
/// arrives, because the MMU drives dport_valid=0 (no ack) on a page fault and
/// the FSM had no fault input (wbErr was tied to 0). The fix feeds the dport
/// `done & ~valid` page fault into the MemoryUnit so the access traps at commit.
///
/// Same program + page tables as core_mmu_perm_test (S-mode load of a U=1 page
/// with SUM=0 -> load page fault, mcause 13), but on an outOfOrder config.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final config = RiverCoreConfig(
    mxlen: RiscVMxlen.rv64,
    extensions: kRva22S64Extensions,
    type: RiverCoreType.general,
    executionMode: ExecutionMode.outOfOrder,
    speculativeFetch: true,
    branchPredictor: BranchPredictor.btfn,
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
  int ori(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x13;
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

  // Full OoO supervisor + page-fault path (#77). The satp value is COMPUTED in
  // the program rather than seeded: the initRegisters backdoor writes the
  // architectural regfile, which the OoO core does not read (it reads renamed
  // physical regs), so a seeded satp never reached the MMU and translation never
  // activated. Computing it (and the #76 fix so csrrw is never suppressed as a
  // no-op write) makes satp.MODE=Sv39 reach the MMU, the S-mode load translates,
  // hits the U=1 page with SUM=0, and takes a load page fault that vectors to
  // mtvec where mcause==13.
  test(
    'OoO: S-mode load of a user page faults (traps, does not hang)',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      final prog = words([
        addi(10, 0, 1), //    0 @0x00 x10 = 1
        slli(10, 10, 63), //  1 @0x04 x10 = 1<<63
        ori(10, 10, 0x10), // 2 @0x08 x10 = 0x8000000000000010 (Sv39|root 0x10)
        csrw(0x180, 10), //   3 @0x0c csrw satp, x10
        addi(11, 0, 0x30), // 4 @0x10 mepc target = 0x30 (S-mode entry)
        csrw(0x341, 11), //   5 @0x14 csrw mepc, x11
        addi(12, 0, 1), //    6 @0x18
        slli(12, 12, 11), //  7 @0x1c x12 = 0x800 (MPP=S, MPV=0 -> virt=0)
        csrw(0x300, 12), //   8 @0x20 csrw mstatus, x12
        addi(14, 0, 0x50), // 9 @0x24 x14 = 0x50 (mtvec)
        csrw(0x305, 14), //  10 @0x28 csrw mtvec, x14
        0x30200073, //       11 @0x2c mret -> S-mode, pc=0x30
        lui(13, 0x20), //    12 @0x30 a3 = 0x20000
        ld(5, 13, 0), //     13 @0x34 S-mode load of a U=1 page -> page fault
        nop, nop, nop, nop, nop, nop, // 14-19 @0x38..0x4c
        csrr(0x342, 5), //   20 @0x50 handler: x5 = mcause (== 13 loadPageFault)
        jalLoop, //          21 @0x54 loop
      ]);
      return coreTest(
        '@0\n$prog\n'
        '@10000\n${pte(0x4401)}\n'
        '@11000\n${pte(0x4801)}\n'
        '@12000\n${pte(0x00B)}\n'
        '@12100\n${pte(0xC01F)}\n' // l0[32] leaf: V|R|W|X|U=1 -> user page
        '@30000\n${pte(0xCAFEF00D)}\n',
        {Register.x5: 13}, // loadPageFault: S-mode denied the user page
        config,
        nextPc: 0x54,
      );
    },
  );
}
