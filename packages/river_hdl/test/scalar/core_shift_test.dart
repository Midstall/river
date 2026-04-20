import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// RV64 shift-immediates with shamt >= 32 (6-bit shamt). These previously hung
/// the in-order decoder because slli/srli/srai matched the full 7-bit funct7
/// (bit 25 = shamt[5]); the decoder now matches funct6 for OP-IMM shifts.
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

  // addi x2,x0,1 ; slli x1,x2,39 (->1<<39) ; srai x3,x1,33 (->(1<<39)>>33=0x40) ; nop
  test(
    'slli/srai with shamt>=32',
    timeout: Timeout(Duration(seconds: 120)),
    () {
      return coreTest(
        '@0\n13 01 10 00 93 10 71 02 93 d1 10 42 13 00 00 00\n',
        {Register.x1: 0x8000000000, Register.x3: 0x40},
        config,
        nextPc: 0x10,
      );
    },
  );
}
