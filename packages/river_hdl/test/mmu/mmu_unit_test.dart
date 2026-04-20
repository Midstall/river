import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Standalone exercise of the RiverMmu page-table walk against a mock combinational
/// Wishbone slave. Prints the bus transaction sequence so the walk FSM can be
/// inspected cycle-by-cycle.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('Sv39 walk drives the expected PTE fetch sequence', () async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final dportEn = Logic(name: 'dportEn');
    final dportAddr = Logic(name: 'dportAddr', width: 64);
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);

    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );
    final mmuConfig = HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    );

    // Source signals the MMU consumes (driven below from the mock slave).
    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);

    final mmu = RiverMmu(
      clk,
      reset,
      Const(0), // ifetchEn
      Const(0, width: 64), // ifetchAddr
      dportEn,
      dportAddr,
      Const(0), // dportWe
      Const(0, width: 64), // dportWdata
      Const(3, width: 3), // dportSize = 8 bytes
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig,
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
    );

    await mmu.build();

    // Mock combinational memory: returns the PTE/value at the requested address.
    Logic memData(Logic a) => mux(
      a.eq(0x10000),
      Const(0x4401, width: 64),
      mux(
        a.eq(0x11000),
        Const(0x4801, width: 64),
        mux(
          a.eq(0x12100),
          Const(0xC00F, width: 64),
          mux(a.eq(0x30000), Const(0xCAFEF00D, width: 64), Const(0, width: 64)),
        ),
      ),
    );
    misoSrc <= memData(mmu.wbAdr);

    // Single-cycle ACK pulse, like the core_harness slave.
    final ackReg = Logic(name: 'ackReg');
    Sequential(clk, [
      If(
        reset,
        then: [ackReg < 0],
        orElse: [
          If(
            mmu.wbCyc & mmu.wbStb & ~ackReg,
            then: [ackReg < 1],
            orElse: [ackReg < 0],
          ),
        ],
      ),
    ]);
    ackSrc <= ackReg;

    reset.inject(1);
    dportEn.inject(0);
    dportAddr.inject(0);
    satpMode.inject(8); // Sv39
    satpRoot.inject(0x10); // root PPN -> 0x10000

    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Issue the dport access to virtual 0x20000.
    dportEn.inject(1);
    dportAddr.inject(0x20000);

    var done = false;
    var rdata = 0;
    for (var i = 0; i < 40; i++) {
      await clk.nextPosedge;
      final cyc = mmu.wbCyc.value.toInt();
      final stb = mmu.wbStb.value.toInt();
      final we = mmu.wbWe.value.toInt();
      final adr = mmu.wbAdr.value;
      final ack = ackSrc.value.toInt();
      final dpDone = mmu.dportDone.value.toInt();
      final dpData = mmu.dportRdata.value;
      print(
        'cyc$i: CYC=$cyc STB=$stb WE=$we '
        'ADR=0x${adr.isValid ? adr.toInt().toRadixString(16) : "x"} '
        'ACK=$ack dportDone=$dpDone '
        'dportRdata=0x${dpData.isValid ? dpData.toInt().toRadixString(16) : "x"}',
      );
      if (dpDone == 1) {
        done = true;
        rdata = dpData.toInt();
        break;
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;

    expect(done, isTrue, reason: 'dportDone never asserted');
    expect(rdata, 0xCAFEF00D);
  });

  test(
    'bare-mode sub-word load returns the addressed byte lane (offset 5)',
    () async {
      // A byte load from a non-zero offset issues an aligned bus read; the
      // addressed byte comes back in its lane and must be shifted down to lane 0
      // so the core's low-byte slice is correct. Regression for the THRE-poll
      // wedge: lbu of the ns16550a LSR at offset 5 read lane 0 (0x00) instead of
      // the real status byte, so the boot banner never streamed.
      final clk = SimpleClockGenerator(20).clk;
      final reset = Logic(name: 'reset');
      final dportEn = Logic(name: 'dportEn');
      final dportAddr = Logic(name: 'dportAddr', width: 64);

      final wbConfig = WishboneConfig(
        addressWidth: 64,
        dataWidth: 64,
        selWidth: 8,
      );
      final mmuConfig = HarborMmuConfig(
        mxlen: RiscVMxlen.rv64,
        pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
        hasSupervisorUserMemory: true,
        hasMakeExecutableReadable: true,
      );

      final ackSrc = Logic(name: 'ackSrc');
      final misoSrc = Logic(name: 'misoSrc', width: 64);

      final mmu = RiverMmu(
        clk,
        reset,
        Const(0), // ifetchEn
        Const(0, width: 64), // ifetchAddr
        dportEn,
        dportAddr,
        Const(0), // dportWe (read)
        Const(0, width: 64), // dportWdata
        Const(0, width: 3), // dportSize = 1 byte
        ackSrc,
        misoSrc,
        mmuConfig: mmuConfig,
        busConfig: wbConfig,
        satpMode: Logic(name: 'satpMode', width: 4)..gets(Const(0, width: 4)),
        satpRoot: Const(0, width: 64),
      );

      await mmu.build();

      // Aligned word at 0x10000000 holds distinct bytes per lane; byte 5 = 0x66.
      misoSrc <=
          mux(
            mmu.wbAdr.eq(0x10000000),
            Const(0x8877665544332211, width: 64),
            Const(0, width: 64),
          );

      final ackReg = Logic(name: 'ackReg');
      Sequential(clk, [
        If(
          reset,
          then: [ackReg < 0],
          orElse: [
            If(
              mmu.wbCyc & mmu.wbStb & ~ackReg,
              then: [ackReg < 1],
              orElse: [ackReg < 0],
            ),
          ],
        ),
      ]);
      ackSrc <= ackReg;

      reset.inject(1);
      dportEn.inject(0);
      dportAddr.inject(0);
      Simulator.setMaxSimTime(10000);
      unawaited(Simulator.run());

      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      dportEn.inject(1);
      dportAddr.inject(0x10000005); // byte offset 5 within the word

      var done = false;
      var rdata = 0;
      for (var i = 0; i < 40; i++) {
        await clk.nextPosedge;
        if (mmu.dportDone.value.toInt() == 1) {
          done = true;
          rdata = mmu.dportRdata.value.toInt();
          break;
        }
      }

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      expect(done, isTrue, reason: 'dportDone never asserted');
      // The core slices the low byte for lbu, so byte 5 (0x66) must be in lane 0.
      expect(
        rdata & 0xff,
        0x66,
        reason: 'lane shift wrong: 0x${rdata.toRadixString(16)}',
      );
    },
  );

  test('Sv39 walk issues a translated store after the walk', () async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final dportEn = Logic(name: 'dportEn');
    final dportAddr = Logic(name: 'dportAddr', width: 64);
    final dportWe = Logic(name: 'dportWe');
    final dportWdata = Logic(name: 'dportWdata', width: 64);
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);

    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );
    final mmuConfig = HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    );

    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);

    final mmu = RiverMmu(
      clk,
      reset,
      Const(0),
      Const(0, width: 64),
      dportEn,
      dportAddr,
      dportWe,
      dportWdata,
      Const(3, width: 3),
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig,
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
    );

    await mmu.build();

    Logic memData(Logic a) => mux(
      a.eq(0x10000),
      Const(0x4401, width: 64),
      mux(
        a.eq(0x11000),
        Const(0x4801, width: 64),
        mux(a.eq(0x12100), Const(0xC00F, width: 64), Const(0, width: 64)),
      ),
    );
    misoSrc <= memData(mmu.wbAdr);

    final ackReg = Logic(name: 'ackReg');
    Sequential(clk, [
      If(
        reset,
        then: [ackReg < 0],
        orElse: [
          If(
            mmu.wbCyc & mmu.wbStb & ~ackReg,
            then: [ackReg < 1],
            orElse: [ackReg < 0],
          ),
        ],
      ),
    ]);
    ackSrc <= ackReg;

    reset.inject(1);
    dportEn.inject(0);
    dportAddr.inject(0);
    dportWe.inject(0);
    dportWdata.inject(0);
    satpMode.inject(8);
    satpRoot.inject(0x10);

    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Issue a store to virtual 0x20000.
    dportEn.inject(1);
    dportWe.inject(1);
    dportAddr.inject(0x20000);
    dportWdata.inject(0xABCD1234);

    var sawWrite = false;
    var writeAddr = 0;
    var writeData = 0;
    var done = false;
    for (var i = 0; i < 40; i++) {
      await clk.nextPosedge;
      final cyc = mmu.wbCyc.value.toInt();
      final stb = mmu.wbStb.value.toInt();
      final we = mmu.wbWe.value.toInt();
      final adr = mmu.wbAdr.value;
      final mosi = mmu.wbDatMosi.value;
      if (cyc == 1 && stb == 1 && we == 1) {
        sawWrite = true;
        writeAddr = adr.toInt();
        writeData = mosi.toInt();
      }
      if (mmu.dportDone.value.toInt() == 1) {
        done = true;
        break;
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;

    expect(done, isTrue, reason: 'dportDone never asserted for store');
    expect(sawWrite, isTrue, reason: 'no write transaction issued');
    expect(writeAddr, 0x30000, reason: 'store went to wrong physical address');
    expect(writeData, 0xABCD1234);
  });

  // Walk fault: an invalid leaf PTE (V=0) must raise dportFault with
  // dportDone & ~dportValid, and must NOT issue the translated access.
  test('Sv39 walk faults on an invalid (V=0) leaf PTE', () async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final dportEn = Logic(name: 'dportEn');
    final dportAddr = Logic(name: 'dportAddr', width: 64);
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);

    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );
    final mmuConfig = HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
      hasSupervisorUserMemory: true,
      hasMakeExecutableReadable: true,
    );

    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);

    final mmu = RiverMmu(
      clk,
      reset,
      Const(0),
      Const(0, width: 64),
      dportEn,
      dportAddr,
      Const(0),
      Const(0, width: 64),
      Const(3, width: 3),
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig,
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
    );

    await mmu.build();

    // l0 leaf @ 0x12100 has V=0 (0xC00E) -> invalid -> fault.
    Logic memData(Logic a) => mux(
      a.eq(0x10000),
      Const(0x4401, width: 64),
      mux(
        a.eq(0x11000),
        Const(0x4801, width: 64),
        mux(
          a.eq(0x12100),
          Const(0xC00E, width: 64), // V=0
          Const(0, width: 64),
        ),
      ),
    );
    misoSrc <= memData(mmu.wbAdr);

    final ackReg = Logic(name: 'ackReg');
    Sequential(clk, [
      If(
        reset,
        then: [ackReg < 0],
        orElse: [
          If(
            mmu.wbCyc & mmu.wbStb & ~ackReg,
            then: [ackReg < 1],
            orElse: [ackReg < 0],
          ),
        ],
      ),
    ]);
    ackSrc <= ackReg;

    reset.inject(1);
    dportEn.inject(0);
    dportAddr.inject(0);
    satpMode.inject(8);
    satpRoot.inject(0x10);

    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    dportEn.inject(1);
    dportAddr.inject(0x20000);

    var faulted = false;
    var sawTranslatedAccess = false;
    for (var i = 0; i < 40; i++) {
      await clk.nextPosedge;
      final adr = mmu.wbAdr.value;
      // The translated leaf access would be to 0x30000, it must never happen.
      if (mmu.wbCyc.value.toInt() == 1 &&
          adr.isValid &&
          adr.toInt() == 0x30000) {
        sawTranslatedAccess = true;
      }
      if (mmu.dportDone.value.toInt() == 1) {
        expect(mmu.dportFault.value.toInt(), 1, reason: 'expected page fault');
        expect(mmu.dportValid.value.toInt(), 0, reason: 'fault => ~valid');
        faulted = true;
        break;
      }
    }

    await Simulator.endSimulation();
    await Simulator.simulationEnded;

    expect(faulted, isTrue, reason: 'walk never completed/faulted');
    expect(
      sawTranslatedAccess,
      isFalse,
      reason: 'must not access memory on a faulting walk',
    );
  });

  // Instruction-fetch translation (translateFetch: true). Walks the same Sv39
  // table as the dport tests but as an instruction access: the leaf needs X, the
  // result/fault route to the ifetch ports. priv = supervisor so fetch is
  // translated (M-mode would bypass).
  Future<(bool done, int rdata, bool fault)> runFetch(int leafPte) async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final ifetchEn = Logic(name: 'ifetchEn');
    final ifetchAddr = Logic(name: 'ifetchAddr', width: 64);
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);
    final priv = Logic(name: 'priv', width: 3);
    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );
    final mmuConfig = HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    );
    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);
    final mmu = RiverMmu(
      clk,
      reset,
      ifetchEn,
      ifetchAddr,
      Const(0),
      Const(0, width: 64),
      Const(0),
      Const(0, width: 64),
      Const(3, width: 3),
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig,
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
      privMode: priv,
      translateFetch: true,
    );
    await mmu.build();
    // root@0x10000 -> 0x11000, l1@0x11000 -> 0x12000, l0[32]@0x12100 = leafPte,
    // instruction word @0x30000 (PPN 0x30 from the leaf).
    Logic memData(Logic a) => mux(
      a.eq(0x10000),
      Const(0x4401, width: 64),
      mux(
        a.eq(0x11000),
        Const(0x4801, width: 64),
        mux(
          a.eq(0x12100),
          Const(leafPte, width: 64),
          mux(a.eq(0x30000), Const(0xCAFEF00D, width: 64), Const(0, width: 64)),
        ),
      ),
    );
    misoSrc <= memData(mmu.wbAdr);
    final ackReg = Logic(name: 'ackReg');
    Sequential(clk, [
      If(
        reset,
        then: [ackReg < 0],
        orElse: [
          If(
            mmu.wbCyc & mmu.wbStb & ~ackReg,
            then: [ackReg < 1],
            orElse: [ackReg < 0],
          ),
        ],
      ),
    ]);
    ackSrc <= ackReg;
    reset.inject(1);
    ifetchEn.inject(0);
    ifetchAddr.inject(0);
    satpMode.inject(8);
    satpRoot.inject(0x10);
    priv.inject(1); // supervisor
    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    ifetchEn.inject(1);
    ifetchAddr.inject(0x20000);
    var done = false, fault = false, rdata = 0;
    for (var i = 0; i < 40; i++) {
      await clk.nextPosedge;
      if (mmu.ifetchDone.value.toInt() == 1) {
        done = true;
        fault = mmu.ifetchFault.value.toInt() == 1;
        final d = mmu.ifetchRdata.value;
        rdata = d.isValid ? d.toInt() : -1;
        break;
      }
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return (done, rdata, fault);
  }

  test(
    'Sv39 fetch translation returns the instruction at the mapped PA',
    () async {
      // leaf 0xC00F = V|R|W|X -> executable.
      final (done, rdata, fault) = await runFetch(0xC00F);
      expect(done, isTrue, reason: 'ifetchDone never asserted');
      expect(fault, isFalse, reason: 'a mapped executable page must not fault');
      expect(rdata, 0xCAFEF00D);
    },
  );

  test('Sv39 fetch of a non-executable page raises ifetch_fault', () async {
    // leaf 0xC007 = V|R|W (no X) -> fetch is a page fault.
    final (done, _, fault) = await runFetch(0xC007);
    expect(done, isTrue, reason: 'a faulting fetch must still complete');
    expect(fault, isTrue, reason: 'a non-X page must raise ifetch_fault');
  });

  // Fetch-TLB: a repeated fetch of the same page hits the cache (one walk, then
  // direct reads). A tlbFlush (sfence.vma) makes the next fetch walk again.
  // Returns the number of page-table WALKS observed (root-PTE reads at 0x10000).
  Future<int> countWalks({int? flushAtCycle}) async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final ifetchEn = Logic(name: 'ifetchEn');
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);
    final priv = Logic(name: 'priv', width: 3);
    final tlbFlush = Logic(name: 'tlbFlush');
    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );
    final mmuConfig = HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    );
    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);
    final mmu = RiverMmu(
      clk,
      reset,
      ifetchEn,
      Const(0x20000, width: 64),
      Const(0),
      Const(0, width: 64),
      Const(0),
      Const(0, width: 64),
      Const(3, width: 3),
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig,
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
      privMode: priv,
      translateFetch: true,
      tlbFlush: tlbFlush,
    );
    await mmu.build();
    Logic memData(Logic a) => mux(
      a.eq(0x10000),
      Const(0x4401, width: 64),
      mux(
        a.eq(0x11000),
        Const(0x4801, width: 64),
        mux(
          a.eq(0x12100),
          Const(0xC00F, width: 64),
          mux(a.eq(0x30000), Const(0xCAFEF00D, width: 64), Const(0, width: 64)),
        ),
      ),
    );
    misoSrc <= memData(mmu.wbAdr);
    final ackReg = Logic(name: 'ackReg');
    Sequential(clk, [
      If(
        reset,
        then: [ackReg < 0],
        orElse: [
          If(
            mmu.wbCyc & mmu.wbStb & ~ackReg,
            then: [ackReg < 1],
            orElse: [ackReg < 0],
          ),
        ],
      ),
    ]);
    ackSrc <= ackReg;
    reset.inject(1);
    ifetchEn.inject(0);
    satpMode.inject(8);
    satpRoot.inject(0x10);
    priv.inject(1);
    tlbFlush.inject(0);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    ifetchEn.inject(1);
    var walks = 0;
    var prevRoot = false;
    for (var i = 0; i < 160; i++) {
      await clk.nextPosedge;
      tlbFlush.inject(i == flushAtCycle ? 1 : 0);
      final adr = mmu.wbAdr.value;
      final atRoot =
          mmu.wbStb.value.toInt() == 1 && adr.isValid && adr.toInt() == 0x10000;
      if (atRoot && !prevRoot) walks++;
      prevRoot = atRoot;
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return walks;
  }

  test('fetch-TLB: repeated same-page fetch walks once, then hits', () async {
    final walks = await countWalks();
    expect(
      walks,
      1,
      reason: 'only the first fetch should walk; rest hit the TLB',
    );
  });

  test('fetch-TLB: tlbFlush (sfence.vma) forces a re-walk', () async {
    final walks = await countWalks(flushAtCycle: 60);
    expect(walks, 2, reason: 'a flush mid-run must cause a second walk');
  });

  // Data-TLB: a repeated load of the same page hits the cache (one walk, then a
  // direct translated read). A tlbFlush (sfence.vma) forces the next load to
  // walk again. Mirrors countWalks but drives the data port.
  Future<int> countDataWalks({int? flushAtCycle}) async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final dportEn = Logic(name: 'dportEn');
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);
    final priv = Logic(name: 'priv', width: 3);
    final tlbFlush = Logic(name: 'tlbFlush');
    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );
    final mmuConfig = HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    );
    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);
    final mmu = RiverMmu(
      clk,
      reset,
      Const(0), // ifetchEn
      Const(0, width: 64), // ifetchAddr
      dportEn,
      Const(0x20000, width: 64),
      Const(0), // dportWe (load)
      Const(0, width: 64), // dportWdata
      Const(3, width: 3), // dportSize = 8 bytes
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig,
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
      privMode: priv,
      tlbFlush: tlbFlush,
    );
    await mmu.build();
    Logic memData(Logic a) => mux(
      a.eq(0x10000),
      Const(0x4401, width: 64),
      mux(
        a.eq(0x11000),
        Const(0x4801, width: 64),
        mux(
          a.eq(0x12100),
          Const(0xC00F, width: 64),
          mux(a.eq(0x30000), Const(0xCAFEF00D, width: 64), Const(0, width: 64)),
        ),
      ),
    );
    misoSrc <= memData(mmu.wbAdr);
    final ackReg = Logic(name: 'ackReg');
    Sequential(clk, [
      If(
        reset,
        then: [ackReg < 0],
        orElse: [
          If(
            mmu.wbCyc & mmu.wbStb & ~ackReg,
            then: [ackReg < 1],
            orElse: [ackReg < 0],
          ),
        ],
      ),
    ]);
    ackSrc <= ackReg;
    reset.inject(1);
    dportEn.inject(0);
    satpMode.inject(8);
    satpRoot.inject(0x10);
    priv.inject(1);
    tlbFlush.inject(0);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    dportEn.inject(1);
    var walks = 0;
    var prevRoot = false;
    for (var i = 0; i < 160; i++) {
      await clk.nextPosedge;
      tlbFlush.inject(i == flushAtCycle ? 1 : 0);
      final adr = mmu.wbAdr.value;
      final atRoot =
          mmu.wbStb.value.toInt() == 1 && adr.isValid && adr.toInt() == 0x10000;
      if (atRoot && !prevRoot) walks++;
      prevRoot = atRoot;
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return walks;
  }

  test('data-TLB: repeated same-page load walks once, then hits', () async {
    final walks = await countDataWalks();
    expect(
      walks,
      1,
      reason: 'only the first load should walk; rest hit the TLB',
    );
  });

  test('data-TLB: tlbFlush (sfence.vma) forces a re-walk', () async {
    final walks = await countDataWalks(flushAtCycle: 60);
    expect(walks, 2, reason: 'a flush mid-run must cause a second walk');
  });

  // Svadu hardware A/D update: a translated access whose leaf PTE has A=0 (or
  // D=0 on a store) writes the updated PTE back to memory before the access.
  // The leaf PTE is 0xC00F at 0x12100 (V|R|W|X, A=0, D=0). Returns the value
  // written to the leaf PTE, or null if no writeback occurred.
  Future<int?> adWriteback({required bool write}) async {
    final clk = SimpleClockGenerator(20).clk;
    final reset = Logic(name: 'reset');
    final dportEn = Logic(name: 'dportEn');
    final satpMode = Logic(name: 'satpMode', width: 4);
    final satpRoot = Logic(name: 'satpRoot', width: 64);
    final priv = Logic(name: 'priv', width: 3);
    final wbConfig = WishboneConfig(
      addressWidth: 64,
      dataWidth: 64,
      selWidth: 8,
    );
    final mmuConfig = HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    );
    final ackSrc = Logic(name: 'ackSrc');
    final misoSrc = Logic(name: 'misoSrc', width: 64);
    final mmu = RiverMmu(
      clk,
      reset,
      Const(0), // ifetchEn
      Const(0, width: 64), // ifetchAddr
      dportEn,
      Const(0x20000, width: 64),
      Const(write ? 1 : 0), // dportWe
      Const(0xDEAD, width: 64), // dportWdata
      Const(3, width: 3), // dportSize
      ackSrc,
      misoSrc,
      mmuConfig: mmuConfig,
      busConfig: wbConfig,
      satpMode: satpMode,
      satpRoot: satpRoot,
      privMode: priv,
    );
    await mmu.build();
    Logic memData(Logic a) => mux(
      a.eq(0x10000),
      Const(0x4401, width: 64),
      mux(
        a.eq(0x11000),
        Const(0x4801, width: 64),
        mux(a.eq(0x12100), Const(0xC00F, width: 64), Const(0, width: 64)),
      ),
    );
    misoSrc <= memData(mmu.wbAdr);
    final ackReg = Logic(name: 'ackReg');
    Sequential(clk, [
      If(
        reset,
        then: [ackReg < 0],
        orElse: [
          If(
            mmu.wbCyc & mmu.wbStb & ~ackReg,
            then: [ackReg < 1],
            orElse: [ackReg < 0],
          ),
        ],
      ),
    ]);
    ackSrc <= ackReg;
    reset.inject(1);
    dportEn.inject(0);
    satpMode.inject(8);
    satpRoot.inject(0x10);
    priv.inject(1);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    dportEn.inject(1);
    int? pteWrite;
    for (var i = 0; i < 120; i++) {
      await clk.nextPosedge;
      final cyc = mmu.wbCyc.value;
      final stb = mmu.wbStb.value;
      final we = mmu.wbWe.value;
      final adr = mmu.wbAdr.value;
      if (cyc.isValid &&
          cyc.toInt() == 1 &&
          stb.toInt() == 1 &&
          we.isValid &&
          we.toInt() == 1 &&
          adr.isValid &&
          adr.toInt() == 0x12100) {
        pteWrite ??= mmu.wbDatMosi.value.toInt();
      }
    }
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
    return pteWrite;
  }

  test('Svadu: a load writes the leaf PTE back with A set', () async {
    final pte = await adWriteback(write: false);
    expect(pte, isNotNull, reason: 'a load with A=0 must write the PTE back');
    expect((pte! >> 6) & 1, 1, reason: 'A (bit 6) set on access');
    expect((pte >> 7) & 1, 0, reason: 'D (bit 7) not set by a load');
  });

  test('Svadu: a store writes the leaf PTE back with A and D set', () async {
    final pte = await adWriteback(write: true);
    expect(pte, isNotNull, reason: 'a store with D=0 must write the PTE back');
    expect((pte! >> 6) & 1, 1, reason: 'A (bit 6) set on access');
    expect((pte >> 7) & 1, 1, reason: 'D (bit 7) set by a store');
  });
}
