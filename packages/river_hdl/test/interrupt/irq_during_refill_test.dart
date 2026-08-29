import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import 'dart:async';

import '../core_harness.dart';

/// Repro for the delta NixOS boot wedge (task #87 regression). The boot got
/// FARTHER before async interrupt-taking was added; it now bus-hangs at random
/// function entries once timer interrupts start firing (RCU init). Hypothesis:
/// an async interrupt taken at an instruction boundary redirects the fetch to
/// tvec WHILE an L1I cold-line REFILL is in flight; the refill response is never
/// consumed and the fetch handshake deadlocks. The #87 test only ran
/// readLatency:0 + a tight spin loop, so it never had a refill in flight.
///
/// Built on the proven coreTest harness (handles latency + cold-line jumps).
/// Program: enable the machine timer interrupt, then jump through a chain of
/// COLD cache lines (constant refills). A timer IRQ is raised mid-chain (during
/// a refill). If the core vectors to the handler @0x200 it is fine; if it wedges
/// it never reaches nextPc.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig cfg() => RiverCoreConfigV1.full(
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

  int jal(int rd, int off) =>
      (((off >> 20) & 1) << 31) |
      (((off >> 1) & 0x3ff) << 21) |
      (((off >> 11) & 1) << 20) |
      (((off >> 12) & 0xff) << 12) |
      (rd << 7) |
      0x6f;

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

  const nop = 0x00000013;
  const park = 0x0000006f;

  // Enable-interrupts prologue @0x0, cold-line jump chain, handler @0x200.
  String prog() => mem({
    0x00000: [
      nop, nop, //                     0x00,0x04 warmup
      0x30529073, //                   0x08 csrw mtvec, x5 (=0x200)
      0x30431073, //                   0x0c csrw mie, x6   (MTIE = 1<<7)
      0x3003a073, //                   0x10 csrs mstatus, x7 (MIE = 1<<3)
      jal(0, 0x4000 - 0x14), //        0x14 -> 0x4000 cold
    ],
    0x00200: [0x0ab00e13, park], //    handler: addi x28,x0,0xAB ; park @0x204
    0x04000: [jal(0, 0x4000)], //      0x4000 -> 0x8000 cold
    0x08000: [jal(0, 0x4000)], //      0x8000 -> 0xC000 cold
    0x0C000: [jal(0, 0x4000)], //      0xC000 -> 0x10000 cold
    0x10000: [park], //                park (reached only if NO interrupt)
  });

  final init = {
    Register.x5: 0x200, // mtvec (direct)
    Register.x6: 1 << 7, // MTIE
    Register.x7: 1 << 3, // MIE
  };

  test(
    'control: cold-line chain runs to park at latency=8 (no IRQ)',
    timeout: Timeout(Duration(minutes: 4)),
    () {
      return coreTest(
        prog(),
        {},
        cfg(),
        initRegisters: init,
        nextPc: 0x10000,
        maxCycles: 2000,
        memLatency: 8,
      );
    },
  );

  // Sweep WHEN the timer IRQ is raised so it lands during a cold-line refill.
  for (final at in const [20, 26, 32, 38, 44, 50, 56, 62]) {
    test(
      'timer IRQ during cold-line refill vectors to handler (raiseAt=$at)',
      timeout: Timeout(Duration(minutes: 4)),
      () {
        // If the interrupt vectors cleanly, x28=0xAB and nextPc=0x204 (handler
        // park). If the fetch handshake wedges, neither is reached.
        return coreTest(
          prog(),
          {Register.x28: 0xAB},
          cfg(),
          initRegisters: init,
          nextPc: 0x204,
          maxCycles: 2000,
          memLatency: 8,
          raiseTimerIrqAt: at,
        );
      },
    );
  }
}
