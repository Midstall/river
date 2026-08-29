import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// All-zero-instruction trap regression.
///
/// The RISC-V ISA reserves the 16-bit encoding 0x0000 as a guaranteed-illegal
/// instruction, specifically so a jump into zeroed memory faults at once instead
/// of running forward. On the delta board the kernel booted past scounteren,
/// then a bad control transfer sent the PC into a zeroed region and the core
/// SLED forward two bytes at a time for hundreds of MB without ever trapping.
/// That is only possible if the core decodes 0x0000 as a nop rather than an
/// illegal instruction. This test pins the required behaviour: fetching 0x0000
/// must raise an illegal-instruction trap (cause 2) and vector to mtvec.
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
    'fetching 0x0000 raises illegal-instruction (cause 2), not a silent nop',
    () async {
      await Simulator.reset();
      // mtvec = 0x40 (direct). At 0x04 sits 0x0000 (illegal compressed). A
      // correct core vectors to 0x40 and mcause reads 2. A core that treats
      // 0x0000 as a nop instead runs the 0xAA sentinel at 0x08 and never traps.
      final program = <int, int>{
        0x00: 0x30571073, // csrw mtvec, x14   (x14 = 0x40)
        0x04: 0x00000000, // 0x0000: illegal compressed instruction -> trap
        0x08: 0x0aa00393, // addi x7, x0, 0xAA (sentinel: must NOT run)
        0x40: 0x342022f3, // handler: csrr x5, mcause  (== 2)
        0x44: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        {Register.x5: 2}, // illegal-instruction cause
        _rc1f(),
        initRegisters: {Register.x14: 0x40},
        nextPc: 0x48,
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );
}
