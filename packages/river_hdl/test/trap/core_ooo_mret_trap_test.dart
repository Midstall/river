import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// OoO trap + return composed (task #75) without paging/translated fetch: mret
/// to M-mode (Step B) lands at mepc, where an illegal-CSR access raises an
/// exception that vectors to mtvec (Step A). Confirms the two deliveries compose
/// in M-mode; the remaining S-mode+paging fault path is a separate OoO gap.
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
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  );

  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x1 << 12) | 0x73;
  int csrrw(int csr, int rs1, int rd) =>
      (csr << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x73;
  int csrr(int csr, int rd) => (csr << 20) | (0x2 << 12) | (rd << 7) | 0x73;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  const mret = 0x30200073;
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

  test(
    'OoO: mret lands, then an illegal-CSR trap vectors to mtvec (compose)',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      // mret target = 0x20; mtvec = 0x40. After mret runs to 0x20, the illegal
      // CSR there traps to 0x40 where mcause (==2) is read into x5.
      final prog = words([
        addi(14, 0, 0x20), // 0  x14 = 0x20 (mepc)
        csrw(0x341, 14), //   1  csrw mepc, x14
        addi(12, 0, 3), //    2
        slli(12, 12, 11), //  3  x12 = 0x1800 (MPP=3=M)
        csrw(0x300, 12), //   4  csrw mstatus, x12
        addi(13, 0, 0x40), // 5  x13 = 0x40 (mtvec)
        csrw(0x305, 13), //   6  csrw mtvec, x13
        mret, //              7  @0x1C mret -> pc = 0x20, M-mode
        csrrw(0xBFF, 0, 1), //8  @0x20 illegal CSR -> trap (cause 2) to mtvec
        nop, nop, nop, nop, nop, nop, // 9-14
        nop, //              15
        csrr(0x342, 5), //   16  @0x40 handler: x5 = mcause (== 2)
        jalLoop, //          17  @0x44 loop
      ]);
      return coreTest('@0\n$prog\n', {Register.x5: 2}, config, nextPc: 0x44);
    },
  );
}
