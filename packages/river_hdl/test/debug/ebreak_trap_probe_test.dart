import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

// Diagnostic: does the in-order core trap on ebreak (cause 3) like ecall?
// Mirrors core_trap_return_test's ecall case, swapping ecall (73 00 00 00)
// for ebreak (73 00 10 00). Same handler bumps mepc past it and mret resumes.
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

  test(
    'ebreak traps to mtvec, mret resumes after ebreak',
    timeout: Timeout(Duration(seconds: 200)),
    () {
      return coreTest(
        '@0\n'
        '73 10 55 30 73 00 10 00 93 05 50 05 13 00 00 00 '
        '13 00 00 00 13 00 00 00 13 00 00 00 73 26 10 34 '
        '13 06 46 00 73 10 16 34 73 00 20 30\n',
        {Register.x11: 0x55, Register.x12: 0x8},
        config,
        initRegisters: {Register.x10: 0x1c},
        nextPc: 0xc,
      );
    },
  );
}
