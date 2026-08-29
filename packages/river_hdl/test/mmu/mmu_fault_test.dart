import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// End-to-end MMU page-fault: a store to a read-only mapped page must raise a
/// store page fault (cause 15), matching the emulator. Observes the pipeline's
/// trap/trapCause directly (independent of the trap vector).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'Sv39 store to a read-only page raises storePageFault (cause 15)',
    () async {
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

      // l0 leaf @ 0x12100 = 0xC00B: V=1,R=1,W=0,X=1 -> read-only (store faults).
      const memString = '''@0
73 10 05 18 37 06 02 00 93 06 50 00 23 30 d6 00
13 00 00 00
@10000
01 44 00 00 00 00 00 00
@11000
01 48 00 00 00 00 00 00
@12000
0F 00 00 00 00 00 00 00
@12100
0B C0 00 00 00 00 00 00
''';

      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic();
      final addrWidth = config.mxlen.size;
      final wbConfig = WishboneConfig(
        addressWidth: addrWidth,
        dataWidth: config.mxlen.size,
        selWidth: config.mxlen.size ~/ 8,
      );

      // Translation applies only in S/U mode (no MPRV in River), so the store
      // page-fault must be observed from S-mode, not the M-mode reset default.
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
        // satp: Sv39 (MODE 8) | root PPN 0x10.
        core.regWritePort.data.inject(LogicValue.ofInt(0x8000000000000010, 64));
        storage.loadMemString(memString);
      });
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      core.regWritePort.en.inject(0);
      while (reset.value.toBool()) {
        await clk.nextPosedge;
      }

      var sawStoreFault = false;
      var sawWriteTo30000 = false;
      for (var i = 0; i < 200; i++) {
        await clk.nextPosedge;
        // The translated write would target 0x30000, it must never happen.
        final adr = wbAdr.value;
        if (wbCyc.value.toInt() == 1 &&
            wbWe.value.toInt() == 1 &&
            adr.isValid &&
            adr.toInt() == 0x30000) {
          sawWriteTo30000 = true;
        }
        final trap = core.pipeline.trap.value;
        if (trap.isValid && trap.toInt() == 1) {
          final cause = core.pipeline.trapCause.value;
          expect(cause.isValid, isTrue, reason: 'trapCause invalid');
          expect(
            cause.toInt(),
            Trap.storePageFault.causeCode,
            reason: 'expected storePageFault (15), got ${cause.toInt()}',
          );
          sawStoreFault = true;
          break;
        }
      }

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      expect(
        sawStoreFault,
        isTrue,
        reason: 'no trap raised for read-only store',
      );
      expect(
        sawWriteTo30000,
        isFalse,
        reason: 'faulting store must not write memory',
      );
    },
  );
}
