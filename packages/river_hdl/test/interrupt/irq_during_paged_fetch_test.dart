import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Repro attempt closest to the real delta boot (task #87 regression): an
/// M-timer interrupt taken while the core runs in S-MODE with Sv39 PAGING ON,
/// so the in-flight instruction fetch involves a page-table WALK (a data access)
/// plus an I-cache refill. The interrupt-take squashing that translated fetch
/// mid-walk is the one interrupt scenario not yet covered (all prior repros were
/// bare mode). Linux takes the RCU/scheduler timer tick in exactly this state.
///
/// M-mode prologue sets mtvec/mie(MTIE)/mstatus(MPP=S,MPIE)/satp(Sv39)/mepc then
/// mret to S-mode @VA 0x1000. S-mode paged code jumps through COLD pages (each a
/// TLB+I-cache miss -> walk+refill). The timer IRQ is raised mid-chain. If it
/// vectors to the M handler @0x200 (x28<-0xAB) the core is fine; if the fetch
/// handshake wedges it never reaches nextPc.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig cfg() => RiverCoreConfigV1.full(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
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

  const park = 0x0000006f;

  String prog() => mem({
    // ---- M-mode prologue @phys 0x0 (bare) ----
    0x00000: [
      0x30529073, // 0x00 csrw mtvec, x5   (=0x200 handler PA)
      0x30431073, // 0x04 csrw mie,   x6   (MTIE = 1<<7)
      0x30039073, // 0x08 csrw mstatus,x7  (MPP=S 1<<11 | MPIE 1<<7)
      0x18041073, // 0x0c csrw satp,  x8   (Sv39, root PPN 0x10)
      0x34149073, // 0x10 csrw mepc,  x9   (=0x1000 S entry VA)
      0x30200073, // 0x14 mret -> S-mode @VA 0x1000, paging on
    ],
    // ---- M-mode timer handler @phys 0x200 ----
    0x00200: [0x0ab00e13, park], // addi x28,x0,0xAB ; park @0x204
    // ---- S-mode paged code (VA==phys, identity mapped) ----
    0x01000: [jal(0, 0x1000)], // 0x1000 -> 0x2000 cold page
    0x02000: [jal(0, 0x1000)], // 0x2000 -> 0x3000 cold page
    0x03000: [jal(0, 0x1000)], // 0x3000 -> 0x4000 cold page
    0x04000: [jal(0, 0x1000)], // 0x4000 -> 0x5000 cold page
    0x05000: [park], //           0x5000 park (reached only if NO interrupt)
    // ---- Sv39 page table (root 0x10000), identity VA 0x1000..0x5000 ----
    0x10000: [0x00004401, 0x0], // L2[0] -> L1 @0x11000
    0x11000: [0x00004801, 0x0], // L1[0] -> L0 @0x12000
    0x12000: [
      0x00000000, 0x0, // L0[0] VA0x0    unmapped
      0x0000040f, 0x0, // L0[1] VA0x1000 -> phys0x1000 (V R W X)
      0x0000080f, 0x0, // L0[2] VA0x2000 -> phys0x2000
      0x00000c0f, 0x0, // L0[3] VA0x3000 -> phys0x3000
      0x0000100f, 0x0, // L0[4] VA0x4000 -> phys0x4000
      0x0000140f, 0x0, // L0[5] VA0x5000 -> phys0x5000
    ],
  });

  final init = {
    Register.x5: 0x200, // mtvec (M handler, direct)
    Register.x6: 1 << 7, // MTIE
    Register.x7: (1 << 11) | (1 << 7), // MPP=S | MPIE
    Register.x8: 0x8000000000000010, // satp Sv39 root PPN 0x10
    Register.x9: 0x1000, // mepc = S entry VA
  };

  test(
    'control: M->S mret + Sv39 paged jump chain runs to park (no IRQ)',
    timeout: Timeout(Duration(minutes: 5)),
    () {
      return coreTest(
        prog(),
        {},
        cfg(),
        initRegisters: init,
        nextPc: 0x5000,
        maxCycles: 3000,
        memLatency: 8,
      );
    },
  );

  // Run each IRQ timing in ISOLATION (-n) to avoid ROHD accumulation - a single
  // sweep run gives false timeouts. Each is its own test.
  for (final at in const [40, 48, 56, 64, 72, 80]) {
    test(
      'timer IRQ during S-mode paged fetch vectors to handler (raiseAt=$at)',
      timeout: Timeout(Duration(minutes: 5)),
      () {
        return coreTest(
          prog(),
          {Register.x28: 0xAB},
          cfg(),
          initRegisters: init,
          nextPc: 0x204,
          maxCycles: 3000,
          memLatency: 8,
          raiseTimerIrqAt: at,
        );
      },
    );
  }
}
