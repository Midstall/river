import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Reproduces the delta HW trampoline sequence exactly: a fetch FAULTS (current
/// low PC unmapped by the just-written satp), the pipeline traps to stvec = a
/// HIGH virtual address that IS mapped (2MB L1 leaf), and the fetch there must
/// succeed. On HW River instead faults AGAIN on that valid high fetch (scause=12
/// loop). Observes pipeline.trap/trapCause directly (vector-independent) and
/// counts traps: exactly ONE instruction page fault (the intended low miss) is
/// expected, then the high target runs. A second fault = the bug.
///
///   phys 0x00 (bare until satp):
///     0x00 lui  t1, 0x80001    t1 = 0xffffffff80001000
///     0x04 addi t1, t1, 0x48   t1 = 0xffffffff80001048  (stvec target)
///     0x08 csrw stvec, t1
///     0x0c csrw satp, a0        enable Sv39 (maps ONLY high, not low PC)
///     0x10 <faults: low 0x10 unmapped> -> trap to stvec = high 0x..1048
///   phys 0x201048 (= virt 0xffffffff80001048 via 2MB L1 leaf):
///     addi x6, x0, 0x11
///     jal  x0, 0
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'trampoline: fault -> trap to mapped high 2MB-leaf fetch succeeds',
    timeout: Timeout(Duration(minutes: 6)),
    () async {
      final config = RiverCoreConfigV1.full(
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

      // M-mode setup: delegate instruction page fault (medeleg bit 12) to S-mode,
      // set stvec = high target, satp = a table mapping ONLY high (root[0] invalid),
      // then mret into S-mode at low 0x100. The S-mode fetch of 0x100 faults ->
      // delegated -> stvec = high 2MB-leaf address -> must fetch/execute there.
      //   0x00 lui  a1,0x1        ; 0x04 csrw medeleg,a1  (=0x1000, bit12)
      //   0x08 lui  a2,0x80001    ; 0x0c addi a2,a2,0x48   (a2=0xffffffff80001048)
      //   0x10 csrw stvec,a2      ; 0x14 csrw satp,a0
      //   0x18 addi a3,x0,0x100   ; 0x1c csrw mepc,a3
      //   0x20 lui  a4,0x1        ; 0x24 srli a4,a4,1 (=0x800 MPP=S)
      //   0x28 csrw mstatus,a4    ; 0x2c mret -> S-mode @0x100 (faults)
      const memString = '''@0
b7 15 00 00 73 90 25 30 37 16 00 80 13 06 86 04 73 10 56 10 73 10 05 18 93 06 00 10 73 90 16 34 37 17 00 00 13 57 17 00 73 10 07 30 73 00 20 30
@10ff0
01 44 00 00 00 00 00 00
@11000
ef 00 08 00 00 00 00 00
@201048
13 03 10 01 6f 00 00 00
''';

      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic();
      final aw = config.mxlen.size;
      final wb = WishboneConfig(
        addressWidth: aw,
        dataWidth: aw,
        selWidth: aw ~/ 8,
      );
      final core = RiverCore(config, busConfig: wb);
      core.input('clk').srcConnection! <= clk;
      core.input('reset').srcConnection! <= reset;
      await core.build();

      final storage = SparseMemoryStorage(
        addrWidth: aw,
        dataWidth: aw,
        alignAddress: (a) => a,
        onInvalidRead: (a, w) => LogicValue.filled(w, LogicValue.zero),
      );
      final memRead = DataPortInterface(aw, aw);
      final memWrite = DataPortInterface(aw, aw);
      // ignore: unused_local_variable
      final mem = MemoryModel(
        clk,
        reset,
        [wrapWriteForRegisterFile(memWrite)],
        [wrapReadForRegisterFile(memRead, clk: clk, readLatency: 0)],
        readLatency: 0,
        storage: storage,
      );
      final cyc = core.output('dataBus_CYC');
      final stb = core.output('dataBus_STB');
      final we = core.output('dataBus_WE');
      final adr = core.output('dataBus_ADR');
      final mosi = core.output('dataBus_DAT_MOSI');
      memRead.en <= cyc & stb & ~we;
      memRead.addr <= adr;
      memWrite.en <= cyc & stb & we;
      memWrite.addr <= adr;
      memWrite.data <= mosi;
      final ack = Logic();
      Sequential(clk, [
        If(
          reset,
          then: [ack < 0],
          orElse: [
            If(
              cyc & stb & ~ack & (we | memRead.valid),
              then: [ack < 1],
              orElse: [ack < 0],
            ),
          ],
        ),
      ]);
      core.input('dataBus_ACK').srcConnection! <= ack;
      core.input('dataBus_DAT_MISO').srcConnection! <= memRead.data;

      reset.inject(1);
      Simulator.registerAction(20, () {
        reset.put(0);
        core.regWritePort.en.inject(1);
        core.regWritePort.addr.inject(LogicValue.ofInt(10, 5)); // a0
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

      var faults = 0;
      var reachedHigh = false;
      var lastPc = 0;
      final trail = <String>[];
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        final trap = core.pipeline.trap.value;
        if (trap.isValid && trap.toInt() == 1) {
          final cause = core.pipeline.trapCause.value;
          if (cause.isValid &&
              cause.toInt() == Trap.instructionPageFault.causeCode) {
            faults++;
          }
        }
        final npc = core.pipeline.nextPc.value;
        if (npc.isValid) {
          lastPc = npc.toInt();
          final s = '0x${lastPc.toRadixString(16)}';
          if (trail.isEmpty || trail.last != s) trail.add(s);
          if (lastPc == 0xffffffff8000104c) {
            reachedHigh = true;
            break;
          }
        }
      }
      expect(
        faults,
        greaterThan(0),
        reason:
            'the intended low-page trampoline miss should fault at least once',
      );
      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      // Exactly one fault (the intended low miss). The high fetch must NOT fault.
      expect(
        reachedHigh,
        isTrue,
        reason:
            'never reached the high park; faults=$faults '
            'lastPc=0x${lastPc.toRadixString(16)} (River faulted on the valid '
            'high 2MB-leaf fetch = the bug)',
      );
      final x6 = core.regs.getData(LogicValue.ofInt(6, 5))!.toInt();
      expect(x6, 0x11, reason: 'high target did not execute');
    },
  );
}
