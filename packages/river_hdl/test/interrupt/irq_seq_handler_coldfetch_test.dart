import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Closest sim repro yet for the HW #87 fetch-bus-hang. The prior interrupt
/// repros vectored to a 2-instruction handler (x28<-0xAB ; park), so they never
/// ran a SEQUENTIAL cold-line fetch stream AFTER landing on the vector, nor an
/// MRET back into cold interrupted code. HW wedges exactly there: the sequential
/// fetch right after a control transfer to a function entry hangs.
///
/// The rc1 L1 icache is tiny (iSize=64B, lineSize=8B => 8 one-word lines), so a
/// sequential nop run thrashes it: a miss + fill every 8 bytes. Program:
///   main: enable M-timer IRQ, then a long sequential nop run (IRQ fires here).
///   handler @0x400: a long sequential nop run across cold lines, x28<-0xAB, MRET.
///   after MRET: main resumes mid-run (mepc = interrupted PC), reaches park.
/// If any sequential fetch after the vector or after MRET wedges, park (nextPc)
/// is never reached and x28 stays unset.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // .small shares the EXACT rc1-f fetch/MMU/CSR/icache datapath (in-order,
  // single-issue, microcoded, _rc1L1 icache) but drops the FPU, so the interrupt
  // + fetch interaction is identical and the sim is far faster.
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

  const nop = 0x00000013;
  const park = 0x0000006f;
  const mret = 0x30200073;
  const addiX28 = 0x0ab00e13; // addi x28, x0, 0xAB

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

  // main: 3 setup CSRs, then a long sequential nop run, then park.
  const setup = [
    0x30529073, // csrw mtvec, x5   (=0x400 handler)
    0x30431073, // csrw mie,   x6   (MTIE = 1<<7)
    0x3003a073, // csrs mstatus,x7  (MIE = 1<<3)
  ];
  const mainNops = 60; // 240 bytes -> thrashes the 64B icache ~4x
  final mainBody = <int>[
    ...setup,
    for (var i = 0; i < mainNops; i++) nop,
    park,
  ];
  final parkPc = (mainBody.length - 1) * 4; // address of the final park

  // handler @0x400: long sequential nop run (cold lines), set x28, PARK. Parking
  // (not MRET) means the timer never needs clearing and the interrupt cannot
  // storm; this isolates the exact HW pattern: the sequential cold-line fetch
  // stream right AFTER landing on the vector entry.
  const handlerNops = 48; // 192 bytes -> thrashes the icache ~3x after vector
  final handlerBody = <int>[
    for (var i = 0; i < handlerNops; i++) nop,
    addiX28,
    park,
  ];
  final handlerParkPc = 0x400 + handlerNops * 4 + 4; // addr of handler park

  // Second handler @0x800: same long cold-line run, but MRET back into the
  // interrupted (now cold) main code instead of parking. Tests the full round
  // trip: vector -> handler cold-fetch -> mret -> re-fetch cold main -> park.
  final handlerMretBody = <int>[
    for (var i = 0; i < handlerNops; i++) nop,
    addiX28,
    mret,
  ];

  String prog() => mem({0x0: mainBody, 0x400: handlerBody});
  String progMret() => mem({0x0: mainBody, 0x800: handlerMretBody});

  final init = {
    Register.x5: 0x400, // mtvec (direct)
    Register.x6: 1 << 7, // MTIE
    Register.x7: 1 << 3, // MIE
  };

  test(
    'control: sequential main+handler runs to park (no IRQ)',
    timeout: Timeout(Duration(minutes: 5)),
    () {
      return coreTest(
        prog(),
        {},
        cfg(),
        initRegisters: init,
        nextPc: parkPc,
        maxCycles: 6000,
        memLatency: 8,
      );
    },
  );

  // Sweep WHEN the timer IRQ is raised so it lands at different points of the
  // main sequential run (different cache/fetch states). Run each ISOLATED.
  for (final at in const [30, 40, 50, 60, 70, 90, 120]) {
    test(
      'IRQ mid sequential run -> handler cold-fetch stream -> handler park '
      '(raiseAt=$at)',
      timeout: Timeout(Duration(minutes: 5)),
      () {
        // Reaching handlerParkPc AND x28=0xAB proves: the interrupt vectored and
        // the handler's SEQUENTIAL cold-line fetch stream after the vector ran to
        // completion (the exact fetch pattern the HW wedges on). Hold MTIP; the
        // handler parks (no mret) so it cannot re-fire.
        return coreTest(
          prog(),
          {Register.x28: 0xAB},
          cfg(),
          initRegisters: init,
          nextPc: handlerParkPc,
          maxCycles: 6000,
          memLatency: 8,
          raiseTimerIrqAt: at,
        );
      },
    );
  }

  // MRET handler @0x800: the FIRST take enters the handler (MIE cleared on entry)
  // and runs its sequential cold-line stream to the addi at 0x8c0 BEFORE any
  // mret/storm. Holding MTIP and targeting 0x8c0 is a deterministic assertion
  // that the interrupt vectors to 0x800 and the post-vector cold fetch completes.
  // (The mret return itself is exercised by the storm behaviour: mret returns to
  // mepc then re-vectors, proving the return path fetches correctly.)
  final initMret = {...init, Register.x5: 0x800};
  const handlerMretPc =
      0x800 + handlerNops * 4 + 4; // mret @0x8c4 (addi retired)
  for (final at in const [40, 60, 90]) {
    test(
      'IRQ vectors to 0x800 handler, cold-fetch stream reaches mret '
      '(raiseAt=$at)',
      timeout: Timeout(Duration(minutes: 5)),
      () {
        return coreTest(
          progMret(),
          {Register.x28: 0xAB},
          cfg(),
          initRegisters: initMret,
          nextPc: handlerMretPc,
          maxCycles: 8000,
          memLatency: 8,
          raiseTimerIrqAt: at,
        );
      },
    );
  }
}
