import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// LSQ Phase 3: speculative loads + disambiguation/replay. Loads may execute
/// ahead of a not-ready older store; a load queue records them, and when the
/// store resolves its address it CAMs the queue, a younger aliasing load that
/// read too early triggers a replay (re-fetch from after the store). See
/// project_hdl_lsq.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig specConfig() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvM, rvZicsr, rvZifencei],
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
    loadStoreQueue: LoadStoreQueue.speculative,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int r(int f7, int rs2, int rs1, int f3, int rd) =>
      (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33;
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

  // Store then two loads of the same address: both forward / read the store.
  test(
    'spec: store then two loads same address',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10),
        iimm(0xAA, 0, 0x0, 5),
        s(0, 5, 10, 0x2),
        lw(0, 10, 7),
        lw(0, 10, 8),
        ...List.filled(10, 0x00000013),
      ]),
      {Register.x7: 0xAA, Register.x8: 0xAA},
      specConfig(),
      nextPc: 0x3C,
      memStates: {0x100: 0xAA},
    ),
  );

  // Two stores, two loads to distinct addresses.
  test(
    'spec: two stores, two loads distinct addresses',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10),
        iimm(0x200, 0, 0x0, 11),
        iimm(0xAA, 0, 0x0, 5),
        iimm(0xBB, 0, 0x0, 6),
        s(0, 5, 10, 0x2),
        s(0, 6, 11, 0x2),
        lw(0, 10, 7),
        lw(0, 11, 8),
        ...List.filled(10, 0x00000013),
      ]),
      {Register.x7: 0xAA, Register.x8: 0xBB},
      specConfig(),
      nextPc: 0x44,
      memStates: {0x100: 0xAA, 0x200: 0xBB},
    ),
  );

  // DISAMBIGUATION REPLAY: the store's data comes from a multi-cycle mul, so the
  // store is not ready when the load (whose address is ready early) executes.
  // The load speculatively reads 0x100 (stale), the mul resolves, the store
  // executes and CAMs the load queue → violation → replay → the load re-reads
  // the stored value (42). Without the replay it would keep the stale 0.
  test(
    'spec: load bypasses slow store, replays on violation',
    timeout: Timeout(Duration(seconds: 90)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100
        iimm(7, 0, 0x0, 1), // addi x1, x0, 7
        iimm(6, 0, 0x0, 4), // addi x4, x0, 6
        r(0x01, 4, 1, 0x0, 5), // mul x5, x1, x4 -> 42 (multi-cycle)
        s(0, 5, 10, 0x2), // sw x5, 0(x10)   (data x5 late -> store not ready)
        lw(0, 10, 6), // lw x6, 0(x10)   bypasses; replays -> 42
        ...List.filled(10, 0x00000013),
      ]),
      {Register.x10: 0x100, Register.x5: 42, Register.x6: 42},
      specConfig(),
      nextPc: 0x40,
      memStates: {0x100: 42},
    ),
  );
}
