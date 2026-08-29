import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// scounteren / mcounteren counter-enable CSR regression.
///
/// On real hardware the Linux RISC-V head code writes `csrw scounteren, t0`
/// (0x10629073) before it installs its own trap vector. River implemented
/// S-mode (satp/sstatus/sie/...) but omitted scounteren (0x106) and mcounteren
/// (0x306). An access to an unimplemented CSR raises ILLEGAL instruction, so the
/// write trapped and the delta board stopped at Weir's diagnostic sink
/// (scause=2 sepc=0x8aa010ea) the first time the kernel ran from DRAM.
///
/// The privileged spec requires scounteren when S-mode exists and mcounteren
/// when U-mode exists. Both gate lower-privilege access to cycle/time/instret,
/// so only bits CY/TM/IR (2:0) are writable; the HPM bits are WARL-0.
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

// Emit ONE contiguous block from @0, gaps filled with nop. A per-word `@addr`
// form makes SparseMemoryStorage take sub-8-byte writes that mis-pack a word
// holding zero bytes, so a zero-heavy instruction reads back corrupted. A single
// contiguous load never triggers that.
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
    'csrw scounteren from S-mode is legal and WARL-masks to CY/IR (TM off)',
    () async {
      await Simulator.reset();
      // Drop to S (MPP=S), then write scounteren with all-ones and read it back.
      // A missing CSR would trap illegal here and x7 would never reach 0x99.
      final program = <int, int>{
        0x00: 0x34151073, // csrw mepc, x10
        0x04: 0x30059073, // csrw mstatus, x11  (MPP=S)
        0x08: 0x30200073, // mret
        0x40: 0x10661073, // csrw scounteren, x12   (S-mode; x12 = all ones)
        0x44: 0x106022f3, // csrr x5, scounteren
        0x48: 0x09900393, // addi x7, x0, 0x99
        0x4c: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        // scounteren reads back 0x5: HPM bits masked off, CY|IR kept, TM
        // WARL-0 (no native `time` CSR; rdtime is SBI-emulated).
        {Register.x5: 0x5, Register.x7: 0x99},
        _rc1s(),
        initRegisters: {
          Register.x10: 0x40,
          Register.x11: 0x800,
          Register.x12: 0xffffffff,
        },
        nextPc: 0x50,
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );

  test(
    'csrw mcounteren from M-mode is legal and WARL-masks to CY/IR (TM off)',
    () async {
      await Simulator.reset();
      final program = <int, int>{
        0x00: 0x30661073, // csrw mcounteren, x12   (M-mode; x12 = all ones)
        0x04: 0x306022f3, // csrr x5, mcounteren
        0x08: 0x09900393, // addi x7, x0, 0x99
        0x0c: 0x00000013, // nop
      };
      await coreTest(
        _memString(program),
        {Register.x5: 0x5, Register.x7: 0x99},
        _rc1s(),
        initRegisters: {Register.x12: 0xffffffff},
        nextPc: 0x10,
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );
}
