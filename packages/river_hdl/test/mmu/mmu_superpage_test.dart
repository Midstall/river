import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Superpage (megapage) translation regression.
///
/// The MMU must compose the physical address from the leaf LEVEL, not always
/// as a 4KB page. A level-1 leaf is a 2MB superpage, so the low bits
/// `vaddr[20:12]` come from the virtual address, not the PTE. The original
/// `leafPa` always took `vaddr[11:0]`, so every 4KB sub-page of a superpage
/// aliased to the superpage base. Linux `swapper_pg_dir` maps the kernel text
/// as a 2MB superpage, so the first instruction fetch under swapper landed
/// 0x1000 bytes low and read a wrong (illegal-decoding) word on delta.
///
/// vaddr 0x201000 is 4KB into the 2MB superpage at guest 0x200000. With the
/// level-1 leaf PPN 0x40000, the correct physical is 0x40001000 (keeps the
/// vaddr[20:12] = 1 offset); the 4KB-only bug computes 0x40000000.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<int> walkAndRead(int vaddr) async {
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
      Const(0), // ifetchEn
      Const(0, width: 64), // ifetchAddr
      dportEn,
      dportAddr,
      Const(0), // dportWe (read)
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

    // Mock combinational memory:
    //   root[0]  @ 0x10000 -> non-leaf PTE, next table 0x11000
    //   L1[1]    @ 0x11008 -> LEAF (2MB superpage), PPN 0x40000, V|R|W|X
    //   0x40001000 -> correct data (superpage sub-page offset kept)
    //   0x40000000 -> wrong data (what the 4KB-only bug reads)
    Logic memData(Logic a) => mux(
      a.eq(0x10000),
      Const(0x4401, width: 64),
      mux(
        a.eq(0x11008),
        Const(0x1000000F, width: 64),
        mux(
          a.eq(0x40001000),
          Const(0xCAFEF00D, width: 64),
          mux(
            a.eq(0x40000000),
            Const(0xDEADBEEF, width: 64),
            Const(0, width: 64),
          ),
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
    satpMode.inject(8); // Sv39
    satpRoot.inject(0x10); // root PPN -> 0x10000

    Simulator.setMaxSimTime(10000);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    dportEn.inject(1);
    dportAddr.inject(vaddr);

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
    return rdata;
  }

  test(
    'Sv39 level-1 superpage keeps vaddr[20:12] in the physical address',
    () async {
      // 4KB into the 2MB superpage -> must read 0x40001000, not the base.
      final rdata = await walkAndRead(0x201000);
      expect(
        rdata,
        0xCAFEF00D,
        reason: 'superpage sub-page offset dropped (read the base instead)',
      );
    },
  );

  test('Sv39 level-1 superpage base sub-page still translates', () async {
    // Offset 0 within the superpage -> base physical 0x40000000.
    await Simulator.reset();
    final rdata = await walkAndRead(0x200000);
    expect(rdata, 0xDEADBEEF);
  });
}
