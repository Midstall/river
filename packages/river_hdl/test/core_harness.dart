import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

Future<void> coreTest(
  String memString,
  Map<Register, int> regStates,
  RiverCoreConfig config, {
  Map<int, int> memStates = const {},
  Map<Register, int> initRegisters = const {},
  int nextPc = 4,
  int latency = 0,
  int memLatency = 0,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();

  final addrWidth = config.mxlen.size;
  final wbConfig = WishboneConfig(
    addressWidth: addrWidth,
    dataWidth: config.mxlen.size,
    selWidth: config.mxlen.size ~/ 8,
  );

  // Drives the OoO physical-regfile backdoor seed: while high, a regWritePort
  // write also lands in the OoO prf so initRegisters reaches the OoO read path.
  final prfSeedMode = Logic(name: 'prfSeedMode');

  final core = RiverCore(config, busConfig: wbConfig, prfSeedMode: prfSeedMode);

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

  // Bridge Wishbone master to MemoryModel
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

  // wbAck honors the read port's latency: for reads, only acknowledge when the
  // slave actually has data ready (memRead.valid, `done` asserts immediately on
  // `en`, it only means the request was accepted). Writes are combinational, so
  // a one-cycle ack is correct.
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
  // While `seedGate` is high we starve the data-bus acknowledge so the fetcher
  // stalls on its first read and the pipeline cannot retire anything. This lets
  // us backdoor-seed the register file one entry per clock edge (the regfile has
  // a single write port and clears all entries while `reset` is asserted, so the
  // seed must happen post-reset, with the core held) before instructions run.
  final seedGate = Logic(name: 'seedGate');
  core.input('dataBus_ACK').srcConnection! <= wbAckReg & ~seedGate;
  core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

  reset.inject(1);
  seedGate.inject(initRegisters.isNotEmpty ? 1 : 0);
  // High through the seed window; the prf write is additionally gated by
  // regWritePort.en (in core.dart) so it only lands on an actual seed write.
  prfSeedMode.inject(initRegisters.isNotEmpty ? 1 : 0);

  Simulator.registerAction(20, () {
    reset.put(0);
    storage.loadMemString(memString);
  });

  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());

  await clk.nextPosedge;

  // Seed the register file one entry per clock edge (single write port). The
  // core is held by `seedGate` (no bus acks), so none of these writes races a
  // pipeline read-back.
  for (final regState in initRegisters.entries) {
    core.regWritePort.en.inject(1);
    core.regWritePort.addr.inject(LogicValue.ofInt(regState.key.value, 5));
    core.regWritePort.data.inject(
      LogicValue.ofInt(regState.value, config.mxlen.size),
    );
    await clk.nextPosedge;
  }

  // Disable register write port and release the core to run.
  core.regWritePort.en.inject(0);
  seedGate.inject(0);
  prfSeedMode.inject(0);

  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  for (var i = 0; i < 5000; i++) {
    await clk.nextPosedge;
    final pc = core.pipeline.nextPc.value;
    if (pc.isValid && pc.toInt() == nextPc) break;
  }

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  expect(core.pipeline.done.value.toBool(), isTrue);
  expect(core.pipeline.nextPc.value.toInt(), nextPc);

  for (final regState in regStates.entries) {
    final value = core.regs.getData(LogicValue.ofInt(regState.key.value, 5))!;
    expect(value.toInt(), regState.value, reason: '${regState.key}=$value');
  }

  for (final memState in memStates.entries) {
    expect(
      storage
          .getData(LogicValue.ofInt(memState.key, config.mxlen.size))!
          .toInt(),
      memState.value,
    );
  }
}
