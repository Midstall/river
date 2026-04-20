import 'dart:async';

import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Regression for the creek (rc1-s) microcode decoder dropping the implicit
/// stack-pointer base and the RVC immediate descramble on compressed stack
/// ops. Before the fix, [DynamicInstructionDecoder] decoded fields purely by
/// instruction format type, so `c.sdsp`/`c.ldsp` (fixedRs1 = sp, immKind =
/// css/ci) came out rs1 = 0, imm = 0 and stored/loaded to address 0. This is
/// the instruction the Weir FSBL prologue hangs on. The OoO path was fine
/// because its StaticInstructionDecoder already applied compReg/immFor.
///
/// The program sets sp with real auipc+addi, stores ra through `c.sdsp`, then
/// reads it back through `c.ldsp`. Pass requires the store to land at sp+off
/// AND the load to recover it (both the fixed sp base and the scaled imm).
RiverCoreConfig _rv64() => RiverCoreConfigV1.small(
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
    rate: HarborFixedClockRate(12000000),
  ),
  resetVector: 0,
);

void main() {
  test(
    'c.sdsp/c.ldsp decode fixed sp base + scaled imm (creek microcode)',
    () async {
      await Simulator.reset();
      final config = _rv64();
      const xlen = 64;
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic(name: 'reset');
      final wbConfig = WishboneConfig(
        addressWidth: xlen,
        dataWidth: xlen,
        selWidth: xlen ~/ 8,
      );
      final core = RiverCore(config, busConfig: wbConfig);
      core.input('clk').srcConnection! <= clk;
      core.input('reset').srcConnection! <= reset;
      await core.build();

      final storage = SparseMemoryStorage(
        addrWidth: xlen,
        dataWidth: xlen,
        alignAddress: (addr) => addr,
        onInvalidRead: (addr, dataWidth) =>
            LogicValue.filled(dataWidth, LogicValue.zero),
      );
      final memRead = DataPortInterface(xlen, xlen);
      final memWrite = DataPortInterface(xlen, xlen);
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
      memRead.en <= wbCyc & wbStb & ~wbWe;
      memRead.addr <= core.output('dataBus_ADR');
      memWrite.en <= wbCyc & wbStb & wbWe;
      memWrite.addr <= core.output('dataBus_ADR');
      memWrite.data <= core.output('dataBus_DAT_MOSI');
      final wbAckReg = Logic(name: 'wbAck');
      Sequential(clk, [
        If(
          reset,
          then: [wbAckReg < 0],
          orElse: [
            If(
              wbCyc & wbStb & ~wbAckReg & (wbWe | memRead.valid),
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
      seedGate.inject(0);
      Simulator.setMaxSimTime(100000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;

      // Program (RV64), reset vector 0:
      //   0:  auipc sp, 0x0         sp = 0           0x00000117
      //   4:  addi  sp, sp, 0x200   sp = 0x200       0x20010113
      //   8:  addi  ra, x0, 0x42    ra = 0x42        0x04200093
      //   c:  c.sdsp ra, 8(sp)      store @0x208     0xe406  (low half)
      //   e:  c.ldsp x5, 8(sp)      x5 = mem[0x208]  0x62a2  (high half)
      //   10: nop (halt here)       0x00000013
      final program = <int>[
        0x00000117,
        0x20010113,
        0x04200093,
        0x62a2e406, // low = c.sdsp ra,8(sp); high = c.ldsp x5,8(sp)
        0x00000013,
      ];

      reset.inject(1);
      seedGate.inject(0);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      final sb = StringBuffer('@0\n');
      for (final w in program) {
        for (var b = 0; b < 4; b++) {
          sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      storage.loadMemString('${sb.toString().trimRight()}\n');
      reset.inject(0);
      await clk.nextPosedge;
      while (reset.value.toBool()) {
        await clk.nextPosedge;
      }

      const nextPc = 0x10;
      var reached = false;
      for (var i = 0; i < 2000; i++) {
        await clk.nextPosedge;
        final p = core.pipeline.nextPc.value;
        if (p.isValid && p.toInt() == nextPc) {
          reached = true;
          break;
        }
      }

      final stored = storage.getData(LogicValue.ofInt(0x208, xlen));
      final x5 = core.regs.getData(LogicValue.ofInt(Register.x5.value, 5));

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      expect(reached, isTrue, reason: 'never reached nextPc=0x10');
      expect(stored, isNotNull, reason: 'c.sdsp store never landed at sp+8');
      expect(
        stored!.toInt(),
        0x42,
        reason: 'c.sdsp wrote wrong value/address (fixed sp base or imm lost)',
      );
      expect(
        x5!.toInt(),
        0x42,
        reason: 'c.ldsp read back wrong value (fixed sp base or imm lost)',
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );
}
