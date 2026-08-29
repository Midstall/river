import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Reproduce the HW illegal-trap by forcing the ONE thing the small repros
/// never did: an I-cache line that is EVICTED by the called function and then
/// SLOW-refilled at the jalr return target.
///
/// rc1-f I-cache is 64B, direct-mapped, 8 lines x 8B (index = addr[5:3]). The
/// return target 0x0c (line 0x08, index 1) is evicted when the called function
/// at 0x48 (index 1, different tag) is fetched. On return, 0x0c is a MISS and
/// refills from memory with `memLatency` cycles -> the refill-vs-decode race at
/// the redirect that fast 1-cycle sim memory hides. HW has real DDR latency, so
/// this mimics it. Bare mode isolates the cache race from paging.
///
///   0x00 addi x6, x0, 0x11
///   0x04 auipc ra, 0            ra = 0x04
///   0x08 jalr  ra, 0x44(ra)     call 0x48, return ra = 0x0c
///   0x0c auipc a0, 0            RETURN TARGET (same cache line as 0x08) -> 0x0c
///   0x10 jal   x0, 0            park
///   0x48 jalr  x0, 0(ra)        ret -> 0x0c  (fetching here evicts the 0x08 line)
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig full() => RiverCoreConfigV1.full(
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
  );

  String prog() {
    final words = <int, int>{
      0x00: 0x01100313, // addi x6, x0, 0x11
      0x04: 0x00000097, // auipc ra, 0
      0x08: 0x044080e7, // jalr ra, 0x44(ra) -> 0x48
      0x0c: 0x00000517, // auipc a0, 0   RETURN TARGET
      0x10: 0x0000006f, // jal x0, 0     park
      0x48: 0x00008067, // jalr x0, 0(ra) ret -> 0x0c
    };
    final maxAddr = 0x48;
    final sb = StringBuffer('@0\n');
    for (var a = 0; a <= maxAddr; a += 4) {
      final w = words[a] ?? 0x00000013; // nop fill
      for (var i = 0; i < 4; i++) {
        sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  for (final lat in [0, 4, 10, 20]) {
    test(
      'icache-evict redirect, memLatency=$lat',
      timeout: Timeout(Duration(minutes: 8)),
      () => coreTest(
        prog(),
        {Register.x6: 0x11, Register.x10: 0x0c},
        full(),
        nextPc: 0x10,
        memLatency: lat,
      ),
    );
  }
}
