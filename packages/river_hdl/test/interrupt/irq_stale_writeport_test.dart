import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Repro for the delta intermittent wedge (unified root suspect): the async
/// interrupt-take path (exec.dart rawTrap) sets nextMode/trap/nextPc/epc but does
/// NOT clear rdWrite.en / memWrite.en. If those are still asserted from the
/// just-retired instruction while the datapath now computes the trap, a spurious
/// register (or memory) write with stale/garbage data fires on the take cycle,
/// corrupting the register the previous instruction wrote. That is exactly the
/// corrupted-pointer symptom on HW (misaligned amoor.d address, garbage lock
/// pointer), frequent but only fatal when it clobbers a live pointer.
///
/// This writes known values into several registers, fires a timer IRQ across a
/// fine cycle sweep so the take lands right after a reg-writing instruction, and
/// checks the values SURVIVE. A stale write-port clobbers one -> mismatch.
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

  const park = 0x0000006f;
  const mret = 0x30200073;

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

  // addi rd, x0, imm  (imm small). Encoding: (imm<<20)|(0<<15)|(0<<12)|(rd<<7)|0x13.
  int addi(int rd, int imm) => (imm << 20) | (rd << 7) | 0x13;

  // Setup: mtvec + mie + mstatus.MIE. Then a stream of reg-writes (addi) that
  // set x18..x25 to distinctive values, then a nop pad, then park. A timer IRQ
  // raised mid-stream should vector to the handler and mret back WITHOUT
  // clobbering any x18..x25. The handler preserves them (it only touches x28).
  const setup = [
    0x30529073, // csrw mtvec, x5   (=0x300)
    0x30431073, // csrw mie,   x6   (MTIE)
    0x3003a073, // csrs mstatus,x7  (MIE)
  ];
  // distinctive values (small imms so addi is single-instruction)
  final vals = {
    18: 0x111,
    19: 0x222,
    20: 0x333,
    21: 0x444,
    22: 0x555,
    23: 0x666,
    24: 0x777,
    25: 0x788,
  };
  final writes = <int>[for (final e in vals.entries) addi(e.key, e.value)];
  final mainBody = <int>[
    ...setup,
    ...writes,
    for (var i = 0; i < 20; i++) 0x00000013, // nop pad (IRQ can land here too)
    park,
  ];
  final parkPc = (mainBody.length - 1) * 4;

  // handler @0x300: set x28=0xAB (marker), then MRET. It must NOT disturb
  // x18..x25. Clear the timer first (lowerTimerIrqAt) so mret does not storm.
  final handlerBody = <int>[0x0ab00e13, mret]; // addi x28,x0,0xAB ; mret
  String prog() => mem({0x0: mainBody, 0x300: handlerBody});

  final init = {
    Register.x5: 0x300, // mtvec
    Register.x6: 1 << 7, // MTIE
    Register.x7: 1 << 3, // MIE
  };

  // Fine sweep of the IRQ raise cycle across the reg-write stream + pad, so the
  // take lands right after each reg-writing instruction. For EVERY cycle the
  // x18..x25 values must survive (the handler mrets back and the stream/pad runs
  // to park). A stale write-port on the take cycle corrupts one -> the reg check
  // fails. lowerTimerIrqAt clears the IRQ mid-handler so a single take occurs.
  for (var at = 10; at <= 40; at++) {
    test(
      'IRQ at cycle $at does not clobber a written register (stale write-port)',
      timeout: Timeout(Duration(minutes: 3)),
      () {
        return coreTest(
          prog(),
          {
            Register.x18: 0x111,
            Register.x19: 0x222,
            Register.x20: 0x333,
            Register.x21: 0x444,
            Register.x22: 0x555,
            Register.x23: 0x666,
            Register.x24: 0x777,
            Register.x25: 0x788,
          },
          cfg(),
          initRegisters: init,
          nextPc: parkPc,
          maxCycles: 4000,
          memLatency: 2,
          raiseTimerIrqAt: at,
          lowerTimerIrqAt: at + 3,
        );
      },
    );
  }
}
