import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// HW repro attempt #2 for the delta boot wedge. The straddle theory is
/// disproven (straddle_amo_test all green), so the misaligned `amoor.d` is a
/// genuinely misaligned AMO the kernel issued. RISC-V raises store/AMO-address-
/// misaligned (cause 6) for it; the core must vector to the trap handler and the
/// handler's first fetch (a cold I-cache line) must complete. This exercises
/// exactly that: a misaligned amoor.d -> cause-6 trap -> handler fetch, swept
/// over the handler-fetch miss latency. If the fetch-after-trap wedges (the
/// suspected intermittent hang class), the handler never sets x6.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig cfg() => RiverCoreConfigV1.small(
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

  // csrw mtvec, x5  (mtvec=0x305): direct-mode vector = x5.
  const csrwMtvec = (0x305 << 20) | (5 << 15) | (1 << 12) | 0x73;
  // amoor.d x0, x13, (x12): rs1=x12 holds a MISALIGNED address -> cause 6.
  const amoorD = (0x20 << 25) | (13 << 20) | (12 << 15) | (3 << 12) | 0x2F;
  // addi x6, x0, 0xAB  (handler marker).
  const addiX6 = (0xAB << 20) | (6 << 7) | 0x13;
  const park = 0x0000006F;

  // Word image: 4-byte words at the given byte addresses, emitted as one @0
  // block of space-separated bytes (loadMemString format), gaps zero-filled.
  String memWords(Map<int, int> words) {
    var maxAddr = 0;
    for (final a in words.keys) {
      if (a + 4 > maxAddr) maxAddr = a + 4;
    }
    final bytes = List<int>.filled(maxAddr, 0);
    words.forEach((a, w) {
      for (var i = 0; i < 4; i++) {
        bytes[a + i] = (w >> (i * 8)) & 0xFF;
      }
    });
    final sb = StringBuffer()..writeln('@0');
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    sb.writeln();
    return sb.toString();
  }

  // main: install mtvec, run the misaligned amoor.d (must trap), then a park
  // that we must NOT reach. handler @0x40: set x6=0xAB, park.
  String prog() => memWords({
    0x0: csrwMtvec,
    0x4: amoorD,
    0x8: park, // reached only if the AMO did NOT trap (bug)
    0x40: addiX6,
    0x44: park, // handler park (the pass target)
  });

  // x5 = mtvec handler (0x40); x12 = a MISALIGNED .d address (low 3 bits != 0);
  // x13 = OR operand. mem is untouched because the AMO must trap first.
  final init = {
    Register.x5: 0x40,
    Register.x12: 0x1001, // misaligned for an 8-byte AMO
    Register.x13: 0x20000,
  };

  for (final lat in const [0, 4, 8, 16]) {
    test(
      'misaligned amoor.d traps (cause 6) and the handler fetch completes '
      '(memLatency=$lat)',
      timeout: Timeout(Duration(minutes: 3)),
      () {
        // Reaching 0x44 with x6=0xAB proves: the misaligned AMO trapped, vectored
        // to mtvec, and the handler's cold-line fetch ran to completion.
        return coreTest(
          prog(),
          {Register.x6: 0xAB},
          cfg(),
          initRegisters: init,
          nextPc: 0x44,
          maxCycles: 4000,
          memLatency: lat,
        );
      },
    );
  }
}
