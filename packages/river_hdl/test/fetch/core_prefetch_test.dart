import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Increment 2 of the prefetch fetcher: PrefetchFetchUnit wired into the
/// single-issue speculative OoO front-end (RiverCoreConfig.prefetchFetch = true).
/// This is the FAITHFUL test environment, the fetch port is the real MMU, whose
/// valid/done behave like the bus the read engine targets (unlike the standalone
/// unit test's MemoryModel). Re-runs representative speculative programs and
/// checks the architectural result matches the classic-fetcher runs in
/// core_ooo_test. See project_hdl_prefetch.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig prefetchConfig() => RiverCoreConfig(
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
    commitWidth: IssueWidth.dual,
    speculativeFetch: true,
    prefetchFetch: true,
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

  test(
    'prefetch: straight-line RAW chain forwards in-flight operands',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(1, 0, 0x0, 1),
        iimm(1, 1, 0x0, 2),
        iimm(1, 2, 0x0, 3),
        iimm(1, 3, 0x0, 4),
        iimm(1, 4, 0x0, 5),
        ...List.filled(8, 0x00000013),
      ]),
      {
        Register.x1: 1,
        Register.x2: 2,
        Register.x3: 3,
        Register.x4: 4,
        Register.x5: 5,
      },
      prefetchConfig(),
      nextPc: 0x34,
    ),
  );

  test(
    'prefetch: speculative overlaps a multi-cycle mul with a backlog',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(6, 0, 0x0, 1),
        iimm(7, 0, 0x0, 2),
        r(0x01, 2, 1, 0x0, 3), // mul x3 = 42 (multi-cycle)
        iimm(1, 1, 0x0, 4),
        iimm(2, 1, 0x0, 5),
        iimm(3, 1, 0x0, 6),
        iimm(4, 1, 0x0, 7),
        ...List.filled(8, 0x00000013),
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
      prefetchConfig(),
      nextPc: 0x3C,
    ),
  );

  test(
    'prefetch: counted loop (backward branch redirects)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(3, 0, 0x0, 1), // 0x00 addi x1,x0,3
        iimm(0, 0, 0x0, 2), // 0x04 addi x2,x0,0
        iimm(1, 2, 0x0, 2), // 0x08 addi x2,x2,1   <- target
        iimm(-1, 1, 0x0, 1), // 0x0C addi x1,x1,-1
        b(-8, 0, 1, 0x1), // 0x10 bne x1,x0,-8
        ...List.filled(11, 0x00000013),
      ]),
      {Register.x1: 0, Register.x2: 3},
      prefetchConfig(),
      nextPc: 0x3C,
    ),
  );

  test(
    'prefetch: taken branch redirects past the skipped instruction',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1),
        iimm(5, 0, 0x0, 2),
        b(8, 2, 1, 0x0), // beq taken -> 0x10
        iimm(99, 0, 0x0, 3), // SKIPPED
        iimm(7, 0, 0x0, 4), // target @0x10
        ...List.filled(8, 0x00000013),
      ]),
      {Register.x1: 5, Register.x2: 5, Register.x3: 0, Register.x4: 7},
      prefetchConfig(),
      nextPc: 0x34,
    ),
  );

  test(
    'prefetch: JAL redirects and writes the link register',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1), // 0x00
        jal(8, 3), // 0x04 jal x3,+8 -> link 0x08, jump 0x0C
        iimm(99, 0, 0x0, 4), // 0x08 SKIPPED
        iimm(7, 0, 0x0, 2), // 0x0C target
        ...List.filled(8, 0x00000013),
      ]),
      {Register.x1: 5, Register.x2: 7, Register.x3: 0x08, Register.x4: 0},
      prefetchConfig(),
      nextPc: 0x30,
    ),
  );
}
