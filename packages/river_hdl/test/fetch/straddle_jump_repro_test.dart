import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// Repro attempt for the surviving delta boot hypothesis: a control transfer
/// (jal, and by extension an mret, since the in-order core steers the fetcher
/// purely by currentPc) that lands on a 32-bit instruction whose address is
/// congruent to 6 mod 8 -> the instruction straddles the 8-byte fetch word
/// (low half in the top halfword of word N, high half in word N+1). The claim
/// from HW debugging: falling THROUGH into such a straddle works, but JUMPING
/// to it mis-assembles the instruction.
///
/// Both programs put `addi x5, x0, 10` (0x00a00293, x5<-0xA) at byte 0x0E and
/// expect x5=0xA. Program A reaches it by fall-through, program B by a jal.
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

  // Turn a byte list (index 0 = addr 0x00) into a loadMemString payload.
  String mem(List<int> bytes) {
    final sb = StringBuffer('@0\n');
    for (final b in bytes) {
      sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return '${sb.toString().trimRight()}\n';
  }

  // Little-endian byte expansions of the fixed opcodes we place.
  const straddleInstr = [0x93, 0x02, 0xA0, 0x00]; // addi x5,x0,10 @ 0x0E
  const jalLoop = [0x6F, 0x00, 0x00, 0x00]; //         jal x0,0 (self loop)
  const nop32 = [0x13, 0x00, 0x00, 0x00]; //           addi x0,x0,0
  const cnop = [0x01, 0x00]; //                        c.nop

  final fallThrough = <int>[
    ...nop32, //  0x00 fall through
    ...cnop, //   0x04
    ...cnop, //   0x06
    ...nop32, //  0x08
    ...cnop, //   0x0C
    ...straddleInstr, // 0x0E straddle -> x5=0xA
    ...jalLoop, // 0x12 park
  ];

  // jal x0, +0x0E from 0x00 = 0x00E0006F -> LE 6F 00 E0 00.
  final jalToStraddle = <int>[
    0x6F, 0x00, 0xE0, 0x00, // 0x00 jal x0,0x0E
    ...cnop, //                0x04 (skipped)
    ...cnop, //                0x06
    ...cnop, //                0x08
    ...cnop, //                0x0A
    ...cnop, //                0x0C
    ...straddleInstr, //       0x0E straddle -> x5=0xA
    ...jalLoop, //             0x12 park
  ];

  // Real DDR-through-cache latency is what the zero-latency sim never exercises;
  // the straddle path issues two sequential reads whose handshake can only race
  // when responses are delayed. Sweep a spread of memory read latencies.
  const latencies = <int>[0, 2, 4, 8, 12, 24];

  for (final lat in latencies) {
    test(
      'A(lat=$lat): fall-through into byte-offset-6 straddle (baseline)',
      timeout: Timeout(Duration(minutes: 6)),
      () => coreTest(
        mem(fallThrough),
        {Register.x5: 0xA},
        full(),
        nextPc: 0x12,
        memLatency: lat,
      ),
    );

    test(
      'B(lat=$lat): jal to byte-offset-6 straddle (suspect path)',
      timeout: Timeout(Duration(minutes: 6)),
      () => coreTest(
        mem(jalToStraddle),
        {Register.x5: 0xA},
        full(),
        nextPc: 0x12,
        memLatency: lat,
      ),
    );
  }
}
