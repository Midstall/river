import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Diagnostic: run the paged-superpage straight-line program and PRINT the PC
/// trajectory so we can see where the fetch goes wrong.
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

  String mem(Map<int, List<int>> words) {
    final sb = StringBuffer();
    final addrs = words.keys.toList()..sort();
    for (final a in addrs) {
      sb.writeln('@${a.toRadixString(16)}');
      for (final w in words[a]!) {
        for (var i = 0; i < 4; i++) {
          sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    return sb.toString();
  }

  test(
    'DIAG paged superpage pc trajectory',
    timeout: Timeout(Duration(minutes: 5)),
    () async {
      final config = full();
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic();
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
      final m = MemoryModel(
        clk,
        reset,
        [wrapWriteForRegisterFile(memWrite)],
        [wrapReadForRegisterFile(memRead)],
        storage: storage,
      );
      final wbCyc = core.output('dataBus_CYC');
      final wbStb = core.output('dataBus_STB');
      final wbWe = core.output('dataBus_WE');
      final wbAdr = core.output('dataBus_ADR');
      memRead.en <= wbCyc & wbStb & ~wbWe;
      memRead.addr <= wbAdr;
      memWrite.en <= wbCyc & wbStb & wbWe;
      memWrite.addr <= wbAdr;
      memWrite.data <= core.output('dataBus_DAT_MOSI');
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

      final prog = mem({
        0x00: [0x18051073, 0x7FD0006F],
        0x1000: [
          0x01100313, // addi x6,x0,0x11
          0x00000097, // auipc ra,0
          0x014080e7, // jalr ra,20(ra) -> 0x1018
          0x00000517, // auipc a0,0   RETURN TARGET @0x100c
          0x0000006f, // jal x0,0  park @0x1010
          0x00000013, // nop
          0x00008067, // jalr x0,0(ra) ret -> 0x100c  @0x1018
        ],
        0x10000: [0x00004401, 0x0],
        0x11000: [0x0000000F, 0x0],
      });

      reset.inject(1);
      seedGate.inject(1);
      prfSeedMode.inject(1);
      Simulator.registerAction(20, () {
        reset.put(0);
        storage.loadMemString(prog);
      });
      Simulator.setMaxSimTime(4000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      // seed satp into a0 (x10)
      core.regWritePort.en.inject(1);
      core.regWritePort.addr.inject(LogicValue.ofInt(10, 5));
      core.regWritePort.data.inject(
        LogicValue.ofInt(0x8000000000000010, config.mxlen.size),
      );
      await clk.nextPosedge;
      core.regWritePort.en.inject(0);
      seedGate.inject(0);
      prfSeedMode.inject(0);
      while (reset.value.toBool()) {
        await clk.nextPosedge;
      }

      final seen = <int>[];
      int? last;
      for (var i = 0; i < 1500; i++) {
        await clk.nextPosedge;
        final pcv = core.pipeline.nextPc.value;
        if (pcv.isValid) {
          final pc = pcv.toInt();
          if (pc != last) {
            seen.add(pc);
            last = pc;
          }
        }
      }
      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      // Print the distinct PC sequence (first 60 transitions).
      final trace = seen
          .take(60)
          .map((p) => '0x${p.toRadixString(16)}')
          .join(' ');
      print('PC TRAJECTORY: $trace');
      print(
        'final pc: 0x${seen.isNotEmpty ? seen.last.toRadixString(16) : "?"}',
      );
    },
  );
}
