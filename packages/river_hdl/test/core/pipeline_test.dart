import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:riscv/riscv.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

Future<void> pipelineTest(
  int instr,
  Map<Register, int> regStates,
  Microcode microcode,
  Mxlen mxlen, {
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

  final mem = MemoryModel(
    clk,
    reset,
    [],
    [memFetchRead, memExecRead],
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
    [rdWrite],
    [rs1Read, rs2Read],
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

  Simulator.registerAction(20, () {
    reset.put(0);

    for (final regState in initRegisters.entries) {
      regs.setData(
        LogicValue.ofInt(regState.key.value, 5),
        LogicValue.ofInt(regState.value, mxlen.size),
      );
    }

    enable.put(1);
  });

  Simulator.setMaxSimTime(maxSimTime * ((latency ~/ 36) + 1));
  unawaited(Simulator.run());

  for (var i = 0; i < cycleCount; i++) {
    await clk.nextPosedge;
  }

  await Simulator.simulationEnded;

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
    final microcode = Microcode(Microcode.buildDecodeMap([rv32i]));

    test(
      'addi increments register',
      () => pipelineTest(
        0x00a08293,
        {Register.x5: 10},
        microcode,
        Mxlen.mxlen_32,
      ),
    );

    test(
      'add performs register addition',
      () => pipelineTest(
        0x005303B3,
        {Register.x7: 16},
        microcode,
        Mxlen.mxlen_32,
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
        Mxlen.mxlen_32,
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
        Mxlen.mxlen_32,
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
        Mxlen.mxlen_32,
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
        Mxlen.mxlen_32,
        maxSimTime: 800,
      ),
    );

    test(
      'slti sets when less-than immediate',
      () => pipelineTest(
        0x00A22293,
        {Register.x5: 1},
        microcode,
        Mxlen.mxlen_32,
        initRegisters: {Register.x4: 5},
        maxSimTime: 800,
      ),
    );
  });
}
