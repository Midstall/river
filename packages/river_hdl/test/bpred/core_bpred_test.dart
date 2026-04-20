import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Branch-predictor correctness: with BTFN prediction the architectural results
/// must be identical to no-prediction, prediction only changes timing. Covers
/// a backward branch (predicted taken), a forward taken branch (predicted
/// not-taken → misprediction recovery), and JAL (predicted taken).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig bpred() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvZicsr, rvZifencei, rvM],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv32,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    executionMode: ExecutionMode.outOfOrder,
    speculativeFetch: true,
    branchPredictor: BranchPredictor.btfn,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int b(int imm, int rs2, int rs1, int f3) =>
      (((imm >> 12) & 0x1) << 31) |
      (((imm >> 5) & 0x3F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      (((imm >> 1) & 0xF) << 8) |
      (((imm >> 11) & 0x1) << 7) |
      0x63;
  int jal(int imm, int rd) =>
      (((imm >> 20) & 0x1) << 31) |
      (((imm >> 1) & 0x3FF) << 21) |
      (((imm >> 11) & 0x1) << 20) |
      (((imm >> 12) & 0xFF) << 12) |
      (rd << 7) |
      0x6F;
  String prog(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var i = 0; i < 4; i++) {
        sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  // Backward branch (loop), BTFN predicts taken (correct for all but the last
  // iteration). Result must be x1=0, x2=3.
  test(
    'bpred: counted loop (predicted-taken back-edge)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(3, 0, 0x0, 1), // addi x1, x0, 3
        iimm(0, 0, 0x0, 2), // addi x2, x0, 0
        iimm(1, 2, 0x0, 2), // loop: addi x2, x2, 1   <- target 0x08
        iimm(-1, 1, 0x0, 1), // addi x1, x1, -1
        b(-8, 0, 1, 0x1), // bne x1, x0, -8 -> 0x08 while x1!=0
        ...List.filled(11, 0x00000013), // nop tail
      ]),
      {Register.x1: 0, Register.x2: 3},
      bpred(),
      nextPc: 0x3C,
    ),
  );

  // Forward taken branch, BTFN predicts NOT-taken, so this exercises the
  // misprediction recovery (flush + redirect at commit). x3 must be skipped.
  test(
    'bpred: forward taken branch (mispredict recovery)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1), // addi x1, x0, 5
        iimm(5, 0, 0x0, 2), // addi x2, x0, 5
        b(8, 2, 1, 0x0), // beq x1, x2, +8 -> taken (forward), skip 0x0C
        iimm(99, 0, 0x0, 3), // addi x3, x0, 99 (SKIPPED)
        iimm(7, 0, 0x0, 4), // addi x4, x0, 7 (target 0x10)
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x1: 5, Register.x2: 5, Register.x3: 0, Register.x4: 7},
      bpred(),
      nextPc: 0x34,
    ),
  );

  // JAL, BTFN predicts taken; link + skip must be correct.
  test(
    'bpred: JAL (predicted taken) with link',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1), // addi x1, x0, 5
        jal(8, 3), // jal x3, +8 -> link x3=0x08, jump 0x0C
        iimm(99, 0, 0x0, 4), // addi x4, x0, 99 (SKIPPED)
        iimm(7, 0, 0x0, 2), // addi x2, x0, 7 (target 0x0C)
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x1: 5, Register.x2: 7, Register.x3: 0x08, Register.x4: 0},
      bpred(),
      nextPc: 0x30,
    ),
  );
}
