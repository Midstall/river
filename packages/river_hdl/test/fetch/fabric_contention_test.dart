import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// HW repro attempt #3 for the intermittent delta boot fetch-hang. Decode and
/// trap paths are clean (straddle_amo_test, misaligned_amo_trap_test). The
/// remaining suspect is fetch STARVATION on the single MMU Wishbone: the MMU
/// arbitrates dport (dcache) over ifetch (icache) with STRICT priority
/// (mmu.dart:916, `~dportEn` gates the ifetch launch). This harness creates
/// SUSTAINED contention: straight-line code far larger than the 64B I-cache (so
/// every line is an icache miss) where every instruction pair also does a load
/// from a fresh data line (so the dcache misses continuously). Under nonzero
/// miss latency the two streams overlap on the bus every cycle. If the arbiter
/// starves or deadlocks the ifetch, the core never reaches the final park.
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

  // ld  x7, 0(x10)     ; data load (dcache), fresh line each iter
  const ldX7 = (10 << 15) | (3 << 12) | (7 << 7) | 0x03;
  // sd  x7, 0(x11)     ; data store (dcache write / dirty), fresh line each iter
  const sdX7 = (7 << 20) | (11 << 15) | (3 << 12) | 0x23;
  // addi x10, x10, 8   ; advance load pointer to the next dcache line
  const addiX10 = (8 << 20) | (10 << 15) | (10 << 7) | 0x13;
  // addi x11, x11, 8   ; advance store pointer
  const addiX11 = (8 << 20) | (11 << 15) | (11 << 7) | 0x13;
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
    return sb.toString();
  }

  // [pairs] iterations of a load-only stream (2 words = 8 bytes = one icache
  // line per iter). Optionally interleave stores for dcache writeback pressure.
  String prog(int pairs, {required bool withStores}) {
    final w = <int, int>{};
    var pc = 0;
    for (var i = 0; i < pairs; i++) {
      w[pc] = ldX7;
      pc += 4;
      if (withStores) {
        w[pc] = sdX7;
        pc += 4;
      }
      w[pc] = addiX10;
      pc += 4;
      if (withStores) {
        w[pc] = addiX11;
        pc += 4;
      }
    }
    w[pc] = park;
    return memWords(w);
  }

  // Load pointer x10 -> data at 0x2000; store pointer x11 -> 0x4000. The data
  // region is far above the (small) code so their cache lines never alias.
  Map<Register, int> init() => {Register.x10: 0x2000, Register.x11: 0x4000};

  // 96 load lines = 768 bytes of code, 12x the 64B icache, so the fetch stream
  // misses every line for the whole run while the dcache misses every load.
  const pairs = 48;

  for (final lat in const [2, 4, 8, 12, 16, 24]) {
    final parkPc = pairs * 8;
    test(
      'load+fetch contention, memLatency=$lat, reaches park (no starvation)',
      timeout: Timeout(Duration(minutes: 4)),
      () {
        return coreTest(
          prog(pairs, withStores: false),
          {Register.x10: 0x2000 + pairs * 8},
          cfg(),
          initRegisters: init(),
          nextPc: parkPc,
          maxCycles: 15000,
          memLatency: lat,
        );
      },
    );
  }

  // With stores: load + store + two addis = 16 bytes/iter, so each iter spans
  // two icache lines and issues both a dcache read miss and a dirty write.
  for (final lat in const [2, 4, 8, 12, 16, 24]) {
    final parkPc = pairs * 16;
    test(
      'load+store+fetch contention, memLatency=$lat, reaches park',
      timeout: Timeout(Duration(minutes: 4)),
      () {
        return coreTest(
          prog(pairs, withStores: true),
          {Register.x10: 0x2000 + pairs * 8},
          cfg(),
          initRegisters: init(),
          nextPc: parkPc,
          maxCycles: 20000,
          memLatency: lat,
        );
      },
    );
  }
}
