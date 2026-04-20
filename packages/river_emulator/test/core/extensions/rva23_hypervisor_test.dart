import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// RVA23 hypervisor (H) bring-up. H is mandatory in RVA23S64 and must be fully
/// configurable: a core that omits the extension has no hypervisor CSRs and
/// traps any access to them. See project_rva23 / project_hypervisor.
void main() {
  HarborMmuConfig mmu(RiscVMxlen x, List<RiscVPagingMode> modes) =>
      HarborMmuConfig(
        mxlen: x,
        pagingModes: modes,
        tlbLevels: const [],
        pmp: HarborPmpConfig.none,
      );
  const clk = HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(10000),
  );

  RiverCore makeCore(RiverCoreConfig config) {
    final sram = Sram(
      RiverDevice(
        name: 'sram',
        compatible: 'river,sram',
        range: BusAddressRange(0, 0xFFFF),
        clockFrequency: 10000,
      ),
    );
    final core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
    core.reset();
    return core;
  }

  // csrr rd, csr  (= csrrs rd, csr, x0); csrw csr, rs1 (= csrrw x0, csr, rs1)
  int csrr(int rd, int csr) => (csr << 20) | (2 << 12) | (rd << 7) | 0x73;
  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (1 << 12) | 0x73;

  group('RVA23 hypervisor CSRs', () {
    test('H present (RVA23S64): hypervisor CSRs read/write', () async {
      final core = makeCore(
        RiverCoreConfig(
          mxlen: RiscVMxlen.rv64,
          extensions: kRva23S64Extensions,
          type: RiverCoreType.general,
          mmu: mmu(RiscVMxlen.rv64, const [RiscVPagingMode.bare]),
          interrupts: [],
          clock: clk,
        ),
      );
      expect(core.config.hasHypervisor, isTrue);

      core.xregs[Register.x5] = 0x123456789AB;
      await core.cycle(0x1000, csrw(0x680, 5)); // csrw hgatp, t0
      await core.cycle(0x1004, csrr(6, 0x680)); // csrr t1, hgatp
      expect(core.xregs[Register.x6], 0x123456789AB);

      // The full hypervisor + VS-mode CSR set is present and accessible.
      for (final csr in [0x600, 0x602, 0x604, 0x643, 0x645, 0x200, 0x280]) {
        await core.cycle(0x1008, csrr(7, csr));
      }
      // hgeip is read-only: writing it traps.
      core.xregs[Register.x5] = 1;
      expect(() => core.cycle(0x100c, csrw(0xE12, 5)), throwsA(anything));
    });

    test('HLV.W / HSV.W with both stages bare (functional)', () async {
      final core = makeCore(
        RiverCoreConfig(
          mxlen: RiscVMxlen.rv64,
          extensions: kRva23S64Extensions,
          type: RiverCoreType.general,
          mmu: mmu(RiscVMxlen.rv64, const [RiscVPagingMode.bare]),
          interrupts: [],
          clock: clk,
        ),
      );
      // vsatp/hgatp default to 0 (bare) -> two-stage translation is identity.
      await core.mmu.write(0x3000, 0x0AFE1234, 4, pageTranslate: false);
      core.xregs[Register.x6] = 0x3000;
      // hlv.w t0, (t1)  -- funct7=0x34, funct3=4
      await core.cycle(
        0x1000,
        (0x34 << 25) | (6 << 15) | (4 << 12) | (5 << 7) | 0x73,
      );
      expect(core.xregs[Register.x5], 0x0AFE1234);

      // hsv.w t2, (t1)  -- funct7=0x35
      core.xregs[Register.x6] = 0x3400;
      core.xregs[Register.x7] = 0x55667788;
      await core.cycle(
        0x1004,
        (0x35 << 25) | (7 << 20) | (6 << 15) | (4 << 12) | 0x73,
      );
      expect(await core.mmu.read(0x3400, 4, pageTranslate: false), 0x55667788);
    });

    test('HLV.W through G-stage (Sv39x4) two-stage translation', () async {
      final core = makeCore(
        RiverCoreConfig(
          mxlen: RiscVMxlen.rv64,
          extensions: kRva23S64Extensions,
          type: RiverCoreType.general,
          mmu: mmu(RiscVMxlen.rv64, const [RiscVPagingMode.bare]),
          interrupts: [],
          clock: clk,
        ),
      );
      Future<void> w(int a, int v) =>
          core.mmu.write(a, v, 8, pageTranslate: false);

      // G-stage Sv39x4 tables map guest-physical 0x8000 -> host 0x3000.
      // GVA == GPA (VS-stage bare). VPN[2]=0, VPN[1]=0, VPN[0]=8.
      const root = 0x4000; // 16 KiB-aligned x4 root
      const l1 = 0x5000;
      const l0 = 0x6000;
      const hpa = 0x3000;
      await w(
        root + 0 * 8,
        ((l1 >> 12) << 10) | 0x1,
      ); // -> L1 (valid, non-leaf)
      await w(l1 + 0 * 8, ((l0 >> 12) << 10) | 0x1); // -> L0
      // leaf: PPN(hpa), U|R|W|V (G-stage requires U)
      await w(l0 + 8 * 8, ((hpa >> 12) << 10) | 0x10 | 0x4 | 0x2 | 0x1);
      await core.mmu.write(hpa, 0x0BADF00D, 4, pageTranslate: false);

      // hgatp = Sv39x4 (mode 8) with root PPN; vsatp = bare.
      core.csrs.write(CsrAddress.hgatp.address, (8 << 60) | (root >> 12), core);

      core.xregs[Register.x6] = 0x8000; // guest virtual == guest physical
      await core.cycle(
        0x1000,
        (0x34 << 25) | (6 << 15) | (4 << 12) | (5 << 7) | 0x73,
      );
      expect(core.xregs[Register.x5], 0x0BADF00D);
    });

    test('H absent (RVA22S64): hypervisor CSR access is illegal', () {
      final core = makeCore(
        RiverCoreConfig(
          mxlen: RiscVMxlen.rv64,
          extensions: kRva22S64Extensions,
          type: RiverCoreType.general,
          mmu: mmu(RiscVMxlen.rv64, const [RiscVPagingMode.bare]),
          interrupts: [],
          clock: clk,
        ),
      );
      expect(core.config.hasHypervisor, isFalse);
      expect(
        () => core.cycle(0x1000, csrr(5, 0x600)), // hstatus -> illegal
        throwsA(anything),
      );
    });
  });
}
