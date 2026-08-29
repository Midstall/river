import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// HW-observed on delta: after the trampoline fault-jumps into HIGH virtual,
/// River raises instructionPageFault on a VALID high-virtual (0xffffffff8...)
/// instruction fetch through a 2MB L1-leaf megapage (Linux relocate_enable_mmu
/// label 1). The mapping is valid+X+A+D and the DRAM holds the right bytes, yet
/// the fetch faults. This isolates that: enable Sv39, jump to a high-virtual
/// address mapped by a 2MB L1 leaf, and require the target executes (a correct
/// core reaches the park; buggy River never does because it faults).
///
///   phys 0x00 (identity via a 1GB root leaf, runs before/after satp):
///     0x00 csrw satp, a0        enable Sv39
///     0x04 lui  t0, 0xc0000     t0 = 0xffffffffc0000000 (sign-extended)
///     0x08 jalr x0, 0(t0)       jump to HIGH virtual 0xffffffffc0000000
///   phys 0x200000 (= virt 0xffffffffc0000000 via a 2MB L1 leaf):
///     addi x6, x0, 0x11
///     jal  x0, 0                park (= virt 0xffffffffc0000004)
///
/// Page tables (Sv39, root @ 0x10000):
///   root[0]   = 0x000000EF  1GB leaf, virt 0x0..0x3fffffff -> phys identity
///   root[511] = 0x00004401  non-leaf -> L1_high @ 0x11000
///   L1_high[0]= 0x000800EF  2MB leaf, virt 0xffffffffc0000000 -> phys 0x200000
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig full() => RiverCoreConfigV1.full(
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

  // Direct jalr to the EXACT HW address 0xffffffff80001048 (VPN2=510, offset
  // 0x1048 into a 2MB L1 leaf), NO preceding fault. Isolates address vs the
  // trampoline fault-then-trap sequence.
  //   0x00 csrw satp,a0 ; 0x04 lui t0,0x80001 ; 0x08 addi t0,t0,0x48 ;
  //   0x0c jalr x0,0(t0)  -> 0xffffffff80001048
  String prog() => mem({
    0x00: [0x18051073, 0x800012b7, 0x04828293, 0x00028067],
    0x10000: [0x000000EF, 0x0], // root[0] 1GB leaf identity low
    0x10ff0: [0x00004401, 0x0], // root[510] -> L1_high
    0x11000: [0x000800EF, 0x0], // L1_high[0] 2MB leaf -> phys 0x200000
    0x201048: [0x01100313, 0x0000006f], // addi x6,0x11 ; park (offset 0x1048)
  });

  test(
    'high-virtual 2MB-megapage instruction fetch executes (no spurious fault)',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x6: 0x11},
      full(),
      startPriv: PrivilegeMode.supervisor,
      initRegisters: {Register.x10: 0x8000000000000010},
      nextPc: 0xffffffff8000104c,
    ),
  );
}
