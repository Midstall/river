import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Isolation test: fetch to an unmapped page with NO icache (memFetchRead talks
/// straight to the MMU). Confirms the MMU raises the fetch fault and the
/// compressed fetch buffer delivers it as instructionPageFault (cause 12). If
/// this passes but the icache variant does not, the icache loses the fault.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('unmapped fetch (no icache) raises instructionPageFault (12)', () async {
    final config = RiverCoreConfig(
      mxlen: RiscVMxlen.rv64,
      extensions: kRva22S64Extensions,
      type: RiverCoreType.general,
      mmu: HarborMmuConfig(
        mxlen: RiscVMxlen.rv64,
        pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
        hasSupervisorUserMemory: true,
        hasMakeExecutableReadable: true,
      ),
      interrupts: [],
      clock: const HarborClockConfig(
        name: 'test',
        rate: HarborFixedClockRate(10000),
      ),
    );

    // csrw satp,a0 ; auipc t0,0x8 ; jalr x0,0(t0) ; nop  then page tables.
    const memString = '''@0
73 10 05 18 97 82 00 00 67 80 02 00 13 00 00 00
@10000
01 44 00 00 00 00 00 00
@11000
01 48 00 00 00 00 00 00
@12000
0F 00 00 00 00 00 00 00
''';

    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic();
    final addrWidth = config.mxlen.size;
    final wbConfig = WishboneConfig(
      addressWidth: addrWidth,
      dataWidth: config.mxlen.size,
      selWidth: config.mxlen.size ~/ 8,
    );

    final core = RiverCore(
      config,
      busConfig: wbConfig,
      resetPrivilege: PrivilegeMode.supervisor.id,
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
    core.input('dataBus_ACK').srcConnection! <= wbAckReg;
    core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

    reset.inject(1);
    Simulator.registerAction(20, () {
      reset.put(0);
      core.regWritePort.en.inject(1);
      core.regWritePort.addr.inject(LogicValue.ofInt(10, 5));
      core.regWritePort.data.inject(LogicValue.ofInt(0x8000000000000010, 64));
      storage.loadMemString(memString);
    });
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    core.regWritePort.en.inject(0);
    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }

    var sawFetchFault = false;
    for (var i = 0; i < 2000; i++) {
      await clk.nextPosedge;
      final trap = core.pipeline.trap.value;
      if (trap.isValid && trap.toInt() == 1) {
        final cause = core.pipeline.trapCause.value;
        final epc = core.pipeline.trapEpc.value;
        // ignore: avoid_print
        print(
          'TRAP cause=${cause.toInt()} '
          'epc=0x${epc.isValid ? epc.toInt().toRadixString(16) : "x"}',
        );
        expect(
          cause.toInt(),
          Trap.instructionPageFault.causeCode,
          reason: 'expected instructionPageFault (12), got ${cause.toInt()}',
        );
        sawFetchFault = true;
        break;
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    expect(sawFetchFault, isTrue, reason: 'no fetch fault raised');
  });
}
