import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Repro for #91: on HW the boot deadlocks in a ticket spinlock with a DUPLICATE
/// ticket (my ticket 0x4e8b behind owner 0x4e8c on a single hart) = a ticket-
/// dispensing amoadd.w LOST its increment. The lock is a 32-bit word
/// [next:16][owner:16]; acquire does `amoadd.w lock, 0x10000` (bump next, old =
/// my ticket), the spin reads the SAME word with `lw`, release bumps owner.
///
/// This hammers exactly that pattern through the REAL HarborL1DCache: a loop of
/// amoadd.w(0x10000) on one lock word, each followed by an `lw` of the same word
/// (like the spin) and an `sh` to the owner half (like a release), N times.
/// After N iterations the next field must be exactly N (no lost bump): the final
/// word high-half == N. A lost amoadd RMW leaves it < N.
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

  // amoadd.w x5, x13, (x12): funct7=0x00 (amoadd, aq=rl=0), rs2=x13(incr),
  // rs1=x12(lock), funct3=2(.w), rd=x5(old = my ticket). 0x00<<25|...|0x2F.
  const amoaddW =
      (0x00 << 25) | (13 << 20) | (12 << 15) | (2 << 12) | (5 << 7) | 0x2F;
  // lw x6, 0(x12): read the lock word (like the spin reading owner).
  const lwX6 = (12 << 15) | (2 << 12) | (6 << 7) | 0x03;
  // ld x7, 0(x12): final read of the whole 64-bit-aligned word for checking.
  const ldX7 = (12 << 15) | (3 << 12) | (7 << 7) | 0x03;
  // addi x28, x28, 1 (loop counter), and branch. Build the loop by hand.
  const park = 0x0000006F;

  String memWords(Map<int, int> words) {
    var maxAddr = 0;
    for (final a in words.keys) {
      if (a + 4 > maxAddr) maxAddr = a + 4;
    }
    final bytes = List<int>.filled(maxAddr, 0);
    words.forEach((a, w) {
      for (var i = 0; i < 4; i++) {
        bytes[a + i] = (w >> (i * 8)) & 0xFF;
      }
    });
    final sb = StringBuffer()..writeln('@0');
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    sb.writeln();
    // lock word at 0x2000, init 0.
    sb.writeln('@2000');
    sb.write('00 00 00 00 00 00 00 00');
    sb.writeln();
    return sb.toString();
  }

  // Unrolled: N times { amoadd.w x5,x13,(x12); lw x6,0(x12) }, then ld x7,0(x12),
  // then park. x13 = 1 (increment next by 1 in the low field for a simple, exact
  // check: final lock low-16 == N). x12 = 0x2000 (lock). Reaching park with
  // x7 == N proves every amoadd RMW landed; x7 < N means a lost increment.
  String prog(int n) {
    final w = <int, int>{};
    var pc = 0;
    for (var i = 0; i < n; i++) {
      w[pc] = amoaddW;
      pc += 4;
      w[pc] = lwX6;
      pc += 4;
    }
    w[pc] = ldX7;
    pc += 4;
    w[pc] = park;
    return memWords(w);
  }

  final init = {
    Register.x12: 0x2000, // lock address
    Register.x13: 0x1, // increment (each amoadd adds 1 to the word)
  };

  for (final n in const [8, 16, 32]) {
    for (final lat in const [0, 4, 8]) {
      test(
        'amoadd.w ticket dispense x$n through real dcache loses no increment '
        '(memLatency=$lat)',
        timeout: Timeout(Duration(minutes: 3)),
        () {
          final parkPc = n * 8 + 4;
          return coreTest(
            prog(n),
            {Register.x7: n},
            cfg(),
            initRegisters: init,
            nextPc: parkPc,
            maxCycles: 8000,
            memLatency: lat,
          );
        },
      );
    }
  }
}
