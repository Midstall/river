import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// H4: VS-mode (virt=1) CSR virtualization in the emulator. When virt=1, a
/// supervisor CSR access redirects to the VS shadow (sstatus->vsstatus,
/// satp->vsatp, ...) and a VS access to an HS-only hypervisor CSR raises a
/// virtual-instruction exception (cause 22). Mirrors the HDL core_vsmode_csr_test
/// / core_vsmode_virtinst_test. See project_hypervisor / project_rva23.
void main() {
  RiverCore makeCore() {
    final sram = Sram(
      RiverDevice(
        name: 'sram',
        compatible: 'river,sram',
        range: BusAddressRange(0, 0xFFFF),
        clockFrequency: 10000,
      ),
    );
    final core = RiverCore(
      RiverCoreConfig(
        mxlen: RiscVMxlen.rv64,
        extensions: kRva23S64Extensions,
        type: RiverCoreType.general,
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        interrupts: [],
        clock: const HarborClockConfig(
          name: 'test',
          rate: HarborFixedClockRate(10000),
        ),
      ),
      memDevices: Map.fromEntries([sram.mem!]),
    );
    core.reset();
    return core;
  }

  int csrr(int rd, int csr) => (csr << 20) | (2 << 12) | (rd << 7) | 0x73;
  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (1 << 12) | 0x73;

  const satp = 0x180, vsatp = 0x280, hstatus = 0x600;

  test('VS-mode csrw satp lands in vsatp; csrr satp reads it back', () async {
    final core = makeCore();
    core.mode = PrivilegeMode.supervisor;
    core.virt = true;

    core.xregs[Register.x5] = 0x8000000000012345;
    await core.cycle(0x1000, csrw(satp, 5)); // VS: writes vsatp, not satp

    expect(
      core.csrs.read(vsatp, core),
      0x8000000000012345,
      reason: 'redirected write landed in vsatp',
    );
    expect(core.csrs.read(satp, core), 0, reason: 'real satp untouched');

    core.mode = PrivilegeMode.supervisor;
    core.virt = true;
    await core.cycle(0x1004, csrr(6, satp)); // VS: reads vsatp via redirect
    expect(core.xregs[Register.x6], 0x8000000000012345);
  });

  test(
    'VS-mode access to an HS hypervisor CSR -> virtual instruction (22)',
    () async {
      final core = makeCore();
      // Valid (non-zero) mtvec so the trap doesn't double-fault on a 0 handler.
      core.xregs[Register.x9] = 0x100;
      await core.cycle(0x0FF0, csrw(0x305, 9)); // (M-mode) csrw mtvec, x9
      core.mode = PrivilegeMode.supervisor;
      core.virt = true;

      await core.cycle(
        0x2000,
        csrr(7, hstatus),
      ); // VS: read hstatus -> cause 22

      expect(
        core.csrs.read(0x342, core) & 0x7FFFFFFFFFFFFFFF,
        22,
        reason: 'mcause = virtual instruction (22)',
      );
    },
  );

  test(
    'VS trap delegated by medeleg+hedeleg lands at vstvec, virt stays 1',
    () async {
      final core = makeCore();
      // From M-mode: delegate cause 8 (ecall-from-U) M->HS (medeleg) and HS->VS
      // (hedeleg); give vstvec and stvec distinct addresses.
      core.xregs[Register.x1] = 1 << 8;
      await core.cycle(0x10, csrw(0x302, 1)); // medeleg[8]=1
      await core.cycle(0x14, csrw(0x602, 1)); // hedeleg[8]=1
      core.xregs[Register.x2] = 0x300;
      await core.cycle(0x18, csrw(0x205, 2)); // vstvec = 0x300
      core.xregs[Register.x3] = 0x200;
      await core.cycle(0x1C, csrw(0x105, 3)); // stvec  = 0x200

      // Enter VU-mode (user + virt) and ecall.
      core.mode = PrivilegeMode.user;
      core.virt = true;
      final nextPc = await core.cycle(0x2000, 0x00000073); // ecall

      expect(
        core.csrs.read(0x242, core) & 0x7FFFFFFFFFFFFFFF,
        8,
        reason: 'vscause = 8 (ecall delegated to VS)',
      );
      expect(core.mode, PrivilegeMode.supervisor, reason: 'VS runs at S priv');
      expect(core.virt, isTrue, reason: 'trap stays virtualized');
      expect(nextPc, 0x300, reason: 'vectored to vstvec, not stvec (0x200)');
    },
  );

  test('G-stage walk fault reports a guest page-fault cause (21)', () async {
    final core = makeCore();
    Future<void> w(int a, int v) =>
        core.mmu.write(a, v, 8, pageTranslate: false);
    // Sv39x4 G-stage tables for guest-physical 0x8000, but the leaf is U=0 - a
    // G-stage leaf must be user-accessible, so the walk faults in the G-stage.
    const root = 0x4000, l1 = 0x5000, l0 = 0x6000, hpa = 0x3000;
    await w(root, ((l1 >> 12) << 10) | 0x1);
    await w(l1, ((l0 >> 12) << 10) | 0x1);
    await w(l0 + 8 * 8, ((hpa >> 12) << 10) | 0x4 | 0x2 | 0x1); // R|W|V, NO U
    core.csrs.write(CsrAddress.hgatp.address, (8 << 60) | (root >> 12), core);
    core.csrs.write(CsrAddress.mtvec.address, 0x100, core); // valid handler

    core.xregs[Register.x6] = 0x8000;
    // hlv.w x5, (x6): funct7=0x34, funct3=4 -> faults in the G-stage (U=0).
    await core.cycle(
      0x1000,
      (0x34 << 25) | (6 << 15) | (4 << 12) | (5 << 7) | 0x73,
    );

    expect(
      core.csrs.read(CsrAddress.mcause.address, core) & 0x7FFFFFFFFFFFFFFF,
      21,
      reason: 'G-stage fault -> loadGuestPageFault (21), not 13',
    );
  });
}
