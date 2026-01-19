import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:riscv/riscv.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

Future<void> execTest(
  int instr,
  Map<Register, int> regStates,
  Microcode microcode,
  Mxlen mxlen, {
  Map<int, int> memStates = const {},
  Map<CsrAddress, int> csrStates = const {},
  Map<int, int> initMem = const {},
  Map<CsrAddress, int> initCsrs = const {},
  Map<Register, int> initRegisters = const {},
  int nextPc = 4,
  int memLatency = 0,
  bool isDynamic = false,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final enable = Logic();
  final mode = Const(PrivilegeMode.machine.id, width: 3);

  final input = Const(instr, width: 32);

  final decoder = StaticInstructionDecoder(
    clk,
    reset,
    enable,
    input,
    microcode: microcode,
    mxlen: mxlen,
  );

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

  final memRead = DataPortInterface(mxlen.size, mxlen.size);
  final memWrite = DataPortInterface(mxlen.size + 7, mxlen.size);

  final backingMemRead = DataPortInterface(mxlen.size, mxlen.size);
  final backingMemWrite = DataPortInterface(mxlen.size, mxlen.size);

  final storage = SparseMemoryStorage(
    addrWidth: mxlen.size,
    dataWidth: mxlen.size,
    alignAddress: (addr) => addr,
    onInvalidRead: (addr, dataWidth) =>
        LogicValue.filled(dataWidth, LogicValue.zero),
  );

  final mem = MemoryModel(
    clk,
    reset,
    [backingMemWrite],
    [memRead, backingMemRead],
    readLatency: memLatency,
    storage: storage,
  );

  SizedWriteSingleDataPort(
    clk,
    reset,
    backingRead: backingMemRead,
    backingWrite: backingMemWrite,
    source: memWrite,
  );

  final rs1Read = DataPortInterface(mxlen.size, 5);
  final rs2Read = DataPortInterface(mxlen.size, 5);
  final rdWrite = DataPortInterface(mxlen.size, 5);

  final regs = RegisterFile(
    clk,
    reset,
    [rdWrite],
    [rs1Read, rs2Read],
    numEntries: 32,
  );

  final microcodeRead = DataPortInterface(
    microcode.mopWidth(mxlen),
    microcode.mopIndexWidth(mxlen),
  );

  RegisterFile(
    clk,
    reset,
    [],
    [microcodeRead],
    numEntries: microcode.encodedMops(mxlen).length,
    resetValue: microcode.encodedMops(mxlen),
  );

  final exec = isDynamic
      ? DynamicExecutionUnit(
          clk,
          reset,
          decoder.valid & decoder.done,
          Const(0, width: mxlen.size),
          Const(0, width: mxlen.size),
          mode,
          decoder.index,
          decoder.instrTypeMap,
          decoder.fields,
          csrRead,
          csrWrite,
          memRead,
          memWrite,
          rs1Read,
          rs2Read,
          rdWrite,
          microcodeRead,
          microcode: microcode,
          mxlen: mxlen,
          mideleg: csrs.mideleg,
          medeleg: csrs.medeleg,
          mtvec: csrs.mtvec,
          stvec: csrs.stvec,
        )
      : StaticExecutionUnit(
          clk,
          reset,
          decoder.valid & decoder.done,
          Const(0, width: mxlen.size),
          Const(0, width: mxlen.size),
          mode,
          decoder.index,
          decoder.instrTypeMap,
          decoder.fields,
          csrRead,
          csrWrite,
          memRead,
          memWrite,
          rs1Read,
          rs2Read,
          rdWrite,
          microcode: microcode,
          mxlen: mxlen,
          mideleg: csrs.mideleg,
          medeleg: csrs.medeleg,
          mtvec: csrs.mtvec,
          stvec: csrs.stvec,
        );

  await exec.build();

  reset.inject(1);
  enable.inject(0);

  Simulator.registerAction(15, () {
    reset.put(0);

    for (final regState in initRegisters.entries) {
      regs.setData(
        LogicValue.ofInt(regState.key.value, 5),
        LogicValue.ofInt(regState.value, mxlen.size),
      );
    }

    for (final memState in initMem.entries) {
      storage.setData(
        LogicValue.ofInt(memState.key, mxlen.size),
        LogicValue.ofInt(memState.value, mxlen.size),
      );
    }

    for (final csrState in initCsrs.entries) {
      csrs.setData(
        LogicValue.ofInt(csrState.key.address, 12),
        LogicValue.ofInt(csrState.value, mxlen.size),
      );
    }

    enable.inject(1);
  });

  unawaited(Simulator.run());

  await clk.nextPosedge;

  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  for (final csrState in initCsrs.entries) {
    csrs
        .getBackdoor(LogicValue.ofInt(csrState.key.address, 12))
        .wrEn!
        .inject(0);
  }

  while (!exec.done.value.toBool()) {
    await clk.nextPosedge;
  }

  while (exec.nextPc.value.toInt() != nextPc) {
    await clk.nextPosedge;
  }

  await clk.nextPosedge;

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  expect(exec.done.value.toBool(), isTrue);
  expect(exec.valid.value.toBool(), isTrue);
  expect(exec.nextPc.value.toInt(), nextPc);

  for (final regState in regStates.entries) {
    final value = regs
        .getData(LogicValue.ofInt(regState.key.value, 5))!
        .toInt();
    expect(value, regState.value, reason: '${regState.key}=$value');
  }

  for (final memState in memStates.entries) {
    expect(
      storage.getData(LogicValue.ofInt(memState.key, mxlen.size))!.toInt(),
      memState.value,
    );
  }

  for (final csrState in csrStates.entries) {
    final value = csrs
        .getData(LogicValue.ofInt(csrState.key.address, 12))!
        .toInt();
    expect(value, csrState.value, reason: '${csrState.key}=$value');
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  void define(bool isDynamic) {
    group('RV32I', () {
      final microcode = Microcode(Microcode.buildDecodeMap([rv32i]));

      test(
        'addi increments register',
        () => execTest(
          0x00a08293,
          {Register.x5: 10},
          microcode,
          Mxlen.mxlen_32,
          isDynamic: isDynamic,
        ),
      );

      test(
        'add performs register addition',
        () => execTest(
          0x005303B3,
          {Register.x7: 16},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 7, Register.x6: 9},
          isDynamic: isDynamic,
        ),
      );

      test(
        'lw loads from memory',
        () => execTest(
          0x0042A303,
          {Register.x6: 0xDEADBEEF},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 0x20},
          initMem: {0x24: 0xDEADBEEF},
          isDynamic: isDynamic,
        ),
      );

      test(
        'sw stores to memory',
        () => execTest(
          0x0062A223,
          {},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 0x20, Register.x6: 0xDEADBEEF},
          initMem: {},
          isDynamic: isDynamic,
        ),
      );

      test(
        'beq takes branch when equal',
        () => execTest(
          0x00628463,
          {},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 5, Register.x6: 5},
          nextPc: 8,
          isDynamic: isDynamic,
        ),
      );

      test(
        'beq does not branch when not equal',
        () => execTest(
          0x00628463,
          {},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 5, Register.x6: 7},
          nextPc: 4,
          isDynamic: isDynamic,
        ),
      );

      test(
        'lui loads upper immediate',
        () => execTest(
          0x123452B7,
          {Register.x5: 0x12345000},
          microcode,
          Mxlen.mxlen_32,
          isDynamic: isDynamic,
        ),
      );

      test(
        'jal writes ra and jumps',
        () => execTest(
          0x100002EF,
          {Register.x5: 4},
          microcode,
          Mxlen.mxlen_32,
          nextPc: 0x100,
          isDynamic: isDynamic,
        ),
      );

      test(
        'auipc adds immediate to PC',
        () => execTest(
          0x00010297,
          {Register.x5: 0x10000},
          microcode,
          Mxlen.mxlen_32,
          isDynamic: isDynamic,
        ),
      );

      test(
        'slti sets when less-than immediate',
        () => execTest(
          0x00A22293,
          {Register.x5: 1},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x4: 5},
          isDynamic: isDynamic,
        ),
      );
    });

    group('Zicsr', () {
      final microcode = Microcode(Microcode.buildDecodeMap([rv32i, rv32Zicsr]));

      test(
        'csrrw: atomic swap (rd=old, CSR=new)',
        () => execTest(
          0x34029373,
          {Register.x6: 0xAAAA},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 0x1234},
          initCsrs: {CsrAddress.mscratch: 0xAAAA},
          csrStates: {CsrAddress.mscratch: 0x1234},
          isDynamic: isDynamic,
        ),
      );

      test(
        'csrrw with rd=x0 still writes CSR but suppresses rd write',
        () => execTest(
          0x34029073,
          {Register.x0: 0},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 0x2222},
          initCsrs: {CsrAddress.mscratch: 0x1111},
          csrStates: {CsrAddress.mscratch: 0x2222},
          isDynamic: isDynamic,
        ),
      );

      test(
        'csrrs: rd=old, CSR |= rs1',
        () => execTest(
          0x3402A373,
          {Register.x6: 0x100},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 0x0F},
          initCsrs: {CsrAddress.mscratch: 0x100},
          csrStates: {CsrAddress.mscratch: 0x10F},
          isDynamic: isDynamic,
        ),
      );

      test(
        'csrrs with rs1=x0 only reads CSR',
        () => execTest(
          0x3400A073,
          {},
          microcode,
          Mxlen.mxlen_32,
          initCsrs: {CsrAddress.mscratch: 0xABCDE},
          csrStates: {CsrAddress.mscratch: 0xABCDE},
          isDynamic: isDynamic,
        ),
      );

      test(
        'csrrc: CSR &= ~rs1',
        () => execTest(
          0x3402B373,
          {Register.x6: 0xFF},
          microcode,
          Mxlen.mxlen_32,
          initRegisters: {Register.x5: 0x0F},
          initCsrs: {CsrAddress.mscratch: 0xFF},
          csrStates: {CsrAddress.mscratch: 0xF0},
          isDynamic: isDynamic,
        ),
      );

      test(
        'csrrwi: CSR = imm, rd = old CSR',
        () => execTest(
          0x3402D373,
          {Register.x6: 0x7777},
          microcode,
          Mxlen.mxlen_32,
          initCsrs: {CsrAddress.mscratch: 0x7777},
          csrStates: {CsrAddress.mscratch: 5},
          isDynamic: isDynamic,
        ),
      );

      test(
        'csrrsi: CSR |= imm',
        () => execTest(
          0x3401E073,
          {},
          microcode,
          Mxlen.mxlen_32,
          initCsrs: {CsrAddress.mscratch: 0x10},
          csrStates: {CsrAddress.mscratch: 0x13},
          isDynamic: isDynamic,
        ),
      );

      test(
        'csrrsi: CSR &= ~imm',
        () => execTest(
          0x3401F073,
          {},
          microcode,
          Mxlen.mxlen_32,
          initCsrs: {CsrAddress.mscratch: 0xF},
          csrStates: {CsrAddress.mscratch: 0xC},
          isDynamic: isDynamic,
        ),
      );
    });
  }

  group('Static execution', () => define(false));
  group('Dynamic execution', () => define(true));
}
