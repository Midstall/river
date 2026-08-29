import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// The full HW scenario, never tested together in sim before:
/// PAGING (superpage) + I-cache EVICTION of the return line + SLOW refill +
/// redirect. rc1-f I-cache is 64B direct-mapped, 8x8B, index=addr[5:3].
///
///   csrw satp; jal ->0x1000
///   0x1000 addi x6,x0,0x11
///   0x1004 auipc ra,0           ra=0x1004
///   0x1008 jalr  ra,0x44(ra)    call 0x1048 (index 1, EVICTS the 0x1008 line
///                               that holds the return target 0x100c), ra=0x100c
///   0x100c auipc a0,0           RETURN TARGET -> paged MISS + slow refill
///   0x1010 jal   x0,0           park
///   0x1048 jalr  x0,0(ra)       ret -> 0x100c
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

  String prog() => mem({
    0x00: [0x18051073, 0x7FD0006F],
    0x1000: [0x01100313, 0x00000097, 0x044080e7, 0x00000517, 0x0000006f],
    0x1048: [0x00008067],
    0x10000: [0x00004401, 0x0],
    0x11000: [0x0000000F, 0x0],
  });

  for (final lat in [0, 10, 20]) {
    test(
      'paged+evict+redirect refill, memLatency=$lat',
      timeout: Timeout(Duration(minutes: 8)),
      () => coreTest(
        prog(),
        {Register.x6: 0x11, Register.x10: 0x100c},
        full(),
        startPriv: PrivilegeMode.supervisor,
        initRegisters: {Register.x10: 0x8000000000000010},
        nextPc: 0x1010,
        memLatency: lat,
      ),
    );
  }
}
