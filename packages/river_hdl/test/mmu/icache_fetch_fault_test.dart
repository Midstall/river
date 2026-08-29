import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// A fetch whose translation faults must be delivered as an instruction page
/// fault, even with the VIVT icache and the microcode decoder in front. The
/// icache refills through the MMU fetch port; when that walk faults (done, not
/// valid) the fill FSM used to stall forever, and even once the fault reached the
/// FetchUnit the garbage bits did not decode (the microcode decoder never
/// validated them), so exec never ran and the held fetch fault was never taken.
/// With the fault propagated (mem_fault -> resp_fault -> FetchUnit) and a NOP
/// delivered in place of the faulting bits, the pipeline raises
/// instructionPageFault (cause 12) instead.
///
///   0x00 csrw satp, a0      enable Sv39 (a0 seeded to the root PPN)
///   0x04 auipc t0, 0x8      t0 = 0x8004
///   0x08 jalr  x0, 0(t0)    jump to VIRTUAL 0x8004 (VPN0 = 8, L0[8] absent)
///   0x0c nop
///
/// Page tables (Sv39, identity for the low code page, nothing at VPN0 = 8):
///   L2[0]@0x10000 = 0x4401 ; L1[0]@0x11000 = 0x4801 ; L0[0]@0x12000 = 0x000F
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig full() => RiverCoreConfigV1.full(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  test(
    'icache fetch to an unmapped page raises instructionPageFault (not a hang)',
    timeout: Timeout(Duration(minutes: 6)),
    () async {
      final config = full();

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
        // satp: Sv39 (MODE 8) | root PPN 0x10.
        core.regWritePort.data.inject(LogicValue.ofInt(0x8000000000000010, 64));
        storage.loadMemString(memString);
      });
      Simulator.setMaxSimTime(400000);
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
          expect(cause.isValid, isTrue, reason: 'trapCause invalid');
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

      expect(
        sawFetchFault,
        isTrue,
        reason: 'icache did not deliver the fetch fault (hung on the refill)',
      );
    },
  );
}
