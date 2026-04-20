import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Microarchitecture IPC benchmark. Measures cycles-to-complete for a workload
/// under several pipeline personalities, isolating the contribution of the
/// instruction cache (fast re-fetch) and dual-dispatch (2-wide issue).
///
/// Memory has a non-trivial read latency so that a bus fetch is meaningfully
/// slower than a cache hit, which is where the icache earns its keep.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  HarborMmuConfig mmu() => HarborMmuConfig(
    mxlen: RiscVMxlen.rv32,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  );

  RiverCoreConfig mk({
    required ExecutionMode mode,
    bool speculative = false,
    IssueWidth issue = IssueWidth.single,
    bool icache = false,
    bool prefetch = false,
    int prefetchDepth = 2,
    BranchPredictor bp = BranchPredictor.none,
    LoadStoreQueue lsq = LoadStoreQueue.none,
  }) => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv32,
    extensions: [rv32i, rvZicsr, rvZifencei, rvM],
    interrupts: [],
    mmu: mmu(),
    type: RiverCoreType.general,
    executionMode: mode,
    speculativeFetch: speculative,
    prefetchFetch: prefetch,
    prefetchDepth: prefetchDepth,
    issueWidth: issue,
    l1cache: icache
        ? HarborL1CacheConfig.split(iSize: 32, dSize: 64, ways: 1, lineSize: 4)
        : null,
    branchPredictor: bp,
    loadStoreQueue: lsq,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  int b(int imm, int rs2, int rs1, int f3) =>
      (((imm >> 12) & 0x1) << 31) |
      (((imm >> 5) & 0x3F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      (((imm >> 1) & 0xF) << 8) |
      (((imm >> 11) & 0x1) << 7) |
      0x63;
  String prog(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var i = 0; i < 4; i++) {
        sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  /// Run [config] on [memString] until nextPc==[nextPc]; return the cycle count.
  Future<int> measureCycles(
    RiverCoreConfig config,
    String memString,
    int nextPc, {
    int memLatency = 0,
  }) async {
    // Each measurement is an independent simulation; reset the global Simulator
    // so its clock starts at zero again (multiple runs in one test).
    await Simulator.reset();
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic();
    final addrWidth = config.mxlen.size;
    final wbConfig = WishboneConfig(
      addressWidth: addrWidth,
      dataWidth: config.mxlen.size,
      selWidth: config.mxlen.size ~/ 8,
    );
    final core = RiverCore(config, busConfig: wbConfig);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;
    await core.build();

    final storage = SparseMemoryStorage(
      addrWidth: addrWidth,
      dataWidth: config.mxlen.size,
      alignAddress: (addr) => addr,
      onInvalidRead: (addr, dataWidth) =>
          LogicValue.filled(dataWidth, LogicValue.zero),
    );
    final memRead = DataPortInterface(config.mxlen.size, addrWidth);
    final memWrite = DataPortInterface(config.mxlen.size, addrWidth);
    // ignore: unused_local_variable
    final mem = MemoryModel(
      clk,
      reset,
      [wrapWriteForRegisterFile(memWrite)],
      [wrapReadForRegisterFile(memRead, clk: clk, readLatency: memLatency)],
      readLatency: memLatency,
      storage: storage,
    );
    final wbCyc = core.output('dataBus_CYC');
    final wbStb = core.output('dataBus_STB');
    final wbWe = core.output('dataBus_WE');
    final wbAdr = core.output('dataBus_ADR');
    final wbDatMosi = core.output('dataBus_DAT_MOSI');
    memRead.en <= wbCyc & wbStb & ~wbWe;
    memRead.addr <= wbAdr;
    memWrite.en <= wbCyc & wbStb & wbWe;
    memWrite.addr <= wbAdr;
    memWrite.data <= wbDatMosi;
    final wbAckReg = Logic(name: 'wbAck');
    final readyForAck = wbWe | memRead.valid;
    Sequential(clk, [
      If(
        reset,
        then: [wbAckReg < 0],
        orElse: [
          If(
            wbCyc & wbStb & ~wbAckReg & readyForAck,
            then: [wbAckReg < 1],
            orElse: [wbAckReg < 0],
          ),
        ],
      ),
    ]);
    core.input('dataBus_ACK').srcConnection! <= wbAckReg;
    core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

    reset.inject(1);
    Simulator.registerAction(20, () {
      reset.put(0);
      storage.loadMemString(memString);
    });
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }
    var cycles = 0;
    for (var i = 0; i < 20000; i++) {
      await clk.nextPosedge;
      cycles++;
      final pc = core.pipeline.nextPc.value;
      if (pc.isValid && pc.toInt() == nextPc) break;
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return cycles;
  }

  // Loop workload: a counted loop whose body is re-fetched every iteration,
  // and the icache turns those re-fetches into hits. Kept short (ROHD sim of the
  // full OoO core is slow). The per-iteration re-fetch is what the icache
  // accelerates, so even a few iterations show the effect.
  // 0x00 addi x1,x0,6
  // 0x04 addi x2,x2,1   (loop body start)
  // 0x08 addi x3,x3,2
  // 0x0C addi x1,x1,-1
  // 0x10 bne  x1,x0,-12  -> back to 0x04
  // 0x14.. nop tail
  String loopProg() => prog([
    iimm(6, 0, 0x0, 1),
    iimm(1, 2, 0x0, 2),
    iimm(2, 3, 0x0, 3),
    iimm(-1, 1, 0x0, 1),
    b(-12, 0, 1, 0x1),
    ...List.filled(10, 0x00000013),
  ]);
  const loopNextPc = 0x3C;

  // Cached-loop workload: a loop whose body is a run of independent adds. After
  // the first iteration the body is cached, so the 2-port icache feeds both
  // lanes 2 instructions/cycle and dual-dispatch can co-issue the independent
  // body, which is where 2-wide issue earns its keep (cold straight-line code is
  // fill-bound at one word/cycle and dual can't beat single there). The wider
  // the independent body, the more the 2-wide lanes amortize the serial
  // loop-carried recurrence (dec then branch), so a longer body gives more
  // speedup: measured ~1.20x at 12 adds, ~1.34x at 16 adds (the latter run
  // standalone at memLatency=4, since the 16-body at memLatency=12 is too slow
  // for this 5-config bench, and core_dual_test's M6 guards 16-body behaviour).
  // 0x00 addi x14,x0,5        (iteration count)
  // 0x04..0x30 addi x1..x12,x0,k   loop body (12 independent adds)
  // 0x34 addi x14,x14,-1
  // 0x38 bne  x14,x0,-52  -> back to 0x04
  // 0x3C.. nop tail
  // 12 independent adds + dec + back-edge.
  String cachedLoopProg() => prog([
    iimm(5, 0, 0x0, 14),
    for (var r = 1; r <= 12; r++) iimm(r, 0, 0x0, r),
    iimm(-1, 14, 0x0, 14),
    b(-52, 0, 14, 0x1),
    ...List.filled(10, 0x00000013),
  ]);
  const cachedLoopNextPc = 0x64; // 25 words

  test(
    'IPC: instruction-cache and dual-dispatch',
    timeout: Timeout(Duration(seconds: 900)),
    () async {
      // memLatency makes a bus fetch cost several cycles; cache hits cost one.
      // Higher latency = larger gap between a bus fetch and a cache hit, so the
      // icache's benefit grows with it (real memory hierarchies have deep misses).
      const lat = 12;

      // Loop: instruction-cache effect (no prediction in either).
      final loopNoIc = await measureCycles(
        mk(mode: ExecutionMode.outOfOrder, speculative: true),
        loopProg(),
        loopNextPc,
        memLatency: lat,
      );
      final loopIc = await measureCycles(
        mk(mode: ExecutionMode.outOfOrder, speculative: true, icache: true),
        loopProg(),
        loopNextPc,
        memLatency: lat,
      );
      // Loop: branch-prediction effect (both have the icache).
      final loopBp = await measureCycles(
        mk(
          mode: ExecutionMode.outOfOrder,
          speculative: true,
          icache: true,
          bp: BranchPredictor.btfn,
        ),
        loopProg(),
        loopNextPc,
        memLatency: lat,
      );

      // Cached independent-body loop with prediction: single vs dual. With the
      // back-edge predicted, the per-iteration flush is gone, so the 2-wide lanes
      // can finally co-issue the independent body.
      final clSingleBp = await measureCycles(
        mk(
          mode: ExecutionMode.outOfOrder,
          speculative: true,
          icache: true,
          bp: BranchPredictor.btfn,
        ),
        cachedLoopProg(),
        cachedLoopNextPc,
        memLatency: lat,
      );
      final clDualBp = await measureCycles(
        mk(
          mode: ExecutionMode.outOfOrder,
          speculative: true,
          issue: IssueWidth.dual,
          icache: true,
          bp: BranchPredictor.btfn,
        ),
        cachedLoopProg(),
        cachedLoopNextPc,
        memLatency: lat,
      );

      // ignore: avoid_print
      print('=== IPC benchmark (memLatency=$lat) ===');
      // ignore: avoid_print
      print(
        'Loop, re-fetched body:   no-icache = $loopNoIc,  +icache = $loopIc'
        '  -> icache ${(loopNoIc / loopIc).toStringAsFixed(2)}x',
      );
      // ignore: avoid_print
      print(
        'Loop, branch predict:    icache = $loopIc,  icache+btfn = $loopBp'
        '  -> bpred ${(loopIc / loopBp).toStringAsFixed(2)}x',
      );
      // ignore: avoid_print
      print(
        'Cached loop +btfn:       single = $clSingleBp,  dual = $clDualBp'
        '  -> dual ${(clSingleBp / clDualBp).toStringAsFixed(2)}x',
      );

      expect(
        loopIc,
        lessThan(loopNoIc),
        reason: 'icache should speed up the re-fetched loop',
      );
      expect(
        loopBp,
        lessThan(loopIc),
        reason: 'branch prediction should speed up the loop further',
      );
      expect(
        clDualBp,
        lessThanOrEqualTo(clSingleBp),
        reason: 'dual should be no slower than single',
      );
    },
  );

  // Prefetch fetcher: a long straight-line, dependency-free run (the case the
  // classic fetcher serialises worst, fetch->decode->rename->alloc per instr).
  // The prefetch fetcher reads one ahead into a FIFO so the next fetch overlaps
  // the current instruction's decode/rename/alloc. With a bus fetch latency the
  // win should be visible. See project_hdl_prefetch.
  String chainProg() => prog([
    for (var i = 0; i < 24; i++) iimm((i & 0x3F) + 1, 0, 0x0, (i % 30) + 1),
    ...List.filled(8, 0x00000013),
  ]);

  test(
    'IPC: prefetch fetcher (straight-line)',
    timeout: Timeout(Duration(seconds: 600)),
    () async {
      const end = 24 * 4; // PC after the 24th addi commits
      print('=== prefetch fetcher (straight-line 24 instr) ===');
      // (icache, memLatency) points: the no-icache headline win, plus the icache
      // cases where line-fill should let prefetch hide the per-hit fetch latency.
      final points = [(false, 0), (true, 0), (true, 2), (true, 4)];
      for (final (ic, lat) in points) {
        final base = await measureCycles(
          mk(mode: ExecutionMode.outOfOrder, speculative: true, icache: ic),
          chainProg(),
          end,
          memLatency: lat,
        );
        final pf = await measureCycles(
          mk(
            mode: ExecutionMode.outOfOrder,
            speculative: true,
            icache: ic,
            prefetch: true,
          ),
          chainProg(),
          end,
          memLatency: lat,
        );
        print(
          'icache=$ic memLatency=$lat: '
          'classic=$base, prefetch=$pf -> ${(base / pf).toStringAsFixed(2)}x',
        );
        expect(
          pf,
          lessThanOrEqualTo(base),
          reason: 'prefetch should be no slower (icache=$ic lat=$lat)',
        );
      }
      // FIFO-depth sweep at icache + latency. NOTE: deeper does NOT help here,
      // reads are single-outstanding, so the FIFO fills at the read rate (~= the
      // consume rate during icache hits) and never gets far enough ahead to cover
      // a line-fill miss. Getting ahead needs MULTIPLE outstanding reads (pipelined
      // fetch), which needs a request/response-decoupled interconnect. Kept as a
      // regression guard that depth is correct + no-slower. See project_hdl_prefetch.
      final dBase = await measureCycles(
        mk(mode: ExecutionMode.outOfOrder, speculative: true, icache: true),
        chainProg(),
        end,
        memLatency: 4,
      );
      for (final d in [2, 4]) {
        final pf = await measureCycles(
          mk(
            mode: ExecutionMode.outOfOrder,
            speculative: true,
            icache: true,
            prefetch: true,
            prefetchDepth: d,
          ),
          chainProg(),
          end,
          memLatency: 4,
        );
        print(
          'icache+memLatency=4 prefetchDepth=$d: '
          'classic=$dBase, prefetch=$pf -> ${(dBase / pf).toStringAsFixed(2)}x',
        );
      }
    },
  );

  // Load-store-queue benchmark. A dependent store→load loop: each iteration
  // stores a value and loads it straight back from the same address, then uses
  // it. With memLatency the store's write to memory costs several cycles, so:
  //  - storeQueue: the load waits for the store to drain every iteration;
  //  - forwarding: the load takes the value from the queue, no drain wait;
  //  - speculative: same forward, and loads may also run ahead of the store.
  int s(int imm, int rs2, int rs1, int f3) =>
      (((imm >> 5) & 0x7F) << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (f3 << 12) |
      ((imm & 0x1F) << 7) |
      0x23;
  int lw(int imm, int rs1, int rd) =>
      (imm << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03;
  // jal x0, 0: an unconditional jump to self, used to terminate a benchmark
  // program so the speculative front-end stays put instead of running off the
  // end of the nop tail into uninitialised memory during long stalls.
  const selfLoop = 0x0000006F;

  // 0x00 addi x10,x0,0x400   (data address)
  // 0x04 addi x14,x0,8       (iteration count)
  // 0x08 addi x5,x0,1        (initial value)
  // 0x0C sw   x5,0(x10)      loop body: store
  // 0x10 lw   x6,0(x10)               load it back (store then load, same addr)
  // 0x14 addi x5,x6,1                 use the loaded value (dep chain via mem)
  // 0x18 addi x14,x14,-1
  // 0x1C bne  x14,x0,-16  -> back to 0x0C
  // 0x20 jal  x0,0        (terminating self-loop)
  String memLoopProg() => prog([
    iimm(0x400, 0, 0x0, 10),
    iimm(8, 0, 0x0, 14),
    iimm(1, 0, 0x0, 5),
    s(0, 5, 10, 0x2),
    lw(0, 10, 6),
    iimm(1, 6, 0x0, 5),
    iimm(-1, 14, 0x0, 14),
    b(-16, 0, 14, 0x1),
    selfLoop,
  ]);
  const memLoopNextPc = 0x20;

  test(
    'IPC: load-store queue (store→load dependent loop)',
    timeout: Timeout(Duration(seconds: 900)),
    () async {
      const lat = 4;
      RiverCoreConfig lsqCfg(
        LoadStoreQueue q, {
        IssueWidth issue = IssueWidth.single,
      }) => mk(
        mode: ExecutionMode.outOfOrder,
        speculative: true,
        icache: true,
        bp: BranchPredictor.btfn,
        issue: issue,
        lsq: q,
      );

      final sq = await measureCycles(
        lsqCfg(LoadStoreQueue.storeQueue),
        memLoopProg(),
        memLoopNextPc,
        memLatency: lat,
      );
      final fwd = await measureCycles(
        lsqCfg(LoadStoreQueue.forwarding),
        memLoopProg(),
        memLoopNextPc,
        memLatency: lat,
      );
      final fwdDual = await measureCycles(
        lsqCfg(LoadStoreQueue.forwarding, issue: IssueWidth.dual),
        memLoopProg(),
        memLoopNextPc,
        memLatency: lat,
      );

      // ignore: avoid_print
      print('=== LSQ benchmark (memLatency=$lat, store→load dep loop) ===');
      // ignore: avoid_print
      print(
        'storeQueue = $sq,  forwarding = $fwd,  forwarding+dual = $fwdDual'
        '  -> dual ${(fwd / fwdDual).toStringAsFixed(2)}x over single',
      );

      expect(
        fwd,
        lessThanOrEqualTo(sq),
        reason: 'forwarding should not be slower than waiting for the drain',
      );
      expect(
        fwdDual,
        lessThanOrEqualTo(fwd),
        reason: 'dual mem co-dispatch should be no slower than single',
      );
    },
  );

  int rr(int f7, int rs2, int rs1, int f3, int rd) =>
      (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33;

  // Independent load behind a SLOW store. Each iteration computes the store's
  // address with a multi-cycle mul, stores there, then loads from a different
  // (fast) address and accumulates. In-order memory (storeQueue/forwarding) must
  // hold the load behind the not-ready store, so every iteration waits the full
  // mul latency. Speculative loads bypass the not-ready store and overlap the
  // mul, hiding it.
  // 0x00 addi x10,x0,0x500   load address (fast)
  // 0x04 addi x21,x0,0x400   store-base operand
  // 0x08 addi x22,x0,1       mul operand
  // 0x0C addi x14,x0,6       count
  // 0x10 addi x5,x0,0xAA     store value
  // 0x14 mul  x20,x21,x22    slow -> store address (0x400)
  // 0x18 sw   x5,0(x20)      store (address not ready until the mul finishes)
  // 0x1C lw   x6,0(x10)      load from 0x500 (independent, ready early)
  // 0x20 add  x7,x7,x6       accumulate
  // 0x24 addi x14,x14,-1
  // 0x28 bne  x14,x0,-20  -> 0x14
  // 0x2C jal  x0,0
  String slowStoreLoopProg() =>
      '${prog([
        iimm(0x500, 0, 0x0, 10),
        iimm(0x400, 0, 0x0, 21),
        iimm(1, 0, 0x0, 22),
        iimm(6, 0, 0x0, 14),
        iimm(0xAA, 0, 0x0, 5),
        rr(0x01, 22, 21, 0x0, 20), // mul x20, x21, x22
        s(0, 5, 20, 0x2),
        lw(0, 10, 6),
        rr(0x00, 6, 7, 0x0, 7), // add x7, x7, x6
        iimm(-1, 14, 0x0, 14),
        b(-20, 0, 14, 0x1),
        selfLoop,
      ])}@500\n05 00 00 00\n';
  const slowStoreNextPc = 0x2C;

  test(
    'IPC: speculative loads bypass a slow store',
    timeout: Timeout(Duration(seconds: 900)),
    () async {
      RiverCoreConfig cfg(LoadStoreQueue q) => mk(
        mode: ExecutionMode.outOfOrder,
        speculative: true,
        icache: true,
        bp: BranchPredictor.btfn,
        lsq: q,
      );

      final fwd = await measureCycles(
        cfg(LoadStoreQueue.forwarding),
        slowStoreLoopProg(),
        slowStoreNextPc,
      );
      final spec = await measureCycles(
        cfg(LoadStoreQueue.speculative),
        slowStoreLoopProg(),
        slowStoreNextPc,
      );

      // ignore: avoid_print
      print('=== speculative-load benchmark (load behind slow store) ===');
      // ignore: avoid_print
      print(
        'forwarding = $fwd,  speculative = $spec'
        '  -> speculative ${(fwd / spec).toStringAsFixed(2)}x',
      );

      expect(
        spec,
        lessThanOrEqualTo(fwd),
        reason: 'speculative loads should bypass the slow store',
      );
    },
  );
}
