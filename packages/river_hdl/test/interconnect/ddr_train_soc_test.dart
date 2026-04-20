import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

import '../matrix_encoders.dart';

/// End-to-end: the River CPU drives the opt-in DDR read-training MMIO window.
/// A program writes RDTAP_TARGET + pulses CTL.SET, then polls STATUS until the
/// reported current tap reaches the target, proving the CPU -> bus -> control
/// register -> Ecp5DelayController path works as a whole SoC fragment. The DDR
/// array itself is never touched (its PHY is an analog blackbox); code/data
/// live in a separate memory slave. See project_ddr_training.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Result of a CPU tap-walk run: the PC the core reached and the tap it read
  /// back (null when the program ran away / never wrote the result register).
  ///
  /// Builds the SoC fragment (core + trainable DDR controller + code/data
  /// memory), runs [program], and returns where the PC landed plus x1.
  ///
  /// [ddrBase] is the controller's array base; the control window then lives at
  /// [ddrBase] + arraySize. The DRAM array span is a power of two
  /// (HarborDdrConfig.orangeCrab => 128 MB), so the control window's address has
  /// bit 31 set whenever [ddrBase] is 0x80000000 (the real OrangeCrab map), the
  /// case that exposes the RV64 `lui` sign-extension trap.
  ///
  /// The address decode mirrors the genip SoC: the DDR slave owns
  /// `[ddrBase, ddrBase + arraySize + trainCtrlSize)` (the same range the
  /// Harbor WishboneDecoder derives from the controller's device-tree `reg`),
  /// and the low code/data memory owns everything below. The decode itself is
  /// the same unsigned `gte/lt` compare the real WishboneDecoder uses, so a
  /// no-ack/hang here is a faithful reproduction of the fabric-level behavior.
  Future<({int? reachedPc, int? tap})> runTapWalk({
    required int ddrBase,
    required List<int> program,
    required int haltPc,
    int maxCycles = 8000,
  }) async {
    const mxlen = RiscVMxlen.rv64;
    final config = RiverCoreConfig(
      clock: const HarborClockConfig(
        name: 'sysclk',
        rate: HarborFixedClockRate(48000000),
      ),
      mxlen: mxlen,
      extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvPriv],
      interrupts: const [],
      mmu: HarborMmuConfig(
        mxlen: mxlen,
        pagingModes: const [RiscVPagingMode.bare],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      ),
      type: RiverCoreType.general,
    );

    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final aw = mxlen.size;
    final dw = mxlen.size;
    final wbConfig = WishboneConfig(
      addressWidth: aw,
      dataWidth: dw,
      selWidth: dw ~/ 8,
    );

    final core = RiverCore(config, busConfig: wbConfig);
    core.input('clk').srcConnection! <= clk;
    core.input('reset').srcConnection! <= reset;

    const ddrConfig = HarborDdrConfig.orangeCrab();
    final ddr = HarborDdrController(
      config: ddrConfig,
      baseAddress: ddrBase,
      busAddressWidth: aw,
    );
    ddr.input('clk').srcConnection! <= clk;
    ddr.input('reset').srcConnection! <= reset;

    await core.build();
    await ddr.build();

    // Core Wishbone master.
    final wbCyc = core.output('dataBus_CYC');
    final wbStb = core.output('dataBus_STB');
    final wbWe = core.output('dataBus_WE');
    final wbAdr = core.output('dataBus_ADR');
    final wbDatMosi = core.output('dataBus_DAT_MOSI');

    // Address decode the genip way: the DDR slave owns its declared bus range
    // (array + train-control window), the same range the Harbor WishboneDecoder
    // derives from the controller's device-tree `reg`. The compare is the same
    // unsigned `gte/lt` the real decoder uses (WishboneDecoder.hit_i), so a high
    // (bit-31-set) control address that the core sign-extends will miss this
    // window exactly as it misses the fabric decoder on hardware.
    final ctrlLo = ddrBase + ddrConfig.size;
    // The committed clk90 DDR controller has no train-control window, so this
    // whole SoC fragment no longer applies; the tests below are skipped. Use a
    // nominal window size purely so the (skipped) helper still compiles.
    const trainCtrlSize = 0x1000;
    final ctrlHi = ctrlLo + trainCtrlSize;
    final ctrlSel =
        wbAdr.gte(Const(ctrlLo, width: aw)) &
        wbAdr.lt(Const(ctrlHi, width: aw));

    // Code/data memory slave: everything below the DDR array base.
    final storage = SparseMemoryStorage(
      addrWidth: aw,
      dataWidth: dw,
      alignAddress: (addr) => addr,
      onInvalidRead: (addr, w) => LogicValue.filled(w, LogicValue.zero),
    );
    final memRead = DataPortInterface(dw, aw);
    final memWrite = DataPortInterface(dw, aw);
    // The code/data memory owns everything the control window does not. Code
    // always lives in the low region (below the control window), so a plain
    // ~ctrlSel keeps the original low-window behavior and, in the high-window
    // case, still serves instruction fetch at low addresses. A control access
    // that the core sign-extends to a high address has bit 31 set and is NOT in
    // the control window, so it lands here on ~ctrlSel - but its address is
    // 0xFFFFFFFF_88.. which no real storage backs, and (critically) the
    // sign-extended store address never matches the control window, so the
    // DELAY controller is never reached. To make the HANG observable rather
    // than silently served by this catch-all memory, restrict the memory slave
    // to the genuine low region [0, ctrlLo): a high sign-extended access then
    // selects NEITHER slave and no ack returns.
    final memSel = wbAdr.lt(Const(ctrlLo, width: aw));
    // ignore: unused_local_variable
    final mem = MemoryModel(
      clk,
      reset,
      [wrapWriteForRegisterFile(memWrite)],
      [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
      readLatency: 0,
      storage: storage,
    );
    memRead.en <= wbCyc & wbStb & ~wbWe & memSel;
    memRead.addr <= wbAdr;
    memWrite.en <= wbCyc & wbStb & wbWe & memSel;
    memWrite.addr <= wbAdr;
    memWrite.data <= wbDatMosi;

    final memAck = Logic(name: 'memAck');
    final memReady = wbWe | memRead.valid;
    Sequential(clk, [
      If(
        reset,
        then: [memAck < 0],
        orElse: [
          If(
            wbCyc & wbStb & memSel & ~memAck & memReady,
            then: [memAck < 1],
            orElse: [memAck < 0],
          ),
        ],
      ),
    ]);

    // DDR control slave - drive its bus from the master. The slave address is
    // window-relative (control offset above the array): the decoder subtracts
    // the slave's range start, so present `wbAdr - ctrlLo` (== array-relative
    // control offset 0x00..) low bits, matching what the controller decodes.
    final ctrlOff =
        (wbAdr - Const(ctrlLo, width: aw)) + Const(ddrConfig.size, width: aw);
    ddr.input('bus_CYC').srcConnection! <= wbCyc & ctrlSel;
    ddr.input('bus_STB').srcConnection! <= wbStb & ctrlSel;
    ddr.input('bus_WE').srcConnection! <= wbWe;
    ddr.input('bus_ADR').srcConnection! <=
        ctrlOff.getRange(0, ddr.input('bus_ADR').width);
    ddr.input('bus_DAT_MOSI').srcConnection! <=
        wbDatMosi.getRange(0, ddr.input('bus_DAT_MOSI').width);
    ddr.input('bus_SEL').srcConnection! <=
        Const(0, width: ddr.input('bus_SEL').width);
    final ddrAck = ddr.output('bus_ACK');
    final ddrMiso = ddr.output('bus_DAT_MISO');

    // Merge the two slaves back onto the master. A control access that misses
    // the window (sign-extended high address) selects NEITHER slave, so no ack
    // is ever returned and the CPU stalls - the hardware control-window hang.
    core.input('dataBus_ACK').srcConnection! <= mux(ctrlSel, ddrAck, memAck);
    core.input('dataBus_DAT_MISO').srcConnection! <=
        mux(ctrlSel, ddrMiso.zeroExtend(dw), memRead.data);

    String memString(List<int> ws) {
      final sb = StringBuffer();
      for (final w in ws) {
        for (var b = 0; b < 4; b++) {
          sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      return sb.toString().trimRight();
    }

    reset.inject(1);
    Simulator.registerAction(20, () {
      reset.put(0);
      storage.loadMemString(memString(program));
    });
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }
    var reached = false;
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      final pc = core.pipeline.nextPc.value;
      if (pc.isValid && pc.toInt() == haltPc) {
        reached = true;
        break;
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;

    final pc = core.pipeline.nextPc.value;
    final reachedPc = reached && pc.isValid ? pc.toInt() : null;
    final x1v = core.regs.getData(LogicValue.ofInt(1, 5));
    final tap = (x1v != null && x1v.isValid) ? x1v.toInt() : null;
    return (reachedPc: reachedPc, tap: tap);
  }

  /// Tap-walk program. [baseSetup] builds the control-window base into x10
  /// (its length in instructions shifts every later PC), then the body writes
  /// RDTAP_TARGET, pulses CTL.SET, and polls STATUS until currentTap == target.
  /// x1 ends holding the trained tap.
  ({List<int> program, int haltPc}) tapWalkProgram(List<int> baseSetup) {
    const target = 12;
    final body = <int>[
      iimm(target, 0, 0x0, 11), // addi x11, x0, 12
      store(0x00, 11, 10, 0x2), // sw  x11, 0x00(x10)  RDTAP_TARGET = 12
      iimm(1, 0, 0x0, 11), // addi x11, x0, 1
      store(0x08, 11, 10, 0x2), // sw  x11, 0x08(x10)  CTL = SET
      // loop: x12 = (STATUS >> 1) & 0x7F; if x12 != 12 goto loop
      load(0x18, 10, 0x2, 12), // lw  x12, 0x18(x10)  STATUS
      iimm(1, 12, 0x5, 12), // srli x12, x12, 1
      iimm(0x7F, 12, 0x7, 12), // andi x12, x12, 0x7F
      iimm(target, 0, 0x0, 13), // addi x13, x0, 12
      branch(-16, 13, 12, 0x1), // bne x12, x13, loop
      rtype(0x00, 0, 12, 0x0, 1), // add x1, x12, x0  -> x1 = tap
      nop,
    ];
    final program = [...baseSetup, ...body];
    final haltPc = (program.length - 1) * 4;
    return (program: program, haltPc: haltPc);
  }

  test('CPU walks the DDR read tap through the MMIO control window '
      '(low window, base 0)', () async {
    // Array base 0; control window at 0x08000000 (the 128MB boundary, bit 31
    // clear). lui builds the base directly with no sign extension.
    final p = tapWalkProgram([
      lui(0x08000, 10), // x10 = 0x08000000 (control window base)
    ]);
    final r = await runTapWalk(
      ddrBase: 0,
      program: p.program,
      haltPc: p.haltPc,
    );
    expect(r.reachedPc, p.haltPc, reason: 'program should reach the halt nop');
    expect(r.tap, 12, reason: 'CPU read the trained tap back as ${r.tap}');
  }, skip: 'committed clk90 DDR has no train-control MMIO window');

  test('high control window (base 0x80000000): naive lui sign-extends and the '
      'control access misses the window -> CPU hangs (hardware repro)', () async {
    // dramBase = 0x80000000, control window at 0x88000000 (bit 31 SET). On RV64
    // `lui 0x88000` loads 0x88000000 then SIGN-EXTENDS bit 31, so x10 becomes
    // 0xFFFFFFFF_88000000 and the store/load address is 0xFFFFFFFF_88000018,
    // which is NOT inside [0x80000000, 0x88001000). No slave decodes it, no ack
    // returns, and the CPU stalls forever on the first control store - exactly
    // the OrangeCrab control-window hang. This is a CORE/firmware address-math
    // trap, not an interconnect routing bug (the decode range already includes
    // the train-control window via trainCtrlSize, and the unsigned gte/lt
    // compare handles bit 31 fine - proven by the corrected-address case below).
    final p = tapWalkProgram([
      lui(0x88000, 10), // x10 = 0xFFFFFFFF88000000 (sign-extended!)
    ]);
    // The stall is permanent (no ack ever returns), so a short budget proves
    // it: a healthy run reaches the control window and walks 12 taps in ~150
    // cycles, so 600 cycles with the PC never reaching halt is a confirmed hang.
    final r = await runTapWalk(
      ddrBase: 0x80000000,
      program: p.program,
      haltPc: p.haltPc,
      maxCycles: 600,
    );
    expect(
      r.reachedPc,
      isNull,
      reason:
          'sign-extended high control address must hang (no ack), '
          'reproducing the hardware control-window hang',
    );
  }, skip: 'committed clk90 DDR has no train-control MMIO window');

  test('high control window (base 0x80000000): sign-extension-corrected base '
      'reaches the window -> tap walk completes (SoC path is clean)', () async {
    // The fix is in the ADDRESS MATH, not the HDL: clear the sign-extended upper
    // 32 bits after lui (slli 32 then srli 32) so x10 holds the true
    // 0x0000000088000000. The same decode + interconnect that hung above now
    // routes the control access correctly and the tap walk completes, proving
    // the SoC-level control plane (decode range, ack, delay controller) is X-
    // clean and bit-31-correct - the only defect was the naive lui.
    final p = tapWalkProgram([
      lui(0x88000, 10), // x10 = 0xFFFFFFFF88000000
      iimm(32, 10, 0x1, 10), // slli x10, x10, 32 -> 0x8800000000000000
      iimm(32, 10, 0x5, 10), // srli x10, x10, 32 -> 0x0000000088000000
    ]);
    final r = await runTapWalk(
      ddrBase: 0x80000000,
      program: p.program,
      haltPc: p.haltPc,
    );
    expect(r.reachedPc, p.haltPc, reason: 'program should reach the halt nop');
    expect(r.tap, 12, reason: 'CPU read the trained tap back as ${r.tap}');
  }, skip: 'committed clk90 DDR has no train-control MMIO window');
}
