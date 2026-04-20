import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// LSQ Phase 4: memory ops co-dispatch in dual-issue slot 1. With a load-store
/// queue, the slot-1 eligibility predicate no longer forbids memory ops, they
/// still leave the issue queue one at a time (single mem port) and execute in
/// program order, so the queue sees them in order and store→load forwarding
/// covers intra-bundle aliasing. See project_hdl_lsq / project_hdl_dualdispatch.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig dualLsqConfig() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvZicsr, rvZifencei],
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
    loadStoreQueue: LoadStoreQueue.forwarding,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int s(int imm, int rs2, int rs1, int f3) =>
      (((imm >> 5) & 0x7F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      ((imm & 0x1F) << 7) |
      0x23;
  int lw(int imm, int rs1, int rd) =>
      (imm << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03;
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

  // Bundles place a memory op in slot 1 (pc+4): a store co-dispatches with an
  // ALU op, then a load co-dispatches with an ALU op, and the load forwards.
  //   0x00 addi x10,x0,0x100   | 0x04 addi x5,x0,0x123     (ALU,ALU)
  //   0x08 addi x6,x0,0x55     | 0x0C sw   x5,0(x10)        (ALU, STORE-in-slot1)
  //   0x10 addi x9,x0,0x77     | 0x14 lw   x7,0(x10)        (ALU, LOAD-in-slot1)
  //   0x18 addi x8,x0,0x66     | 0x1C nop
  test(
    'dual+LSQ: memory ops co-dispatch in slot 1',
    timeout: Timeout(Duration(seconds: 90)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10),
        iimm(0x123, 0, 0x0, 5),
        iimm(0x55, 0, 0x0, 6),
        s(0, 5, 10, 0x2), // sw x5, 0(x10)  (slot 1)
        iimm(0x77, 0, 0x0, 9),
        lw(0, 10, 7), // lw x7, 0(x10)  (slot 1) -> 0x123
        iimm(0x66, 0, 0x0, 8),
        ...List.filled(9, 0x00000013),
      ]),
      {
        Register.x10: 0x100,
        Register.x5: 0x123,
        Register.x6: 0x55,
        Register.x9: 0x77,
        Register.x7: 0x123,
        Register.x8: 0x66,
      },
      dualLsqConfig(),
      nextPc: 0x40,
      memStates: {0x100: 0x123},
    ),
  );

  // Two stores in one bundle (slot0+slot1 both stores) both reach memory: the
  // slot-1 store is held one commit cycle so the store queue's commit pointer
  // tracks each store (a pair retiring together would otherwise under-count).
  // (A load+load bundle still deadlocks, see project_hdl_lsq; WIP.)
  test(
    'dual+LSQ: two stores in one bundle both drain',
    timeout: Timeout(Duration(seconds: 90)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10),
        iimm(0x200, 0, 0x0, 11),
        iimm(0xAA, 0, 0x0, 5),
        iimm(0xBB, 0, 0x0, 6),
        s(0, 5, 10, 0x2), // sw x5,0(x10)   (bundle: store+store)
        s(0, 6, 11, 0x2), // sw x6,0(x11)
        ...List.filled(10, 0x00000013),
      ]),
      {Register.x10: 0x100, Register.x11: 0x200},
      dualLsqConfig(),
      nextPc: 0x40,
      memStates: {0x100: 0xAA, 0x200: 0xBB},
    ),
  );

  // A run mixing store and load bundles: the store pair co-dispatches; the load
  // pair falls back to single dispatch (load+load co-dispatch is disabled) and
  // still reads back the correct values.
  test(
    'dual+LSQ: store and load bundles read back',
    timeout: Timeout(Duration(seconds: 90)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10),
        iimm(0x200, 0, 0x0, 11),
        iimm(0xAA, 0, 0x0, 5),
        iimm(0xBB, 0, 0x0, 6),
        s(0, 5, 10, 0x2),
        s(0, 6, 11, 0x2),
        lw(0, 10, 7), // -> 0xAA
        lw(0, 11, 8), // -> 0xBB
        ...List.filled(10, 0x00000013),
      ]),
      {Register.x7: 0xAA, Register.x8: 0xBB},
      dualLsqConfig(),
      nextPc: 0x44,
      memStates: {0x100: 0xAA, 0x200: 0xBB},
    ),
  );
}
