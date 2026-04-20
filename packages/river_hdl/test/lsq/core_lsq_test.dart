import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Load-store queue (Phase 1: storeQueue mode). Stores buffer in the queue and
/// drain to memory in program order at commit; a load waits for the queue to
/// drain before reading the bus, so a load right after a same-address store sees
/// the stored value with NO separation nops (the case that needs a store-
/// visibility gap without an LSQ). See project_hdl_lsq.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig lsqConfig() => RiverCoreConfig(
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
    loadStoreQueue: LoadStoreQueue.storeQueue,
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

  // Store then load the SAME address with no separation nops. The load must
  // wait for the store to drain, then read 0x123, not stale memory.
  test(
    'LSQ: store then load same address (no visibility gap)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100  (base addr)
        iimm(0x123, 0, 0x0, 5), // addi x5, x0, 0x123   (value)
        s(0, 5, 10, 0x2), // sw x5, 0(x10)        mem[0x100]=0x123
        lw(0, 10, 6), // lw x6, 0(x10)        x6 = 0x123 (waits for drain)
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x10: 0x100, Register.x5: 0x123, Register.x6: 0x123},
      lsqConfig(),
      nextPc: 0x20,
      memStates: {0x100: 0x123},
      memLatency: 2,
    ),
  );

  // Store then two loads of the same address: both loads wait for the queue to
  // drain and read the stored value (exercises the background drain feeding two
  // consecutive dependent loads).
  test(
    'LSQ: store then two loads of the same address',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100
        iimm(0xAA, 0, 0x0, 5), // addi x5, x0, 0xAA
        s(0, 5, 10, 0x2), // sw x5, 0(x10)   mem[0x100]=0xAA
        lw(0, 10, 7), // lw x7, 0(x10)   x7 = 0xAA
        lw(0, 10, 8), // lw x8, 0(x10)   x8 = 0xAA
        ...List.filled(10, 0x00000013), // nop tail
      ]),
      {
        Register.x10: 0x100,
        Register.x5: 0xAA,
        Register.x7: 0xAA,
        Register.x8: 0xAA,
      },
      lsqConfig(),
      nextPc: 0x3C,
      memStates: {0x100: 0xAA},
      memLatency: 2,
    ),
  );

  // Two stores to different addresses, then a load of each back. Both stores
  // drain in program order in the background; each load waits for the queue to
  // empty and reads its value. (memLatency 0 like the other OoO memory tests,
  // a long store-drain stall lets the speculative front-end run off the end of
  // this tiny program, an artifact of the nop-tail harness, not the core.)
  test(
    'LSQ: two stores, two loads (different addresses)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100
        iimm(0x200, 0, 0x0, 11), // addi x11, x0, 0x200
        iimm(0xAA, 0, 0x0, 5), // addi x5, x0, 0xAA
        iimm(0xBB, 0, 0x0, 6), // addi x6, x0, 0xBB
        s(0, 5, 10, 0x2), // sw x5, 0(x10)   mem[0x100]=0xAA
        s(0, 6, 11, 0x2), // sw x6, 0(x11)   mem[0x200]=0xBB
        lw(0, 10, 7), // lw x7, 0(x10)   x7 = 0xAA
        lw(0, 11, 8), // lw x8, 0(x11)   x8 = 0xBB
        ...List.filled(10, 0x00000013), // nop tail
      ]),
      {
        Register.x10: 0x100,
        Register.x11: 0x200,
        Register.x7: 0xAA,
        Register.x8: 0xBB,
      },
      lsqConfig(),
      nextPc: 0x44,
      memStates: {0x100: 0xAA, 0x200: 0xBB},
    ),
  );
}
