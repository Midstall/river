import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// H1: the V (virtualization) bit transitions on MRET. With mstatus.MPV=1 and
/// MPP=S, an MRET must enter (mode=S, virt=1).
void main() {
  tearDown(() async => Simulator.reset());

  final config = RiverCoreConfig(
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvPriv, rvH],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
  );

  test(
    'MRET with MPV=1, MPP=S enters virt mode',
    timeout: Timeout(Duration(seconds: 300)),
    () async {
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic();
      final aw = config.mxlen.size;
      final wbConfig = WishboneConfig(
        addressWidth: aw,
        dataWidth: config.mxlen.size,
        selWidth: config.mxlen.size ~/ 8,
      );
      final core = RiverCore(config, busConfig: wbConfig);
      core.input('clk').srcConnection! <= clk;
      core.input('reset').srcConnection! <= reset;
      await core.build();
      final storage = SparseMemoryStorage(
        addrWidth: aw,
        dataWidth: config.mxlen.size,
        alignAddress: (a) => a,
        onInvalidRead: (a, w) => LogicValue.filled(w, LogicValue.zero),
      );
      final memRead = DataPortInterface(config.mxlen.size, aw);
      final memWrite = DataPortInterface(config.mxlen.size, aw);
      // ignore: unused_local_variable
      final mem = MemoryModel(
        clk,
        reset,
        [wrapWriteForRegisterFile(memWrite)],
        [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
        readLatency: 0,
        storage: storage,
      );
      final cyc = core.output('dataBus_CYC'),
          stb = core.output('dataBus_STB'),
          we = core.output('dataBus_WE'),
          adr = core.output('dataBus_ADR'),
          dat = core.output('dataBus_DAT_MOSI');
      memRead.en <= cyc & stb & ~we;
      memRead.addr <= adr;
      memWrite.en <= cyc & stb & we;
      memWrite.addr <= adr;
      memWrite.data <= dat;
      final ack = Logic(name: 'wbAck');
      final ready = we | memRead.valid;
      Sequential(clk, [
        If(
          reset,
          then: [ack < 0],
          orElse: [
            If(cyc & stb & ~ack & ready, then: [ack < 1], orElse: [ack < 0]),
          ],
        ),
      ]);
      core.input('dataBus_ACK').srcConnection! <= ack;
      core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

      reset.inject(1);
      Simulator.registerAction(20, () {
        reset.put(0);
        core.regWritePort.en.inject(1);
        core.regWritePort.addr.inject(LogicValue.ofInt(Register.x11.value, 5));
        // mstatus: MPP=S (1<<11) | MPV (1<<39)
        core.regWritePort.data.inject(
          LogicValue.ofInt(0x8000000800, config.mxlen.size),
        );
        // addi x10,x0,0x10 ; csrw mepc,x10 ; csrw mstatus,x11 ; mret ; @0x10 addi x12,x0,0x55
        storage.loadMemString(
          '@0\n13 05 00 01 73 10 15 34 73 90 05 30 73 00 20 30 13 06 50 05\n',
        );
      });
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      core.regWritePort.en.inject(0);
      while (reset.value.toBool()) {
        await clk.nextPosedge;
      }
      for (var i = 0; i < 5000; i++) {
        await clk.nextPosedge;
        final pc = core.pipeline.nextPc.value;
        if (pc.isValid && pc.toInt() == 0x14) break;
      }
      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      expect(core.pipeline.nextPc.value.toInt(), 0x14);
      final virt = core.output('virt').value;
      expect(virt.isValid, isTrue, reason: 'virt is X');
      expect(virt.toInt(), 1, reason: 'MRET should have entered virt mode');
      final x12 = core.regs.getData(LogicValue.ofInt(Register.x12.value, 5))!;
      expect(
        x12.toInt(),
        0x55,
        reason: 'instruction after MRET should execute',
      );
    },
  );
}
