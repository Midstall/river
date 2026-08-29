import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Repro attempt for the delta boot wedge (task #88 follow-up): on HW the core
/// bus-hangs at a function ENTRY - a control transfer lands on the entry (that
/// fetch, a cold L1I miss, refills fine), then the NEXT sequential fetch within
/// the just-filled line WEDGES the fetch handshake. It is intermittent, so it
/// looks like a latency-sensitive race between the refill response landing and
/// the following fetch request. DDR + SDIO are proven good, so this is purely
/// the FetchUnit <-> L1 I-cache handshake.
///
/// This drives that exact shape: jal to a COLD line far from the entry code, so
/// the target fetch misses and refills, then execute several sequential ops in
/// that line. Swept across refill latencies to hit the racing timing. A wedge =
/// the core never sets x6 / never reaches the park.
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

  int jal(int rd, int off) {
    final b20 = (off >> 20) & 1;
    final b10_1 = (off >> 1) & 0x3ff;
    final b11 = (off >> 11) & 1;
    final b19_12 = (off >> 12) & 0xff;
    return (b20 << 31) |
        (b10_1 << 21) |
        (b11 << 20) |
        (b19_12 << 12) |
        (rd << 7) |
        0x6f;
  }

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
  // addi x6, x0, 0x33
  const marker = 0x03300313;

  // Entry code at 0x0 hops through several COLD targets (each in a distinct,
  // far-apart line), landing on a function-entry-like NOP sled each time, then
  // running sequential ops in the just-filled line. Final target sets x6.
  String prog() => mem({
    0x0000: [jal(0, 0x4000)], //          -> cold line @0x4000
    0x4000: [nop, jal(0, 0x4000)], //  0x4000 entry(miss); 0x4004 -> @0x8000
    // wait: 0x4004 jal offset to 0x8000 = 0x8000-0x4004 = 0x3FFC
    0x8000: [nop, nop, jal(0, 0x4000)], // seq fetches then -> @0xC000
    0xC000: [nop, nop, marker, park], //  entry; seq; x6=0x33; park
  });

  for (final lat in const [0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32]) {
    test(
      'cold-line control-transfer + refill, sequential fetch (lat=$lat)',
      timeout: Timeout(Duration(minutes: 3)),
      () => coreTest(
        // fix the jal offsets: from 0x4004 to 0x8000 = 0x3FFC; 0x8008 to 0xC000
        mem({
          0x0000: [jal(0, 0x4000)],
          0x4000: [nop, jal(0, 0x3FFC)], // 0x4004 -> 0x8000
          0x8000: [nop, nop, jal(0, 0x3FF8)], // 0x8008 -> 0xC000
          0xC000: [nop, nop, marker, park], // 0xC008 x6=0x33 ; 0xC00C park
        }),
        {Register.x6: 0x33},
        cfg(),
        nextPc: 0xC00C,
        maxCycles: 1200,
        memLatency: lat,
      ),
    );
  }
}
