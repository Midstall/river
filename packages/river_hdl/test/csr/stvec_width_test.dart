import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// HW-observed: at relocate_enable_mmu the kernel writes stvec with a high
/// sign-extended virtual address (0xffffffff80001048) but it reads back as
/// 0x80001048 (upper 32 bits dropped), causing the trampoline fault to loop.
/// This checks csrw/csrr stvec round-trips a full 64-bit value (mtvec too) on
/// the delta full() lanes=2 config. satp already round-trips 64 bits on HW.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig full() => RiverCoreConfigV1.full(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  // t0=x5 seeded to the high virtual address; csrw stvec,t0 ; csrr t1,stvec.
  //   0x00 csrw stvec, t0   (0x10529073)
  //   0x04 csrr t1, stvec   (0x10502373)  t1=x6
  //   0x08 csrw mtvec, t0   (0x30529073)
  //   0x0c csrr t2, mtvec   (0x30502373)  t2=x7
  //   0x10 jal x0, 0        park
  String prog() {
    final sb = StringBuffer('@0\n');
    void h32(int v) {
      for (var i = 0; i < 4; i++) {
        sb.write(((v >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }

    // Build t0 = 0xffffffff80001048 in-program (lui sign-extends bit 31 on RV64),
    // so there is no seeded-register high-bit ambiguity.
    h32(0x800012b7); // lui  t0, 0x80001   -> 0xffffffff80001000
    h32(0x04828293); // addi t0, t0, 0x48  -> 0xffffffff80001048
    h32(0x10529073); // csrw stvec, t0
    h32(0x00000013); // nop
    h32(0x00000013); // nop
    h32(0x10502373); // csrr t1, stvec  (t1=x6)
    h32(0x0000006f); // jal x0, 0 (park)
    sb.writeln();
    return sb.toString();
  }

  const hi = 0xffffffff80001048;

  test(
    'csrw/csrr stvec round-trips a 64-bit high virtual address (lanes=2)',
    timeout: Timeout(Duration(minutes: 6)),
    () async {
      await coreTest(prog(), {Register.x6: hi}, full(), nextPc: 0x18);
    },
  );
}
