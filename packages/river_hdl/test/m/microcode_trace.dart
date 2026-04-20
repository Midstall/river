import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';

import '../matrix_configs.dart';
import '../matrix_encoders.dart';

/// Diagnostic: dump a VCD of the in-order MICROCODE core running a single base
/// `add` cell, using the SAME memory/bus wiring as the matrix harness (a
/// MemoryModel + a registered Wishbone ack) so the timing is faithful (an
/// earlier ad-hoc combinational memory was misleading). Writes
/// /tmp/microcode_trace.vcd. Not an assertion test.
void main() async {
  await Simulator.reset();
  const xlen = 64;
  final config = matrixConfig(
    RiscVMxlen.rv64,
    Uarch.inOrder,
    'base',
    microcodeMode: MicrocodeMode.full,
  );
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic(name: 'reset');
  final core = RiverCore(
    config,
    busConfig: WishboneConfig(
      addressWidth: xlen,
      dataWidth: xlen,
      selWidth: xlen ~/ 8,
    ),
  );
  core.input('clk').srcConnection! <= clk;
  core.input('reset').srcConnection! <= reset;
  await core.build();

  final storage = SparseMemoryStorage(
    addrWidth: xlen,
    dataWidth: xlen,
    alignAddress: (addr) => addr,
    onInvalidRead: (addr, dataWidth) =>
        LogicValue.filled(dataWidth, LogicValue.zero),
  );
  final memRead = DataPortInterface(xlen, xlen);
  final memWrite = DataPortInterface(xlen, xlen);
  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [wrapWriteForRegisterFile(memWrite)],
    [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
    readLatency: 0,
    storage: storage,
  );
  final wbCyc = core.output('dataBus_CYC');
  final wbStb = core.output('dataBus_STB');
  final wbWe = core.output('dataBus_WE');
  memRead.en <= wbCyc & wbStb & ~wbWe;
  memRead.addr <= core.output('dataBus_ADR');
  memWrite.en <= wbCyc & wbStb & wbWe;
  memWrite.addr <= core.output('dataBus_ADR');
  memWrite.data <= core.output('dataBus_DAT_MOSI');
  final wbAckReg = Logic(name: 'wbAck');
  Sequential(clk, [
    If(
      reset,
      then: [wbAckReg < 0],
      orElse: [
        If(
          wbCyc & wbStb & ~wbAckReg & (wbWe | memRead.valid),
          then: [wbAckReg < 1],
          orElse: [wbAckReg < 0],
        ),
      ],
    ),
  ]);
  final seedGate = Logic(name: 'seedGate');
  core.input('dataBus_ACK').srcConnection! <= wbAckReg & ~seedGate;
  core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

  WaveDumper(core, outputPath: '/tmp/microcode_trace.vcd');

  // base 'add' cell: addi x1,x0,-5 ; addi x2,x0,3 ; add x3,x1,x2 ; nop.
  final prog = <int>[
    iimm(-5, 0, 0x0, 1),
    iimm(3, 0, 0x0, 2),
    rtype(0x00, 2, 1, 0x0, 3),
    nop,
  ];
  final memStr = StringBuffer('@0\n');
  for (final w in prog) {
    for (var b = 0; b < 4; b++) {
      memStr.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      memStr.write(' ');
    }
  }

  reset.inject(1);
  seedGate.inject(0);
  Simulator.setMaxSimTime(60000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  await clk.nextPosedge;
  await clk.nextPosedge;
  storage.loadMemString(memStr.toString());
  reset.inject(0);
  for (var i = 0; i < 500; i++) {
    await clk.nextPosedge;
  }
  await Simulator.endSimulation();
}
