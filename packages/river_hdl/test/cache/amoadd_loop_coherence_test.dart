import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Faithful repro of the delta ticket-lock corruption: run the REAL amoadd
/// micro-op, through the REAL D-cache (rc1-f full config includes the split L1),
/// in a tight loop against ONE cached address, and require every increment to
/// land. On HW two amoadds lost an increment (a ticket ended up behind the
/// owner). The differential matrix cannot catch this: it drives a simple
/// MemoryModel, not the D-cache. Data lives at 0x80001000 (>= cacheableBase
/// 0x80000000) so it is actually cached; code runs from low (uncached).
///
///   x5 = 0x80001000 (target), x7 = 1 (increment), x8 = N (count)
///   loop: amoadd.w.aqrl x6, x7, (x5)   ; mem[x5] += 1, x6 = old
///         addi x8, x8, -1
///         bnez x8, loop
///         jal  x0, 0                    ; park
void main() {
  test(
    'amoadd.w.aqrl loop through the real D-cache never loses an increment',
    timeout: Timeout(Duration(minutes: 6)),
    () async {
      const n = 40;
      // amoadd.w.aqrl x6,x7,(x5): opcode 0x2f, f3=2, funct7=0x03 (amoadd aq=rl=1),
      // rs2=7, rs1=5, rd=6.
      const amoaddAqrl =
          (0x03 << 25) | (7 << 20) | (5 << 15) | (2 << 12) | (6 << 7) | 0x2f;
      final program = <int, int>{
        0x00: 0x00100393, // addi x7, x0, 1
        0x04:
            (n << 20) | (0 << 15) | (0 << 12) | (8 << 7) | 0x13, // addi x8,x0,N
        0x08: amoaddAqrl, // loop: amoadd.w.aqrl x6,x7,(x5)
        0x0c: 0xfff40413, // addi x8, x8, -1
        0x10: 0xfe041ce3, // bnez x8, -8 (back to 0x08)
        0x14: 0x0000006f, // jal x0, 0 (park)
      };
      // Emit one contiguous block from @0.
      final sb = StringBuffer('@0\n');
      final maxA = program.keys.reduce((a, b) => a > b ? a : b);
      for (var addr = 0; addr <= maxA + 4; addr += 4) {
        final w = program[addr] ?? 0x00000013;
        for (var b = 0; b < 4; b++) {
          sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }

      await coreTest(
        sb.toString(),
        {
          Register.x6: n - 1, // last amoadd returns the previous value (N-1)
          Register.x8: 0,
        },
        RiverCoreConfigV1.full(
          interrupts: [],
          mmu: HarborMmuConfig(
            mxlen: RiscVMxlen.rv64,
            pagingModes: const [RiscVPagingMode.bare],
            tlbLevels: const [],
            pmp: HarborPmpConfig.none,
          ),
          clock: const HarborClockConfig(
            name: 'sysclk',
            rate: HarborFixedClockRate(48000000),
          ),
        ),
        initRegisters: {Register.x5: 0x80001000},
        // final memory at 0x80001000 must be exactly N (no lost increments)
        memStates: {0x80001000: n},
        nextPc: 0x14,
      );
    },
  );
}
