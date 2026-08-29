import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Strongest remaining hypothesis for the delta intermittent wedge (#91): an
/// async timer interrupt taken while a LOAD or AMO is mid page-table WALK. Every
/// prior integrity repro ran in bare mode; irq_during_paged_fetch covers the
/// FETCH walk, but the DATA-side walk of a load/amo has never been interrupted
/// in sim. Linux takes the scheduler/RCU tick in exactly this state: satp on,
/// S-mode, a load of a live pointer in flight. If the interrupt-take does not
/// cleanly abort and re-issue the data walk, the load's destination register
/// gets a stale/garbage value, the corrupted-pointer root of the misaligned
/// amoor.d / duplicate-ticket HW wedge.
///
/// M prologue -> mret to S-mode @VA0x1000 (paging on). S code loads from three
/// COLD pages (each a fresh TLB miss -> data walk) and does an amoadd, then jal
/// to park. A timer IRQ is fired across a cycle sweep so the take lands during a
/// data walk; the M handler sets x28 and MRETs back. Every loaded value MUST
/// survive regardless of IRQ timing. A divergence pinpoints the bug.
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
  int ld(int rd, int rs1) => (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
  // amoadd.d rd, rs2, (rs1)
  int amoaddD(int rd, int rs2, int rs1) =>
      (rs2 << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2F;

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
  const mret = 0x30200073;

  // Data words as two 32-bit halves (little-endian dword).
  List<int> dword(int lo, int hi) => [lo, hi];

  String prog() => mem({
    // ---- M-mode prologue @phys 0x0 (bare) ----
    0x00000: [
      0x30529073, // csrw mtvec, x5   (=0x200 handler PA)
      0x30431073, // csrw mie,   x6   (MTIE = 1<<7)
      0x30039073, // csrw mstatus,x7  (MPP=S 1<<11 | MPIE 1<<7)
      0x18041073, // csrw satp,  x8   (Sv39, root PPN 0x10)
      0x34149073, // csrw mepc,  x9   (=0x1000 S entry VA)
      mret, // -> S-mode @VA 0x1000, paging on
    ],
    // ---- M-mode timer handler @phys 0x200: mark x28, MRET back ----
    0x00200: [0x0ab00e13, mret],
    // ---- S-mode paged code @VA 0x1000 ----
    0x01000: [
      ld(18, 20), // x18 = *(VA 0x2000) cold -> data walk
      ld(19, 21), // x19 = *(VA 0x3000) cold -> data walk
      amoaddD(22, 23, 24), // x22 = old *(VA 0x4000); *0x4000 += x23
      ld(25, 24), // x25 = *(VA 0x4000) post-amo
      jal(0, 0x5000 - 0x1010), // -> park @VA 0x5000
    ],
    0x05000: [park],
    // ---- data pages (identity mapped) ----
    0x02000: dword(0x1111, 0), // *0x2000 = 0x1111
    0x03000: dword(0x2222, 0), // *0x3000 = 0x2222
    0x04000: dword(0x3333, 0), // *0x4000 = 0x3333
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
    Register.x5: 0x200, // mtvec (M handler)
    Register.x6: 1 << 7, // MTIE
    Register.x7: (1 << 11) | (1 << 7), // MPP=S | MPIE
    Register.x8: 0x8000000000000010, // satp Sv39 root PPN 0x10
    Register.x9: 0x1000, // mepc = S entry VA
    Register.x20: 0x2000, // load ptr A
    Register.x21: 0x3000, // load ptr B
    Register.x23: 0x10, // amoadd addend
    Register.x24: 0x4000, // amo/load ptr C
  };

  final expected = {
    Register.x18: 0x1111, // *0x2000
    Register.x19: 0x2222, // *0x3000
    Register.x22: 0x3333, // old *0x4000 (amoadd returns old)
    Register.x25: 0x3343, // *0x4000 post-amo (0x3333 + 0x10)
  };

  test(
    'control: paged loads+amo run to park (no IRQ)',
    timeout: Timeout(Duration(minutes: 5)),
    () {
      return coreTest(
        prog(),
        expected,
        cfg(),
        initRegisters: init,
        nextPc: 0x5000,
        maxCycles: 4000,
        memLatency: 8,
      );
    },
  );

  // Fire the IRQ across the window where the data walks are in flight. Each is
  // its own isolated test (ROHD accumulation makes a single sweep give false
  // timeouts). The M handler MRETs back, the interrupted load/amo re-issues its
  // walk, and every loaded value MUST match [expected]. A mismatch = the take
  // corrupted a data-walk load's rd (the wedge root).
  for (final at in const [24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112]) {
    test(
      'timer IRQ during S-mode paged data walk preserves loads (raiseAt=$at)',
      timeout: Timeout(Duration(minutes: 5)),
      () {
        return coreTest(
          prog(),
          expected,
          cfg(),
          initRegisters: init,
          nextPc: 0x5000,
          maxCycles: 4000,
          memLatency: 8,
          raiseTimerIrqAt: at,
          lowerTimerIrqAt: at + 4,
        );
      },
    );
  }
}
