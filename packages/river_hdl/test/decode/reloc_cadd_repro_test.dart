import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// HW-observed on delta: Linux relocate_enable_mmu computes stvec as a relocated
/// address by ADDING the va->pa offset a1 to a PC-relative label. Two adjacent
/// `c.add rd, a1` with the SAME a1:
///   0x1014  c.add ra, a1   -> ra relocates correctly (HIGH virtual)  ✓
///   0x101e  c.add a2, a1   -> a2 does NOT get a1 added  ✗  (stvec stays LOW)
/// so the trampoline fetch-fault traps back to the low PC forever. This isolates
/// that pattern at the SAME instruction alignment (the two c.add at word-offset
/// 4 and 6, the auipc/addi 4-byte ops between them) and asserts the lanes=2
/// microcode adds a1 in BOTH, matching lanes=1 (the proven reference).
RiverCoreConfig cfg(int lanes) => RiverCoreConfig(
  clock: HarborClockConfig(
    name: 'sysclk',
    rate: HarborFixedClockRate(48000000),
  ),
  mxlen: RiscVMxlen.rv64,
  extensions: [rvC, rvZicsr, rvZifencei, rvM, rv64i, rv32i],
  interrupts: [],
  mmu: HarborMmuConfig(
    mxlen: RiscVMxlen.rv64,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  ),
  type: RiverCoreType.general,
  executionMode: ExecutionMode.inOrder,
  issueWidth: IssueWidth.single,
  microcodeMode: MicrocodeMode.full,
  microcodeDecodeLanes: lanes,
);

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Program mirrors relocate_enable_mmu 0x1012..0x1028 at the same low offsets.
  // 0x00..0x11 padded with c.nop so the critical ops sit at 0x14/0x16/0x1a/0x1e.
  //   0x12 c.nop
  //   0x14 c.add ra, a1     (0x90ae)
  //   0x16 auipc a2, 0x0    (0x00000617)
  //   0x1a addi  a2, a2, 50 (0x03260613)
  //   0x1e c.add a2, a1     (0x962e)
  //   0x20 ori   s0, a2, 0  (0x00066413)  capture a2
  //   0x24 ori   s1, ra, 0  (0x0000e493)  capture ra
  //   0x28 jal   x0, 0      park
  String prog() {
    final sb = StringBuffer('@0\n');
    void h16(int v) {
      sb.write((v & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
      sb.write(((v >> 8) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }

    void h32(int v) {
      for (var i = 0; i < 4; i++) {
        sb.write(((v >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }

    for (var i = 0; i < 9; i++) {
      h16(0x0001); // c.nop  (0x00..0x11)
    }
    h16(0x0001); // 0x12 c.nop
    h16(0x90ae); // 0x14 c.add ra, a1
    h32(0x00000617); // 0x16 auipc a2, 0x0
    h32(0x03260613); // 0x1a addi a2, a2, 50
    h16(0x962e); // 0x1e c.add a2, a1
    h32(0x00066413); // 0x20 ori s0, a2, 0
    h32(0x0000e493); // 0x24 ori s1, ra, 0
    h32(0x0000006f); // 0x28 jal x0, 0 (park)
    sb.writeln();
    return sb.toString();
  }

  // a1 = 0xffffffff00000000 (the va->pa offset high bits). ra seeded 0.
  // lanes=1 reference result:
  //   ra = 0 + a1                = 0xffffffff00000000  -> s1
  //   a2 = 0x16 + 50 + a1        = 0xffffffff00000048  -> s0
  const a1 = 0xffffffff00000000; // fits int64 bit-pattern (negative in Dart)
  const expectS0 = 0xffffffff00000048;
  const expectS1 = 0xffffffff00000000;

  test(
    'lanes=1: both c.add relocate (reference)',
    timeout: Timeout(Duration(minutes: 5)),
    () async {
      await coreTest(
        prog(),
        {Register.x8: expectS0, Register.x9: expectS1},
        cfg(1),
        initRegisters: {Register.x11: a1},
        nextPc: 0x28,
      );
    },
  );

  test(
    'lanes=2: both c.add MUST relocate (matches lanes=1)',
    timeout: Timeout(Duration(minutes: 5)),
    () async {
      await coreTest(
        prog(),
        {Register.x8: expectS0, Register.x9: expectS1},
        cfg(2),
        initRegisters: {Register.x11: a1},
        nextPc: 0x28,
      );
    },
  );

  // The delta boot config: full rc1-f (lanes=2 + VIVT icache + microcode). The
  // icache changes how instructions reach the packed decoder, which may be the
  // trigger the no-icache cfg misses.
  test(
    'full() rc1-f: both c.add MUST relocate',
    timeout: Timeout(Duration(minutes: 6)),
    () async {
      await coreTest(
        prog(),
        {Register.x8: expectS0, Register.x9: expectS1},
        RiverCoreConfigV1.full(
          interrupts: [],
          mmu: HarborMmuConfig(
            mxlen: RiscVMxlen.rv64,
            pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
            tlbLevels: const [],
            pmp: HarborPmpConfig.none,
            hasSupervisorUserMemory: true,
            hasMakeExecutableReadable: true,
          ),
          clock: const HarborClockConfig(
            name: 'sysclk',
            rate: HarborFixedClockRate(48000000),
          ),
        ),
        initRegisters: {Register.x11: a1},
        nextPc: 0x28,
      );
    },
  );
}
