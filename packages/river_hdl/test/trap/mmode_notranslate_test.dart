import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// M-mode data accesses must NOT be translated, even when supervisor has enabled
/// paging (satp.MODE != 0). River has no mstatus.MPRV, so an M-mode load/store
/// is always physical. Before the fix the MMU walked M-mode loads/stores through
/// the supervisor page tables the moment satp was set: on the delta board the
/// SBI firmware (Weir, M-mode) restored its stack in a trap handler right after
/// the kernel enabled Sv39, the physical stack address was not a valid VA, and
/// the walk hung the core. Here satp points at a bogus root; a translated access
/// would fault/miss, a physical (bypassed) access reads the real value.
RiverCoreConfig _rc1f() => RiverCoreConfigV1.small(
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
    'M-mode load with Sv39 satp set reads physical (no translation)',
    () async {
      await Simulator.reset();
      // csrw satp, x11 (x11 = Sv39 mode + bogus root PPN=1). Then ld x7, 0(x12)
      // from physical 0x200 which holds 0xABCD. In M-mode the access must bypass
      // paging and read 0xABCD; a page-table walk would read a garbage PTE.
      final program = <int, int>{
        0x00: 0x18059073, // csrw satp, x11
        0x04: 0x00063383, // ld x7, 0(x12)
        0x08: 0x00000013, // nop
        0x200: 0x0000abcd, // data at physical 0x200 (low word)
        0x204: 0x00000000, // high word
      };
      await coreTest(
        _memString(program),
        {Register.x7: 0xabcd},
        _rc1f(),
        initRegisters: {
          Register.x11: 0x8000000000000001, // satp: Sv39, root PPN 1
          Register.x12: 0x200,
        },
        nextPc: 0x0c,
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );
}
