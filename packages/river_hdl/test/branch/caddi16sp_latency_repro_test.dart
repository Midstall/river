import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Repro attempt 3 for the HW regression: rc1-f traps ILLEGAL (mcause 2) on
/// `c.addi16sp` (0x7179) at a NixOS EFI entry point, but ONLY at full speed on
/// real hardware (single-step, sim at zero fetch latency, and an SBA read all
/// show it decodes/executes fine). The decode-overrun fix (decoder end-of-ROM
/// mask==0 + the pipeline illegal-instruction trap) is the suspect: at full
/// speed a jump to a compressed instruction may momentarily present a decode
/// result that the new illegal path traps on. The zero-latency sim missed it.
/// This sweeps a multi-cycle fetch latency (DRAM/cache-like) while JUMPING to a
/// compressed instruction, to try to reproduce the spurious trap in sim.
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

  // Set sp, JUMP to a 4-aligned c.addi16sp, capture the result.
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
    emit16(0x7179); // 0x0c c.addi16sp sp, -48 (JUMP TARGET)
    emit32(iimm(0, 2, 0x0, 5)); // 0x0e addi x5, sp, 0
    emit32(0x0000006f); // 0x12 jal x0, 0 (park)

    final sb = StringBuffer('@0\n');
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return '$sb\n';
  }

  // Sweep realistic fetch latencies. The HW fetch (DRAM through the I-cache) is
  // multi-cycle; a spurious end-of-ROM/illegal fire would show up as x5 never
  // reaching 0x3D0 (the core traps and parks at the trap vector instead).
  for (final lat in [1, 2, 3, 4, 6]) {
    test(
      'c.addi16sp jump target decodes at fetch latency $lat (lanes=2)',
      timeout: Timeout(Duration(minutes: 6)),
      () => coreTest(
        prog(),
        {Register.x5: 0x3D0, Register.x2: 0x3D0},
        full(),
        nextPc: 0x12,
        memLatency: lat,
      ),
    );
  }
}
