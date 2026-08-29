import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// The bug the identity-mapped repros never caught: instruction fetch through a
/// NON-IDENTITY page mapping. With `translateFetch` gated off behind the icache,
/// the VIVT icache refills from the UNTRANSLATED virtual address, so a mapping
/// where virtual != physical fetches garbage. This is exactly Linux's swapper
/// (virtual 0xffffffff8000xxxx -> physical 0x8aaxxxxx).
///
///   0x00 csrw satp, a0           enable Sv39
///   0x04 auipc t0, 0x3           t0 = 0x3004
///   0x08 jalr  x0, -4(t0)        jump to VIRTUAL 0x3000
///   @phys 0x1000 (= virt 0x3000 via L0[3]->PPN1, NON-IDENTITY):
///     0x1000 addi x6, x0, 0x11
///     0x1004 jal  x0, 0          park  (= virtual 0x3004)
///
/// Page tables (Sv39, identity for low code + one non-identity 4KB leaf):
///   L2[0]@0x10000 = 0x4401  ; L1[0]@0x11000 = 0x4801 ; L0@0x12000
///   L0[0]@0x12000 = 0x000F  (virt 0x0    -> phys 0x0)
///   L0[3]@0x12018 = 0x040F  (virt 0x3000 -> phys 0x1000)  NON-IDENTITY
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
    0x00: [0x18051073, 0x00003297, 0xFFC28067],
    0x1000: [0x01100313, 0x0000006f],
    0x10000: [0x00004401, 0x0],
    0x11000: [0x00004801, 0x0],
    0x12000: [0x0000000F, 0x0],
    0x12018: [0x0000040F, 0x0],
  });

  test(
    'non-identity paged fetch: virt 0x3000 -> phys 0x1000 decodes',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x6: 0x11},
      full(),
      startPriv: PrivilegeMode.supervisor,
      initRegisters: {Register.x10: 0x8000000000000010},
      nextPc: 0x3004,
    ),
  );
}
