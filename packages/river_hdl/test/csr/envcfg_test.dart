import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// senvcfg (0x10A) / menvcfg (0x30A) environment-configuration CSR regression.
///
/// Linux 6.x accesses senvcfg from the context-switch path (envcfg_update_bits)
/// and probes it in try_to_set_pmm/tagged_addr_init; OpenSBI/Weir touch menvcfg.
/// River omitted both. An access to an unimplemented CSR raises ILLEGAL, so the
/// kernel would trap (the same failure shape as the earlier scounteren gap).
///
/// River implements none of the envcfg-controlled features (Zicbo CBIE/CBCFE/
/// CBZE, pointer-masking PMM, Sstc STCE, Svpbmt PBMTE), so every field is
/// WARL-0: writes drop, reads return 0. That is the correct "feature absent"
/// report; e.g. try_to_set_pmm reads PMM back as 0 and disables pointer masking.
RiverCoreConfig _rc1s() => RiverCoreConfigV1.small(
  mmu: HarborMmuConfig(
    mxlen: RiscVMxlen.rv64,
    pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
    hasSupervisorUserMemory: true,
    hasMakeExecutableReadable: true,
  ),
  interrupts: [],
  clock: const HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(12000000),
  ),
  resetVector: 0,
);

String _memString(Map<int, int> words) {
  const nop = 0x00000013;
  final maxAddr = words.keys.reduce((a, b) => a > b ? a : b);
  final sb = StringBuffer('@0\n');
  for (var addr = 0; addr <= maxAddr + 4; addr += 4) {
    final w = words[addr] ?? nop;
    for (var b = 0; b < 4; b++) {
      sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
  }
  return sb.toString();
}

void main() {
  test(
    'menvcfg (M) + senvcfg (S) are legal and WARL-0 (write all-ones -> read 0)',
    () async {
      await Simulator.reset();
      // M-mode: write menvcfg all-ones, read back (expect 0). Then drop to S
      // (MPP=S via mret) and do the same for senvcfg. A missing CSR would trap
      // illegal and x7 would never reach 0x99.
      final program = <int, int>{
        0x00: 0x30A69073, // csrw menvcfg, x13  (x13 = all ones)
        0x04: 0x30A02373, // csrr x6, menvcfg
        0x08: 0x34151073, // csrw mepc, x10
        0x0c: 0x30059073, // csrw mstatus, x11  (MPP=S)
        0x10: 0x30200073, // mret -> S-mode @ 0x40
        0x40: 0x10A61073, // csrw senvcfg, x12  (S-mode; x12 = all ones)
        0x44: 0x10A022f3, // csrr x5, senvcfg
        0x48: 0x09900393, // addi x7, x0, 0x99
        0x4c: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        // Both read back 0 (all fields WARL-0); x7=0x99 proves neither access
        // trapped.
        {Register.x5: 0x0, Register.x6: 0x0, Register.x7: 0x99},
        _rc1s(),
        initRegisters: {
          Register.x10: 0x40,
          Register.x11: 0x800,
          Register.x12: 0xffffffff,
          Register.x13: 0xffffffff,
        },
        nextPc: 0x4c,
      );
    },
    timeout: Timeout(Duration(minutes: 6)),
  );
}
