import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Dual-dispatch bring-up: two instructions rename/allocate per cycle. Uses the
/// speculative front-end + PRF operand datapath; gated by issueWidth==dual.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig dualConfig() => RiverCoreConfig(
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
    issueWidth: IssueWidth.dual,
  );

  // Like dualConfig but with the icache + back-edge prediction, so a loop runs
  // speculatively (no per-iteration flush) and many bundles are in flight at
  // once, the condition under which ALU1 and the branch/CSR unit complete the
  // same cycle. With a shared wakeup port that collision dropped a wakeup and
  // deadlocked; the dedicated 3rd wakeup port fixes it.
  RiverCoreConfig dualSpecConfig() => RiverCoreConfig(
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
    issueWidth: IssueWidth.dual,
    l1cache: HarborL1CacheConfig.split(
      iSize: 32,
      dSize: 64,
      ways: 1,
      lineSize: 4,
    ),
    branchPredictor: BranchPredictor.btfn,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int r(int f7, int rs2, int rs1, int f3, int rd) =>
      (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33;
  int b(int imm, int rs2, int rs1, int f3) =>
      (((imm >> 12) & 0x1) << 31) |
      (((imm >> 5) & 0x3F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      (((imm >> 1) & 0xF) << 8) |
      (((imm >> 11) & 0x1) << 7) |
      0x63;
  String prog(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  // M2: four mutually independent adds. Each consecutive pair should
  // co-dispatch (slot 0 + slot 1) and retire. Verifies the 2-wide
  // fetch→decode→rename→ROB/IQ→dual-commit path end to end.
  test(
    'dual-dispatch retires independent ALU pairs',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x111, 0, 0x0, 1), // addi x1, x0, 0x111
        iimm(0x222, 0, 0x0, 2), // addi x2, x0, 0x222
        iimm(0x333, 0, 0x0, 3), // addi x3, x0, 0x333
        iimm(0x444, 0, 0x0, 4), // addi x4, x0, 0x444
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {
        Register.x1: 0x111,
        Register.x2: 0x222,
        Register.x3: 0x333,
        Register.x4: 0x444,
      },
      dualConfig(),
      nextPc: 0x2C,
    ),
  );

  // M3: intra-bundle RAW, slot 1 depends on slot 0. Rename redirects slot1's
  // source to slot0's pdst and the PRF/wakeup forwards the value.
  test(
    'dual-dispatch handles intra-bundle RAW (slot1 ← slot0)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x10, 0, 0x0, 1), // addi x1, x0, 0x10
        iimm(0x20, 1, 0x0, 2), // addi x2, x1, 0x20  -> 0x30
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x1: 0x10, Register.x2: 0x30},
      dualConfig(),
      nextPc: 0x28,
    ),
  );

  // M4: dual-dispatch mixed with a taken branch. The branch must dispatch in
  // slot 0 alone (eligibility forbids co-dispatching past a control transfer),
  // redirect correctly, and the surrounding independent adds still pair up.
  test(
    'dual-dispatch with a taken branch (eligibility + redirect)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1), // 0x00 addi x1, x0, 5
        iimm(5, 0, 0x0, 2), // 0x04 addi x2, x0, 5
        b(8, 2, 1, 0x0), // 0x08 beq x1, x2, +8 -> taken, skip 0x0C
        iimm(99, 0, 0x0, 5), // 0x0C addi x5, x0, 99  (SKIPPED)
        iimm(7, 0, 0x0, 3), // 0x10 addi x3, x0, 7  (target)
        iimm(8, 0, 0x0, 4), // 0x14 addi x4, x0, 8
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {
        Register.x1: 5,
        Register.x2: 5,
        Register.x3: 7,
        Register.x4: 8,
        Register.x5: 0, // skipped by the branch
      },
      dualConfig(),
      nextPc: 0x38,
    ),
  );

  // M5: dual-dispatch + dual-commit together. A multi-cycle mul stalls at the
  // ROB head while independent adds behind it dual-dispatch and queue; when the
  // mul retires they retire alongside it. Exercises both 2-wide lanes + the
  // multi-cycle ALU + slot-1 commit.
  test(
    'dual-dispatch retires a backlog behind a multi-cycle mul',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(6, 0, 0x0, 1), // addi x1, x0, 6
        iimm(7, 0, 0x0, 2), // addi x2, x0, 7
        r(0x01, 2, 1, 0x0, 3), // mul  x3, x1, x2 -> 42
        iimm(1, 1, 0x0, 4), // addi x4, x1, 1 -> 7
        iimm(2, 1, 0x0, 5), // addi x5, x1, 2 -> 8
        iimm(3, 1, 0x0, 6), // addi x6, x1, 3 -> 9
        iimm(4, 1, 0x0, 7), // addi x7, x1, 4 -> 10
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {
        Register.x1: 6,
        Register.x2: 7,
        Register.x3: 42,
        Register.x4: 7,
        Register.x5: 8,
        Register.x6: 9,
        Register.x7: 10,
      },
      dualConfig(),
      nextPc: 0x3C,
    ),
  );

  // M6: long independent loop body (16 adds) run speculatively with the icache +
  // back-edge prediction. Regression guard for the wakeup-port collision that
  // deadlocked dual-dispatch on long bodies, without the dedicated 3rd wakeup
  // port this never reaches nextPc (hangs at the 5000-cycle cap). x20 counts the
  // iterations down to 0; each iteration rewrites x1..x16 to their constants.
  test(
    'dual-dispatch long body (16 adds) does not deadlock',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      prog([
        iimm(3, 0, 0x0, 20), // 0x00 addi x20, x0, 3  (iteration count)
        for (var k = 1; k <= 16; k++)
          iimm(k, 0, 0x0, k), // 0x04..0x40 addi xk, x0, k
        iimm(-1, 20, 0x0, 20), // 0x44 addi x20, x20, -1
        b(-68, 0, 20, 0x1), // 0x48 bne x20, x0, -68 -> back to 0x04
        ...List.filled(10, 0x00000013), // nop tail
      ]),
      {for (var k = 1; k <= 16; k++) Register.values[k]: k, Register.x20: 0},
      dualSpecConfig(),
      // A few nops past the loop exit (0x4C). The completion sentinel must be a
      // PC the dual-commit core actually lands on: when two instructions retire
      // together, nextPc skips the second's PC. After the loop-exit flush the
      // buffer resumes single-issue for one instruction, so the nop pairing is
      // 0x4c, then (0x50,0x54), (0x58,0x5c)... nextPc hits 0x50 and 0x58 but
      // not 0x54. 0x58 is a stable landing point in the nop tail. (Register
      // checks below are the real correctness assertion.)
      nextPc: 0x58,
    ),
  );
}
