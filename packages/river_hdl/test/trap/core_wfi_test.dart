import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// wfi must retire as a NOP-hint and advance past itself so the core does not
/// wedge (Linux idles with wfi). The dynamic microcode interpreter (creek path)
/// had no handler for the WaitForInterrupt micro-op, so wfi stalled forever.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final config = RiverCoreConfigV1.small(
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  );

  //   0x00 wfi               ; 73 00 50 10   (0x10500073)
  //   0x04 addi x1,x0,0x42   ; 93 00 20 04   (0x04200093)  <- must run
  test(
    'wfi retires and the core continues to the next instruction',
    timeout: Timeout(Duration(seconds: 120)),
    () {
      return coreTest(
        '@0\n'
        '73 00 50 10 93 00 20 04\n',
        {Register.x1: 0x42},
        config,
        nextPc: 0x08,
      );
    },
  );
}
