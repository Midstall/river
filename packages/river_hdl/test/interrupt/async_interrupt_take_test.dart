import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Async interrupt-taking (mip&mie&mstatus.MIE -> vector to mtvec).
///
/// River rc1-f never carried interrupt VECTORING in the microcode path: mip was
/// plumbed but nothing computed pending&enabled and redirected the PC. Linux
/// needs it (the scheduler tick, SBI timer, softirqs). This drives a real
/// external IRQ line into the core, holds it while an M-mode program enables
/// interrupts and spins, and asserts the core vectors to mtvec with
/// mcause = interrupt|11 (MEI) and mepc = the interrupted PC.
///
/// The harness mirrors core_harness but adds the [srcIrqs] input and watches the
/// pipeline PC instead of a fixed retirement address.
Future<Map<String, int>> runIrqTest({
  required String memString,
  required Map<Register, int> initRegisters,
  required int handlerPc,
  required int parkPc,
  bool driveIrq = true,
  // When true, drive the machine timer-pending line (mip.MTIP) instead of the
  // external line, to exercise the CLINT timer path (mcause 7).
  bool driveTimer = false,
  // Cycle budget for the watch loop. The positive cases exit early once they
  // reach the handler park, so they use a generous budget; the negative case
  // runs the full span, so it uses a small one to stay fast.
  int maxCycles = 1200,
}) async {
  await Simulator.reset();
  final config = RiverCoreConfigV1.full(
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
  );

  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final irq = Logic(name: 'extIrq');
  final timerIrq = Logic(name: 'timerIrq');

  final addrWidth = config.mxlen.size;
  final wbConfig = WishboneConfig(
    addressWidth: addrWidth,
    dataWidth: config.mxlen.size,
    selWidth: config.mxlen.size ~/ 8,
  );

  final prfSeedMode = Logic(name: 'prfSeedMode');

  final core = RiverCore(
    config,
    busConfig: wbConfig,
    prfSeedMode: prfSeedMode,
    srcIrqs: {'extInt': irq},
    timerPending: timerIrq,
  );

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
    [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
    readLatency: 0,
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

  final seedGate = Logic(name: 'seedGate');
  core.input('dataBus_ACK').srcConnection! <= wbAckReg & ~seedGate;
  core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

  reset.inject(1);
  irq.inject(0);
  timerIrq.inject(0);
  seedGate.inject(initRegisters.isNotEmpty ? 1 : 0);
  prfSeedMode.inject(initRegisters.isNotEmpty ? 1 : 0);

  Simulator.registerAction(20, () {
    reset.put(0);
    storage.loadMemString(memString);
  });

  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());

  await clk.nextPosedge;

  for (final regState in initRegisters.entries) {
    core.regWritePort.en.inject(1);
    core.regWritePort.addr.inject(LogicValue.ofInt(regState.key.value, 5));
    core.regWritePort.data.inject(
      LogicValue.ofInt(regState.value, config.mxlen.size),
    );
    await clk.nextPosedge;
  }

  core.regWritePort.en.inject(0);
  seedGate.inject(0);
  prfSeedMode.inject(0);

  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  if (driveIrq) {
    irq.inject(1);
  }
  if (driveTimer) {
    timerIrq.inject(1);
  }

  var vectored = false;
  var reachedPark = false;
  for (var i = 0; i < maxCycles; i++) {
    await clk.nextPosedge;
    final pc = core.pipeline.nextPc.value;
    if (!pc.isValid) continue;
    final p = pc.toInt();
    if (p == handlerPc) vectored = true;
    if (p == parkPc) {
      reachedPark = true;
      break;
    }
  }

  // Let the handler's csr reads retire.
  for (var i = 0; i < 20; i++) {
    await clk.nextPosedge;
  }

  final mcause = core.regs
      .getData(LogicValue.ofInt(Register.x28.value, 5))!
      .toInt();
  final mepc = core.regs
      .getData(LogicValue.ofInt(Register.x29.value, 5))!
      .toInt();

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  return {
    'vectored': vectored ? 1 : 0,
    'reachedPark': reachedPark ? 1 : 0,
    'mcause': mcause,
    'mepc': mepc,
  };
}

/// Build the shared program: enable interrupts, spin, and a handler that
/// captures mcause/mepc.
String buildProgram() {
  // 0x00 csrw mtvec, x1     (x1 = handlerPc)
  // 0x04 csrw mie, x2       (x2 = 1<<11 MEIE)
  // 0x08 csrs mstatus, x3   (x3 = 1<<3 MIE)
  // 0x0c j 0x0c             (spin, this is mepc)
  // 0x100 csrr x28, mcause
  // 0x104 csrr x29, mepc
  // 0x108 j 0x108           (park)
  final words = <int, int>{
    0x00: 0x00000013, // nop (warmup)
    0x04: 0x00000013, // nop
    0x08: 0x30529073, // csrw mtvec, x5  (x5 = handler base 0x100)
    0x0c: 0x30431073, // csrw mie, x6    (x6 = MEIE = 1<<11)
    0x10: 0x3003a073, // csrs mstatus, x7 (x7 = MIE = 1<<3)
    0x14: 0x0000006f, // j 0x14  (spin, mepc)
    0x100: 0x34202e73, // csrr x28, mcause
    0x104: 0x34102ef3, // csrr x29, mepc
    0x108: 0x0000006f, // j 0x108
  };

  final bytes = <int, int>{};
  words.forEach((addr, w) {
    for (var b = 0; b < 4; b++) {
      bytes[addr + b] = (w >> (b * 8)) & 0xFF;
    }
  });
  final maxA = bytes.keys.reduce((a, b) => a > b ? a : b);
  final sb = StringBuffer('@0\n');
  for (var a = 0; a <= maxA + 1; a++) {
    sb.write((bytes[a] ?? 0).toRadixString(16).padLeft(2, '0'));
    sb.write(' ');
  }
  return sb.toString();
}

void main() {
  test(
    'async M-mode interrupt vectors to mtvec with mcause=MEI, mepc=spin',
    timeout: Timeout(Duration(minutes: 4)),
    () async {
      final result = await runIrqTest(
        memString: buildProgram(),
        initRegisters: {
          Register.x5: 0x100, // mtvec (direct mode, base 0x100)
          Register.x6: 1 << 11, // MEIE
          Register.x7: 1 << 3, // MIE
        },
        handlerPc: 0x100,
        parkPc: 0x108,
      );

      expect(
        result['reachedPark'],
        1,
        reason: 'core never reached the handler park',
      );
      expect(
        result['vectored'],
        1,
        reason: 'PC never hit the handler base 0x100',
      );
      // RV64 mcause: interrupt bit is bit 63, cause 11 (machine external).
      expect(result['mcause'], (1 << 63) | 11, reason: 'wrong mcause');
      expect(
        result['mepc'],
        0x14,
        reason: 'mepc must be the interrupted spin PC',
      );
    },
  );

  test(
    'CLINT machine-timer interrupt vectors with mcause=MTI (cause 7)',
    timeout: Timeout(Duration(minutes: 4)),
    () async {
      final result = await runIrqTest(
        memString: buildProgram(),
        initRegisters: {
          Register.x5: 0x100, // mtvec base
          Register.x6: 1 << 7, // MTIE (machine timer enable)
          Register.x7: 1 << 3, // MIE
        },
        handlerPc: 0x100,
        parkPc: 0x108,
        driveIrq: false,
        driveTimer: true,
      );

      expect(
        result['reachedPark'],
        1,
        reason: 'timer interrupt never reached the handler',
      );
      expect(
        result['vectored'],
        1,
        reason: 'PC never hit the handler on a timer IRQ',
      );
      expect(
        result['mcause'],
        (1 << 63) | 7,
        reason: 'wrong mcause for machine timer',
      );
      expect(
        result['mepc'],
        0x14,
        reason: 'mepc must be the interrupted spin PC',
      );
    },
  );

  test('interrupt does NOT vector while the IRQ line is low', () async {
    final result = await runIrqTest(
      memString: buildProgram(),
      initRegisters: {
        Register.x5: 0x100,
        Register.x6: 1 << 11,
        Register.x7: 1 << 3,
      },
      handlerPc: 0x100,
      parkPc: 0x108,
      driveIrq: false,
      maxCycles: 500,
    );

    expect(
      result['reachedPark'],
      0,
      reason: 'core vectored with no pending interrupt',
    );
    expect(result['vectored'], 0, reason: 'PC hit the handler with no IRQ');
  });
}
