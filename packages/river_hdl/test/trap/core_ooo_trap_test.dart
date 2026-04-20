import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// OoO exception delivery (task #75, Step A). A committing synchronous exception
/// on the out-of-order core must redirect the fetch PC to the trap vector
/// (mtvec) and write mcause, the same way the in-order path does. Before #75 the
/// OoO commit path hardcoded nextMode=currentMode and never redirected to mtvec,
/// so a trap was silently dropped.
///
/// M-mode test (the OoO core runs M-mode in tests): set mtvec, then touch an
/// unimplemented CSR -> the CsrUnit raises an illegal-instruction exception
/// (cause 2) -> the commit path vectors to mtvec, the handler reads mcause==2.
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
    'OoO: an illegal-CSR exception vectors to mtvec and sets mcause',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      // mtvec = 0x40 (direct mode, low bits 0). Handler reads mcause.
      final prog = words([
        addi(14, 0, 0x40), // 0  x14 = 0x40
        csrw(0x305, 14), //   1  csrw mtvec, x14
        csrrw(0xBFF, 0, 1), //2  csrrw x1, 0xBFF, x0 -> illegal CSR (cause 2)
        nop, nop, nop, nop, nop, nop, nop, nop, nop, nop, nop, nop, nop, // 3-15
        csrr(0x342, 5), //   16  @0x40 handler: x5 = mcause (== 2)
        jalLoop, //          17  @0x44 loop
      ]);
      return coreTest(
        '@0\n$prog\n',
        {Register.x5: 2}, // illegal instruction cause
        config,
        nextPc: 0x44,
      );
    },
  );
}
