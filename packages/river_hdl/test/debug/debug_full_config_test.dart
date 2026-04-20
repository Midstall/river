import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Reproduces river_sim's remote_bitbang setup IN-PROCESS (no socket): the full
/// `rc1-s` core config (small + Sv39 paging) with `withDebug`, the debug module
/// wired both ways, and a free-running simulator. If the bidirectional debug
/// feedback plus this config makes the simulator hang, this test times out and
/// pins the bug deterministically (the live socket path is hard to observe).
/// Builds the full rc1-s system (core + memory + debug module, wired both ways)
/// exactly like river_sim's remote_bitbang path, and returns the core.
Future<RiverCore> _buildFull(Logic clk, Logic reset) async {
  const xlen = 64;
  final coreConfig = RiverCoreConfigV1.small(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    resetVector: 0,
  );
  final wbConfig = WishboneConfig(
    addressWidth: xlen,
    dataWidth: xlen,
    selWidth: xlen ~/ 8,
  );
  final storage = SparseMemoryStorage(
    addrWidth: xlen,
    dataWidth: xlen,
    alignAddress: (addr) => addr,
    onInvalidRead: (addr, dataWidth) =>
        LogicValue.filled(dataWidth, LogicValue.zero),
  );
  for (var a = 0; a < 0x400; a += 8) {
    storage.setData(
      LogicValue.ofInt(a, xlen),
      LogicValue.ofInt(0x0000001300000013, xlen),
    );
  }
  final core = RiverCore(coreConfig, busConfig: wbConfig, withDebug: true);
  core.input('clk').srcConnection! <= clk;
  core.input('reset').srcConnection! <= reset;
  await core.build();
  final wb = core.interface('dataBus').interface as WishboneInterface;
  final memRead = DataPortInterface(xlen, xlen);
  final memWrite = DataPortInterface(xlen, xlen);
  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [wrapWriteForRegisterFile(memWrite)],
    [wrapReadForRegisterFile(memRead)],
    storage: storage,
  );
  memRead.en <= wb.cyc & wb.stb & ~wb.we;
  memRead.addr <= wb.adr;
  memWrite.en <= wb.cyc & wb.stb & wb.we;
  memWrite.addr <= wb.adr;
  memWrite.data <= wb.datMosi;
  final wbAck = Logic(name: 'wbAck');
  Sequential(clk, [
    If(
      reset,
      then: [wbAck < 0],
      orElse: [
        If(wb.cyc & wb.stb & ~wbAck, then: [wbAck < 1], orElse: [wbAck < 0]),
      ],
    ),
  ]);
  wb.ack <= wbAck;
  wb.datMiso <= memRead.data;
  final tck = Logic(name: 'tck');
  final tms = Logic(name: 'tms');
  final tdi = Logic(name: 'tdi');
  final trstN = Logic(name: 'trst_n');
  final sbaRdata = Logic(name: 'sba_rdata', width: xlen);
  final sbaAck = Logic(name: 'sba_ack');
  final dbg = RiverDebugModule(
    clk,
    reset,
    tck,
    tms,
    tdi,
    trstN,
    hartHalted: core.output('debug_halted'),
    regRdata: core.output('debug_reg_rdata'),
    regReady: core.output('debug_reg_ready'),
    sbaRdata: sbaRdata,
    sbaAck: sbaAck,
    xlen: xlen,
    idcode: 0x10000001,
  );
  await dbg.build();
  core.input('debug_halt_req').srcConnection! <= dbg.haltReq;
  core.input('debug_resume_req').srcConnection! <= dbg.resumeReq;
  core.input('debug_reg_read').srcConnection! <= dbg.regRead;
  core.input('debug_reg_write').srcConnection! <= dbg.regWrite;
  core.input('debug_reg_addr').srcConnection! <= dbg.regAddr;
  core.input('debug_reg_wdata').srcConnection! <= dbg.regWdata;
  tck.inject(0);
  tms.inject(0);
  tdi.inject(0);
  trstN.inject(1);
  sbaRdata.inject(0);
  sbaAck.inject(0);
  return core;
}

void main() {
  test(
    'full rc1-s config + debug wiring advances the clock (no settle hang)',
    () async {
      await Simulator.reset();
      const xlen = 64;
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic(name: 'reset');

      // Mirror river_sim's rc1-s: small core WITH Sv39 in the paging modes.
      final coreConfig = RiverCoreConfigV1.small(
        interrupts: [],
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        clock: const HarborClockConfig(
          name: 'sysclk',
          rate: HarborFixedClockRate(48000000),
        ),
        resetVector: 0,
      );
      final wbConfig = WishboneConfig(
        addressWidth: xlen,
        dataWidth: xlen,
        selWidth: xlen ~/ 8,
      );

      final storage = SparseMemoryStorage(
        addrWidth: xlen,
        dataWidth: xlen,
        alignAddress: (addr) => addr,
        onInvalidRead: (addr, dataWidth) =>
            LogicValue.filled(dataWidth, LogicValue.zero),
      );
      for (var a = 0; a < 0x400; a += 8) {
        storage.setData(
          LogicValue.ofInt(a, xlen),
          LogicValue.ofInt(0x0000001300000013, xlen),
        );
      }

      final core = RiverCore(coreConfig, busConfig: wbConfig, withDebug: true);
      core.input('clk').srcConnection! <= clk;
      core.input('reset').srcConnection! <= reset;
      await core.build();

      final wb = core.interface('dataBus').interface as WishboneInterface;
      final memRead = DataPortInterface(xlen, xlen);
      final memWrite = DataPortInterface(xlen, xlen);
      // ignore: unused_local_variable
      final mem = MemoryModel(
        clk,
        reset,
        [wrapWriteForRegisterFile(memWrite)],
        [wrapReadForRegisterFile(memRead)],
        storage: storage,
      );
      memRead.en <= wb.cyc & wb.stb & ~wb.we;
      memRead.addr <= wb.adr;
      memWrite.en <= wb.cyc & wb.stb & wb.we;
      memWrite.addr <= wb.adr;
      memWrite.data <= wb.datMosi;
      final wbAck = Logic(name: 'wbAck');
      Sequential(clk, [
        If(
          reset,
          then: [wbAck < 0],
          orElse: [
            If(
              wb.cyc & wb.stb & ~wbAck,
              then: [wbAck < 1],
              orElse: [wbAck < 0],
            ),
          ],
        ),
      ]);
      wb.ack <= wbAck;
      wb.datMiso <= memRead.data;

      final tck = Logic(name: 'tck');
      final tms = Logic(name: 'tms');
      final tdi = Logic(name: 'tdi');
      final trstN = Logic(name: 'trst_n');
      final sbaRdata = Logic(name: 'sba_rdata', width: xlen);
      final sbaAck = Logic(name: 'sba_ack');
      final dbg = RiverDebugModule(
        clk,
        reset,
        tck,
        tms,
        tdi,
        trstN,
        hartHalted: core.output('debug_halted'),
        regRdata: core.output('debug_reg_rdata'),
        regReady: core.output('debug_reg_ready'),
        sbaRdata: sbaRdata,
        sbaAck: sbaAck,
        xlen: xlen,
        idcode: 0x10000001,
      );
      await dbg.build();
      core.input('debug_halt_req').srcConnection! <= dbg.haltReq;
      core.input('debug_resume_req').srcConnection! <= dbg.resumeReq;
      core.input('debug_reg_read').srcConnection! <= dbg.regRead;
      core.input('debug_reg_write').srcConnection! <= dbg.regWrite;
      core.input('debug_reg_addr').srcConnection! <= dbg.regAddr;
      core.input('debug_reg_wdata').srcConnection! <= dbg.regWdata;

      reset.inject(1);
      tck.inject(0);
      tms.inject(0);
      tdi.inject(0);
      trstN.inject(1);
      sbaRdata.inject(0);
      sbaAck.inject(0);

      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);

      // Free-run the clock like river_sim's loop. This proves the full rc1-s
      // config plus the bidirectional debug wiring settles and advances (it does).
      // NOTE: the live remote_bitbang socket can NOT be driven from this same
      // isolate: `Simulator.run()` starves socket/timer awaits, and a hand-pumped
      // `Simulator.tick()` loop deadlocks with the full core. The socket bridge
      // needs the simulation in a separate isolate (see project_debug_jtag).
      for (var i = 0; i < 100; i++) {
        await clk.nextPosedge;
      }

      expect(
        core.pipeline.nextPc.value.isValid,
        isTrue,
        reason: 'full config + debug wiring advanced 100 cycles',
      );

      await Simulator.endSimulation();
      await Simulator.simulationEnded;
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'rbb run loop (tick + periodic yield) advances core AND services I/O',
    () async {
      // This is exactly river_sim's remote_bitbang loop: hand-step the simulator
      // with `Simulator.tick()` and yield to the event loop every `yieldEvery`
      // ticks. It must (a) advance the full core and (b) let a concurrent async
      // task (the JTAG socket) make progress. `Simulator.run()` fails (b); a
      // per-tick yield is far too slow on the full core; per-N is the sweet spot.
      await Simulator.reset();
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic(name: 'reset');
      final core = await _buildFull(clk, reset);
      reset.inject(1);
      Simulator.setMaxSimTime(2000000);

      // A gentle background task (like a socket server waiting for data), NOT a
      // tight timer loop. It must get serviced while the sim advances.
      var ioTurns = 0;
      var running = true;
      unawaited(() async {
        while (running) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          ioTurns++;
        }
      }());

      const yieldEvery = 64;
      var cycles = 0;
      var prevClk = 0;
      var tickCount = 0;
      await Future<void>(() {});
      while (cycles < 100 && Simulator.hasStepsRemaining()) {
        await Simulator.tick();
        // Deassert reset exactly once (river_sim does this via a t=20 registered
        // action; injecting every tick re-propagates reset and is pathologically
        // slow).
        if (Simulator.time >= 20 &&
            reset.value.isValid &&
            reset.value.toBool()) {
          reset.inject(0);
        }
        final c = (clk.value.isValid && clk.value.toBool()) ? 1 : 0;
        if (c == 1 && prevClk == 0 && !reset.value.toBool()) cycles++;
        prevClk = c;
        if (++tickCount % yieldEvery == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      running = false;

      expect(cycles, 100, reason: 'rbb loop advanced the full core');
      expect(
        ioTurns,
        greaterThan(0),
        reason: 'concurrent async (the JTAG socket) was serviced, not starved',
      );
      expect(core.pipeline.nextPc.value.isValid, isTrue);

      Simulator.endSimulation();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
