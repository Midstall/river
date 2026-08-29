import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// sfence.vma must be implemented by any S-mode core (rc1-f/delta has S-mode
/// via rvPriv but no hypervisor). It was previously defined ONLY in the
/// hypervisor extension (rvH), so delta did not decode it: the kernel's
/// relocate_enable_mmu runs sfence.vma around the satp write, and without it the
/// first fetch after paging is enabled mis-translates and the core runs off the
/// rails. This pins the fix: sfence.vma decodes and executes (TLB fence, PC+4),
/// it does NOT raise an illegal-instruction trap.
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
    'sfence.vma is legal (executes, advances pc) not an illegal trap',
    () async {
      await Simulator.reset();
      // sfence.vma (0x12000073, rs1=rs2=0) then a sentinel. If sfence.vma were
      // unimplemented it would trap and x7 would never reach 0x99.
      final program = <int, int>{
        0x00: 0x12000073, // sfence.vma
        0x04: 0x09900393, // addi x7, x0, 0x99
        0x08: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        {Register.x7: 0x99},
        _rc1f(),
        nextPc: 0x0c,
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );
}
