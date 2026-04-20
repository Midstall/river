import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/icache.dart';
import 'package:test/test.dart';

/// Eviction / aliasing / thrash stress for RiverICache in the CREEK geometry
/// (direct-mapped, numLines: 8, lineWords: 1, xlen: 64) with a MULTI-CYCLE
/// backing that models the slow DDR fill latency.
///
/// The conduit-walk boot failure only appears once main runs a code footprint
/// far larger than the 8-word icache, so the icache constantly misses, evicts,
/// and re-fills lines while executing from DRAM. The existing icache_test only
/// touches a few addresses and never forces an eviction, nor a re-access of an
/// evicted line, nor a back-to-back miss under realistic fill latency. This test
/// exercises exactly that: every fetch must return its own address (the backing
/// returns addr), so any stale-hit, tag-aliasing, or fill/settle-timing bug
/// surfaces as a wrong word.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> runEvict({required int latency}) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic();
    final req0En = Logic();
    final req0Addr = Logic(width: 64);
    final memDone = Logic();
    final memValid = Logic();
    final memRdata = Logic(width: 64);
    final flush = Logic();

    final ic = RiverICache(
      clk,
      reset,
      req0En: req0En,
      req0Addr: req0Addr,
      req1En: null,
      req1Addr: null,
      memDone: memDone,
      memValid: memValid,
      memRdata: memRdata,
      flush: flush,
      xlen: 64,
      lineWords: 1,
      numLines: 8,
      dualPort: false,
    );
    await ic.build();

    // Multi-cycle backing: when memEn asserts, count `latency` cycles, then
    // pulse memDone/memValid with memRdata = the (latched) fill address. This is
    // the DDR fill latency the combinational test-backing never modeled.
    final busy = Logic(name: 'bk_busy');
    final cnt = Logic(name: 'bk_cnt', width: 8);
    final addrLatched = Logic(name: 'bk_addr', width: 64);
    final doneR = Logic(name: 'bk_done');
    final validR = Logic(name: 'bk_valid');
    final rdataR = Logic(name: 'bk_rdata', width: 64);
    memDone <= doneR;
    memValid <= validR;
    memRdata <= rdataR;
    Sequential(clk, reset: reset, [
      doneR < 0,
      validR < 0,
      If(
        ~busy & ic.memEn & ~doneR,
        then: [busy < 1, cnt < 0, addrLatched < ic.memAddr],
        orElse: [
          If(
            busy,
            then: [
              cnt < cnt + 1,
              If(
                cnt.eq(Const(latency, width: 8)),
                then: [busy < 0, doneR < 1, validR < 1, rdataR < addrLatched],
              ),
            ],
          ),
        ],
      ),
    ]);

    reset.inject(1);
    req0En.inject(0);
    req0Addr.inject(0);
    flush.inject(0);
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    Future<int> fetch(int addr) async {
      req0En.inject(1);
      req0Addr.inject(addr);
      for (var i = 0; i < 200; i++) {
        await clk.nextNegedge;
        if (ic.done0.value.toBool()) {
          final d = ic.rdata0.value.toInt();
          req0En.inject(0);
          await clk.nextPosedge; // let the fetcher advance one cycle
          return d;
        }
      }
      req0En.inject(0);
      throw StateError('fetch of 0x${addr.toRadixString(16)} timed out');
    }

    // Line index = addr[5:3] (8-byte words, 8 lines). base+0x00..0x38 fill lines
    // 0..7; base+0x40 aliases line 0 with a new tag (evicts it).
    const base = 0x80000000;
    Future<void> check(int addr) async {
      final d = await fetch(addr);
      expect(
        d,
        addr,
        reason:
            'fetch 0x${addr.toRadixString(16)} returned '
            '0x${d.toRadixString(16)} (stale/aliased line)',
      );
    }

    // 1) Fill all 8 lines.
    for (var i = 0; i < 8; i++) {
      await check(base + i * 8);
    }
    // 2) Re-fetch all 8 (should all hit, still correct).
    for (var i = 0; i < 8; i++) {
      await check(base + i * 8);
    }
    // 3) Evict line 0 with an aliasing tag, then re-fetch the original: must MISS
    //    and re-fill, not serve the evictor's or the stale word.
    await check(base + 0x40); // idx 0, new tag -> evicts line 0
    await check(base + 0x00); // idx 0, original tag -> must re-miss + refill
    await check(base + 0x40); // idx 0 again
    await check(base + 0x00);

    // 4) Thrash a single line back-to-back (alternating tags at the same index).
    for (var i = 0; i < 16; i++) {
      await check(base + (i.isEven ? 0x00 : 0x40));
    }

    // 5) Streaming walk over 64 consecutive words (8x the cache), twice, the
    //    real conduit-walk shape: constant miss/evict/refill.
    for (var pass = 0; pass < 2; pass++) {
      for (var w = 0; w < 64; w++) {
        await check(base + w * 8);
      }
    }

    // 6) Back-to-back distinct-line misses with no idle gap between them.
    for (var i = 0; i < 8; i++) {
      req0En.inject(1);
      req0Addr.inject(base + 0x1000 + i * 8); // fresh tags, each a miss
      var got = -1;
      for (var k = 0; k < 200; k++) {
        await clk.nextNegedge;
        if (ic.done0.value.toBool()) {
          got = ic.rdata0.value.toInt();
          break;
        }
      }
      expect(
        got,
        base + 0x1000 + i * 8,
        reason: 'back-to-back miss $i returned 0x${got.toRadixString(16)}',
      );
      // do NOT drop req0En between: keep the stream flowing, just change addr
    }
    req0En.inject(0);

    await Simulator.endSimulation();
  }

  test(
    'icache eviction/thrash, fast fill (latency 2)',
    () => runEvict(latency: 2),
  );
  test(
    'icache eviction/thrash, slow DDR-like fill (latency 12)',
    () => runEvict(latency: 12),
  );
}
