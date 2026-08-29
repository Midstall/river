import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Repro for the delta NixOS boot wedge (task #88): the kernel's page-directory
/// switch trampoline (relocate_enable_mmu family) does
///     sfence.vma ; csrw satp, 0 (disable paging) ; auipc ...
/// The instruction right AFTER `csrw satp, 0` must be fetched with paging OFF
/// (a plain bare physical fetch). On delta River instead walked it with the
/// stale paging-ON satp and took a spurious instruction page fault on the now
/// physical (unmapped-as-a-VA) PC, then wedged.
///
/// This isolates the hazard: run paged (Sv39), put `csrw satp, x0` at the end of
/// a MAPPED page (VA 0x1000 -> phys 0x1000), and the next instruction on the
/// NEXT page (VA/phys 0x2000) which is deliberately UNMAPPED under the active
/// satp. With paging correctly disabled the fetch of 0x2000 is a bare physical
/// access to real code (x6 <- 0x22). If the disable does not take effect for
/// that fetch, VA 0x2000 is unmapped -> instruction page fault, x6 stays 0.
///
/// Layout (all identity for what is mapped):
///   phys 0x0000  csrw satp, a0    enable Sv39 (a0 seeded = 0x8..0010)
///   phys 0x0004  jal  x0, +0x1FF8 -> VA 0x1FFC (end of the mapped page)
///   phys 0x1FFC  csrw satp, x0    disable paging (bare)
///   phys 0x2000  addi x6, x0,0x22 <- bare-only fetch, the test
///   phys 0x2004  jal  x0, 0       park
/// Page table (Sv39, root 0x10000): VA 0x0 -> phys 0x0, VA 0x1000 -> phys 0x1000,
///   VA 0x2000 UNMAPPED.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // small (RV64IMAC microcode, no FPU) shares the fetch/MMU/CSR datapath with
  // delta's full rc1-f but elaborates/sims much faster - the satp fetch hazard
  // lives in that shared logic, so it reproduces here too.
  RiverCoreConfig full() => RiverCoreConfigV1.small(
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
  );

  int jal(int rd, int off) {
    final b20 = (off >> 20) & 1;
    final b10_1 = (off >> 1) & 0x3ff;
    final b11 = (off >> 11) & 1;
    final b19_12 = (off >> 12) & 0xff;
    return (b20 << 31) |
        (b10_1 << 21) |
        (b11 << 20) |
        (b19_12 << 12) |
        (rd << 7) |
        0x6f;
  }

  String mem(Map<int, List<int>> words) {
    final sb = StringBuffer();
    final addrs = words.keys.toList()..sort();
    for (final a in addrs) {
      sb.writeln('@${a.toRadixString(16)}');
      for (final w in words[a]!) {
        for (var i = 0; i < 4; i++) {
          sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    return sb.toString();
  }

  String prog() => mem({
    0x0000: [0x18051073, jal(0, 0x1FF4)], // csrw satp,a0 ; jal ->0x1FF8
    // Block starts at the 8-byte-aligned 0x1FF8 (loadMemString aligns block
    // starts down to 8B): filler nop @0x1FF8, then csrw satp, a1 @0x1FFC.
    // csrw satp, a1 (a1=0, disable) - NOT `csrw satp, x0` (0x18001073), which
    // River skips (rs1=x0 no-write); the real relocate_enable_mmu trampoline
    // uses a register holding 0.
    0x1FF8: [
      0x12000073,
      0x18059073,
    ], //  sfence.vma @0x1FF8 ; csrw satp,a1 @0x1FFC
    0x2000: [0x02200313, 0x0000006f], //     addi x6,x0,0x22 ; park
    0x10000: [0x00004401, 0x0], //           L2[0] -> L1 @0x11000
    0x11000: [0x00004801, 0x0], //           L1[0] -> L0 @0x12000
    0x12000: [
      0x0000000F, 0x0, //  L0[0] VA0x0    -> phys0x0   (V R W X)
      0x0000040F, 0x0, //  L0[1] VA0x1000 -> phys0x1000
      0x00000000, 0x0, //  L0[2] VA0x2000 UNMAPPED
    ],
  });

  test(
    'csrw satp,0 disable takes effect for the very next fetch (bare)',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x6: 0x22},
      full(),
      startPriv: PrivilegeMode.supervisor,
      initRegisters: {Register.x10: 0x8000000000000010}, // a0 = Sv39 root 0x10
      nextPc: 0x2004,
      maxCycles: 700, // wedge fails fast instead of grinding the full budget
    ),
  );
}
