import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// MRET / trap-return support in the in-order HDL core.
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

  // Isolated MRET return: preload mepc=0x10 (computed) and mstatus.MPP=M
  // (0x1800, from x11), then mret. PC must jump to 0x10 and execute addi.
  //   0x00 addi x10,x0,0x10   ; 13 05 00 01
  //   0x04 csrw mepc,x10      ; 73 10 15 34
  //   0x08 csrw mstatus,x11   ; 73 90 05 30
  //   0x0c mret               ; 73 00 20 30
  //   0x10 addi x12,x0,0x55   ; 13 06 50 05   <- return target
  test(
    'mret returns to mepc and restores mode',
    timeout: Timeout(Duration(seconds: 200)),
    () {
      return coreTest(
        '@0\n'
        '13 05 00 01 73 10 15 34 73 90 05 30 73 00 20 30 13 06 50 05\n',
        {Register.x12: 0x55},
        config,
        initRegisters: {Register.x11: 0x1800},
        nextPc: 0x14,
      );
    },
  );

  // Full trap round-trip: ecall (M) saves mepc, jumps to mtvec handler; handler
  // reads mepc, bumps it past the ecall, mret returns to the next instruction.
  //   0x00 csrw mtvec,x10     ; 73 10 55 30   (x10=0x1c)
  //   0x04 ecall              ; 73 00 00 00
  //   0x08 addi x11,x0,0x55   ; 93 05 50 05   <- resumes here
  //   0x0c (nextPc target)    ; 13 00 00 00
  //   0x10..0x18 nops
  //   0x1c csrr x12,mepc      ; 73 26 10 34
  //   0x20 addi x12,x12,4     ; 13 06 46 00
  //   0x24 csrw mepc,x12      ; 73 10 16 34
  //   0x28 mret               ; 73 00 20 30
  test(
    'ecall traps to mtvec, mret resumes after ecall',
    timeout: Timeout(Duration(seconds: 200)),
    () {
      return coreTest(
        '@0\n'
        '73 10 55 30 73 00 00 00 93 05 50 05 13 00 00 00 '
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
