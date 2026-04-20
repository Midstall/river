import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// OoO privileged return delivery (task #75, Step B), isolated in M-mode (no
/// paging). Sets mepc + mstatus.MPP=M, executes mret, and checks the fetch
/// redirects to mepc and the wrong-path instruction right after mret is flushed
/// (it would clobber x5 if not squashed). Before #75 the OoO commit path set
/// isReturn=0, so mret was a silent no-op and execution fell through.
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
    'OoO: mret redirects to mepc and flushes the wrong-path successor',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      // mepc = 0x40 (target). MPP=3 (machine) so mret stays in M-mode.
      final prog = words([
        addi(14, 0, 0x40), // 0  x14 = 0x40
        csrw(0x341, 14), //   1  csrw mepc, x14
        addi(12, 0, 3), //    2  x12 = 3
        slli(12, 12, 11), //  3  x12 = 0x1800 (mstatus.MPP = 3 = machine)
        csrw(0x300, 12), //   4  csrw mstatus, x12
        mret, //              5  @0x14 mret -> pc = mepc = 0x40, mode = M
        addi(5, 0, 0xFF), //  6  @0x18 WRONG PATH: clobbers x5 if not flushed
        nop, nop, nop, nop, nop, nop, nop, nop, nop, // 7-15
        addi(5, 0, 0xAB), // 16  @0x40 correct target: x5 = 0xAB
        jalLoop, //          17  @0x44 loop
      ]);
      return coreTest(
        '@0\n$prog\n',
        {Register.x5: 0xAB}, // proves mret landed at 0x40 and 0x18 was squashed
        config,
        nextPc: 0x44,
      );
    },
  );
}
