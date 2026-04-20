import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

Future<void> pipelineTest(
  int instr,
  Map<Register, int> regStates,
  MicrocodeRom microcode,
  RiscVMxlen mxlen, {
  Map<Register, int> initRegisters = const {},
  int maxSimTime = 800,
  int cycleCount = 8,
  int nextPc = 4,
  int latency = 0,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final enable = Logic();
  final mode = Const(PrivilegeMode.machine.id, width: 3);

  final csrRead = DataPortInterface(mxlen.size, 12);
  final csrWrite = DataPortInterface(mxlen.size, 12);

  final csrs = RiscVCsrFile(
    clk,
    reset,
    mode,
    mxlen: mxlen,
    misa: mxlen.misa,
    csrRead: csrRead,
    csrWrite: csrWrite,
  );

  final memFetchRead = DataPortInterface(mxlen.size, mxlen.size);
  final memExecRead = DataPortInterface(mxlen.size, mxlen.size);
  final memWrite = DataPortInterface(mxlen.size + 7, mxlen.size);

  final rs1Read = DataPortInterface(mxlen.size, 5);
  final rs2Read = DataPortInterface(mxlen.size, 5);
  final rdWrite = DataPortInterface(mxlen.size, 5);

  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [],
    [
      wrapReadForRegisterFile(memFetchRead),
      wrapReadForRegisterFile(memExecRead),
    ],
    readLatency: latency,
    storage: SparseMemoryStorage(
      addrWidth: mxlen.size,
      dataWidth: mxlen.size,
      alignAddress: (addr) => addr,
      onInvalidRead: (addr, dataWidth) =>
          LogicValue.ofInt(addr.toInt() == 0 ? instr : 0, dataWidth),
    ),
  );

  final regs = RegisterFile(
    clk,
    reset,
    [wrapWriteForRegisterFile(rdWrite)],
    [wrapReadForRegisterFile(rs1Read), wrapReadForRegisterFile(rs2Read)],
    numEntries: 32,
  );

  final pipeline = RiverPipeline(
    clk,
    reset,
    enable,
    Const(0, width: mxlen.size),
    Const(0, width: mxlen.size),
    mode,
    csrRead,
    csrWrite,
    memFetchRead,
    memExecRead,
    memWrite,
    rs1Read,
    rs2Read,
    rdWrite,
    null,
    null,
    microcode: microcode,
    mxlen: mxlen,
    mideleg: csrs.mideleg,
    medeleg: csrs.medeleg,
    mtvec: csrs.mtvec,
    stvec: csrs.stvec,
  );

  await pipeline.build();

  reset.inject(1);
  enable.inject(0);

  Simulator.setMaxSimTime(2000 + maxSimTime * ((latency ~/ 36) + 1));
  unawaited(Simulator.run());

  // Release reset
  await clk.nextPosedge;
  reset.put(0);

  // Write initial register values one per cycle
  for (final regState in initRegisters.entries) {
    rdWrite.en.inject(1);
    rdWrite.addr.inject(LogicValue.ofInt(regState.key.value, 5));
    rdWrite.data.inject(LogicValue.ofInt(regState.value, mxlen.size));
    await clk.nextPosedge;
  }
  rdWrite.en.inject(0);

  // Enable pipeline
  enable.put(1);

  // Wait for pipeline done
  for (var i = 0; i < 100; i++) {
    await clk.nextPosedge;
    final d = pipeline.done.value;
    if (d.isValid && d.toBool()) break;
  }

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  expect(pipeline.done.value.isValid, isTrue);
  expect(pipeline.done.value.toBool(), isTrue);
  expect(pipeline.nextPc.value.toInt(), nextPc);

  for (final regState in regStates.entries) {
    expect(
      regs.getData(LogicValue.ofInt(regState.key.value, 5))!.toInt(),
      regState.value,
    );
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('RV32I', () {
    final microcode = MicrocodeRom(
      RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]),
    );

    test(
      'addi increments register',
      () => pipelineTest(
        0x00a08293,
        {Register.x5: 10},
        microcode,
        RiscVMxlen.rv32,
      ),
    );

    test(
      'add performs register addition',
      () => pipelineTest(
        0x005303B3,
        {Register.x7: 16},
        microcode,
        RiscVMxlen.rv32,
        initRegisters: {Register.x5: 7, Register.x6: 9},
        maxSimTime: 800,
      ),
    );

    test(
      'beq takes branch when equal',
      () => pipelineTest(
        0x00628463,
        {},
        microcode,
        RiscVMxlen.rv32,
        initRegisters: {Register.x5: 5, Register.x6: 5},
        nextPc: 8,
        maxSimTime: 800,
      ),
    );

    test(
      'beq does not branch when not equal',
      () => pipelineTest(
        0x00628463,
        {},
        microcode,
        RiscVMxlen.rv32,
        initRegisters: {Register.x5: 5, Register.x6: 7},
        nextPc: 4,
        maxSimTime: 800,
      ),
    );

    test(
      'jal writes ra and jumps',
      () => pipelineTest(
        0x100002EF,
        {Register.x5: 4},
        microcode,
        RiscVMxlen.rv32,
        nextPc: 0x100,
        maxSimTime: 800,
      ),
    );

    test(
      'auipc adds immediate to PC',
      () => pipelineTest(
        0x00010297,
        {Register.x5: 0x10000},
        microcode,
        RiscVMxlen.rv32,
        maxSimTime: 800,
      ),
    );

    test(
      'slti sets when less-than immediate',
      () => pipelineTest(
        0x00A22293,
        {Register.x5: 1},
        microcode,
        RiscVMxlen.rv32,
        initRegisters: {Register.x4: 5},
        maxSimTime: 800,
      ),
    );
  });
}
