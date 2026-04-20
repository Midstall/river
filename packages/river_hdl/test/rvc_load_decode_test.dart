import 'dart:async';

import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

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
    'c.ld prime-register register-relative load (creek microcode)',
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
      //   0:  auipc ra, 0x0       ra = 0            0x00000097
      //   4:  jalr  ra, 16(ra)    tgt=0x10, ra=0x8  0x010080e7
      //   8:  addi  x5, x0, 0xAA  SENTINEL (return) 0x0aa00293
      //   c:  nop (halt here)                       0x00000013
      //   10: addi  x6, x0, 0xBB  subroutine body   0x0bb00313
      //   14: c.ret (c.jr ra)     -> ra = 0x8       0x8082 (+ c.nop pad)
      // Program (RV64), reset vector 0. Exercises c.ld (register-relative,
      // PRIME registers x8-x15, cldsd imm) which c.ldsp does not cover.
      //   0:  addi s0, x0, 0x300   s0(x8)=0x300       0x30000413
      //   4:  addi s2, x0, 0x55    s2(x18)=0x55       0x05500913
      //   8:  sd   s2, 16(s0)      mem[0x310]=0x55    0x01243823
      //   c:  c.ld s1, 16(s0)      s1(x9)=mem[0x310]  0x6804 (+ c.nop pad)
      //   10: j .  (halt)                             0x0000006f
      final program = <int>[
        0x30000413,
        0x05500913,
        0x01243823,
        0x00016804,
        0x0000006f,
      ];
      ;

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

      const haltPc = 0x10;
      var reached = false;
      var lastPc = -1;
      for (var i = 0; i < 1200; i++) {
        await clk.nextPosedge;
        final p = core.pipeline.nextPc.value;
        lastPc = p.isValid ? p.toInt() : -1;
        if (p.isValid && p.toInt() == haltPc) {
          reached = true;
          break;
        }
      }

      final s1 = core.regs.getData(LogicValue.ofInt(Register.x9.value, 5));
      final stored = storage.getData(LogicValue.ofInt(0x310, xlen));

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      expect(reached, isTrue, reason: 'never reached halt');
      expect(stored?.toInt(), 0x55, reason: 'sd to s0+16 did not land');
      expect(
        s1!.toInt(),
        0x55,
        reason: 'c.ld s1,16(s0) loaded wrong value (prime reg or imm)',
      );
    },
    timeout: Timeout(Duration(minutes: 5)),
  );
}
