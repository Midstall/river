import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Repro attempt 2 for the HW trap: rc1-f traps ILLEGAL (mcause 2) on
/// `c.addi16sp` (0x7179) at a NixOS EFI entry point 0x8200744c. The earlier
/// caddi16sp_repro_test FELL THROUGH into the c.addi16sp and passed. On real
/// hardware Weir JUMPS to the entry, so the c.addi16sp is the FIRST fetch at a
/// 4-byte-aligned jump target (a fresh, cold instruction stream). This repro
/// jumps to the c.addi16sp instead of falling through, to see whether the
/// 2-lane decoder mis-selects the lane at a jump target.
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

  int iimm(int imm, int rs1, int f3, int rd) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;

  // Program: set sp, then JUMP forward to a 4-aligned c.addi16sp.
  //   @0x00 addi sp, x0, 0x400
  //   @0x04 jal  x0, +8          -> lands on 0x0c
  //   @0x08 addi x0, x0, 0       (unreached filler, keeps 0x0c 4-aligned)
  //   @0x0c c.addi16sp sp, -48   (0x7179, the JUMP TARGET, first fetch there)
  //   @0x0e addi x5, sp, 0       (capture the result)
  //   @0x12 jal  x0, 0           (park)
  // Expect sp = 0x400 - 48 = 0x3D0, x5 == 0x3D0.
  String prog() {
    final bytes = <int>[];
    void emit32(int w) {
      for (var i = 0; i < 4; i++) {
        bytes.add((w >> (i * 8)) & 0xFF);
      }
    }

    void emit16(int h) {
      bytes.add(h & 0xFF);
      bytes.add((h >> 8) & 0xFF);
    }

    emit32(iimm(0x400, 0, 0x0, 2)); // 0x00 addi sp, x0, 0x400
    emit32(0x0080006f); // 0x04 jal x0, +8 -> 0x0c
    emit32(iimm(0, 0, 0x0, 0)); // 0x08 nop filler
    emit16(0x7179); // 0x0c c.addi16sp sp, -48 (jump target)
    emit32(iimm(0, 2, 0x0, 5)); // 0x0e addi x5, sp, 0
    emit32(0x0000006f); // 0x12 jal x0, 0 (park)

    final sb = StringBuffer('@0\n');
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return '$sb\n';
  }

  test(
    'c.addi16sp as a JUMP TARGET decodes on rc1-f (lanes=2) - x5 == sp-48',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x5: 0x3D0, Register.x2: 0x3D0},
      full(),
      nextPc: 0x12,
    ),
  );
}
