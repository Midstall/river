import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Load-store queue Phase 2: store→load forwarding. A load whose address is
/// covered by an in-queue store takes the value directly (no bus, no waiting for
/// the store to drain); a non-aliasing load reads the bus immediately; the
/// youngest aliasing store wins. See project_hdl_lsq.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig fwdConfig() => RiverCoreConfig(
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

  // Store then load the same address: the load FORWARDS from the queue (the
  // store has not drained yet, memLatency 2, so a bus read would be stale).
  test(
    'fwd: store then load same address forwards',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100
        iimm(0x123, 0, 0x0, 5), // addi x5, x0, 0x123
        s(0, 5, 10, 0x2), // sw x5, 0(x10)
        lw(0, 10, 6), // lw x6, 0(x10)  -> 0x123 (forwarded)
        ...List.filled(8, 0x00000013),
      ]),
      {Register.x10: 0x100, Register.x5: 0x123, Register.x6: 0x123},
      fwdConfig(),
      nextPc: 0x20,
      memStates: {0x100: 0x123},
      memLatency: 2,
    ),
  );

  // Two stores to the SAME address, then a load: the YOUNGEST store's value is
  // forwarded.
  test(
    'fwd: youngest aliasing store wins',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100
        iimm(0xAA, 0, 0x0, 5), // addi x5, x0, 0xAA
        iimm(0xBB, 0, 0x0, 6), // addi x6, x0, 0xBB
        s(0, 5, 10, 0x2), // sw x5, 0(x10)   (older)
        s(0, 6, 10, 0x2), // sw x6, 0(x10)   (younger)
        lw(0, 10, 7), // lw x7, 0(x10)  -> 0xBB (youngest)
        ...List.filled(8, 0x00000013),
      ]),
      {Register.x10: 0x100, Register.x7: 0xBB},
      fwdConfig(),
      nextPc: 0x2C,
      memStates: {0x100: 0xBB},
      memLatency: 2,
    ),
  );

  // Non-aliasing load reads the bus immediately (no forward, no wait): store to
  // 0x100, load from preloaded 0x200.
  test(
    'fwd: non-aliasing load reads memory',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100
        iimm(0x200, 0, 0x0, 11), // addi x11, x0, 0x200
        iimm(0x123, 0, 0x0, 5), // addi x5, x0, 0x123
        s(0, 5, 10, 0x2), // sw x5, 0(x10)   mem[0x100]=0x123
        lw(0, 11, 7), // lw x7, 0(x11)  -> 0xDEAD (from memory)
        ...List.filled(8, 0x00000013),
      ])}@200\nad de 00 00\n',
      {Register.x10: 0x100, Register.x7: 0xDEAD},
      fwdConfig(),
      nextPc: 0x28,
      memStates: {0x100: 0x123},
      memLatency: 2,
    ),
  );

  // Two stores to different addresses, two loads: each load forwards from its
  // own store with no waiting (memLatency 0, like the other OoO memory tests).
  test(
    'fwd: two stores, two loads each forward',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100
        iimm(0x200, 0, 0x0, 11), // addi x11, x0, 0x200
        iimm(0xAA, 0, 0x0, 5), // addi x5, x0, 0xAA
        iimm(0xBB, 0, 0x0, 6), // addi x6, x0, 0xBB
        s(0, 5, 10, 0x2), // sw x5, 0(x10)   mem[0x100]=0xAA
        s(0, 6, 11, 0x2), // sw x6, 0(x11)   mem[0x200]=0xBB
        lw(0, 10, 7), // lw x7, 0(x10)  -> 0xAA
        lw(0, 11, 8), // lw x8, 0(x11)  -> 0xBB
        ...List.filled(10, 0x00000013),
      ]),
      {
        Register.x10: 0x100,
        Register.x11: 0x200,
        Register.x7: 0xAA,
        Register.x8: 0xBB,
      },
      fwdConfig(),
      nextPc: 0x44,
      memStates: {0x100: 0xAA, 0x200: 0xBB},
    ),
  );
}
