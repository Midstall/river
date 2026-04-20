import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// RVA22S64 supervisor verification: Sv39 paging (3-level walk) and the
/// Svnapot NAPOT page-attribute bit. See project_rva22 in memory.
void main() {
  group('RVA22 S-mode Sv39', () {
    late Sram sram;
    late Mmu mmu;

    // Page tables live inside SRAM; map virtual pages identity to a physical
    // address that is also within SRAM so reads/writes resolve.
    const l2Base = 0x10000;
    const l1Base = 0x11000;
    const l0Base = 0x12000;

    setUp(() {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFFFF),
          clockFrequency: 10000,
        ),
      );
      mmu = Mmu(
        HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
          hasSupervisorUserMemory: true,
          hasMakeExecutableReadable: true,
        ),
        Map.fromEntries([sram.mem!]),
      );
      mmu.configure(8, l2Base >> 12); // Sv39
    });

    void writeDword(int addr, int value) {
      for (var i = 0; i < 8; i++) {
        sram.data[addr + i] = (value >> (i * 8)) & 0xFF;
      }
    }

    // Identity-map the 4 KiB page containing [vaddr]. napot sets PTE bit 63.
    void mapPage(
      int vaddr, {
      bool r = true,
      bool w = true,
      bool x = true,
      bool u = false,
      bool napot = false,
    }) {
      final vpn2 = (vaddr >> 30) & 0x1FF;
      final vpn1 = (vaddr >> 21) & 0x1FF;
      final vpn0 = (vaddr >> 12) & 0x1FF;
      final physPage = vaddr >> 12;
      writeDword(l2Base + vpn2 * 8, ((l1Base >> 12) << 10) | 0x1); // non-leaf
      writeDword(l1Base + vpn1 * 8, ((l0Base >> 12) << 10) | 0x1); // non-leaf
      var flags = 0x1;
      if (r) flags |= 0x2;
      if (w) flags |= 0x4;
      if (x) flags |= 0x8;
      if (u) flags |= 0x10;
      var pte = (physPage << 10) | flags;
      if (napot) pte |= 1 << 63;
      writeDword(l0Base + vpn0 * 8, pte);
    }

    test('translates a leaf page (3-level walk)', () async {
      mapPage(0x20000);
      final phys = await mmu.translate(
        0x20000,
        MemoryAccess.read,
        privilege: PrivilegeMode.supervisor,
      );
      expect(phys, 0x20000);
    });

    test('load page fault for unmapped address', () async {
      expect(
        () => mmu.translate(
          0x40000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
        ),
        throwsA(isA<TrapException>()),
      );
    });

    test('store page fault for read-only page', () async {
      mapPage(0x20000, w: false);
      expect(
        () => mmu.translate(
          0x20000,
          MemoryAccess.write,
          privilege: PrivilegeMode.supervisor,
        ),
        throwsA(isA<TrapException>()),
      );
    });

    test('Svnapot: PTE with N bit still translates', () async {
      mapPage(0x20000, napot: true);
      final phys = await mmu.translate(
        0x20000,
        MemoryAccess.read,
        privilege: PrivilegeMode.supervisor,
      );
      expect(phys, 0x20000);
    });
  });

  group('RVA22 S-mode privilege', () {
    late Sram sram;
    late RiverCore core;
    final config = RiverCoreConfig(
      mxlen: RiscVMxlen.rv64,
      extensions: kRva22S64Extensions,
      type: RiverCoreType.general,
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
        rate: HarborFixedClockRate(10000),
      ),
    );

    setUp(() {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: 10000,
        ),
      );
      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
      core.reset();
    });

    test('SRET returns to supervisor via sepc', () async {
      core.csrs.write(CsrAddress.stvec.address, 0x80000000, core);
      core.csrs.write(CsrAddress.sepc.address, 0x300, core);
      var sstatus = core.csrs.read(CsrAddress.sstatus.address, core);
      sstatus |= 1 << 8; // SPP = supervisor
      core.csrs.write(CsrAddress.sstatus.address, sstatus, core);
      core.mode = PrivilegeMode.supervisor;
      final nextPc = await core.cycle(0x1000, 0x10200073); // sret
      expect(nextPc, 0x300);
      expect(core.mode, PrivilegeMode.supervisor);
    });

    test('ecall from U-mode is delegated to S-mode', () async {
      core.csrs.write(CsrAddress.stvec.address, 0x80000000, core);
      core.csrs.write(CsrAddress.mtvec.address, 0x40000000, core);
      core.csrs.write(CsrAddress.medeleg.address, 1 << 8, core); // ecall-from-U
      core.mode = PrivilegeMode.user;
      final nextPc = await core.cycle(0x1000, 0x00000073); // ecall
      expect(nextPc, 0x80000000); // S-mode handler, not mtvec
      expect(core.mode, PrivilegeMode.supervisor);
    });

    test('Svinval sinval.vma executes', () async {
      core.mode = PrivilegeMode.supervisor;
      expect(await core.cycle(0x1000, 0x16628073), 0x1004);
    });

    test('Svinval sfence.w.inval / sfence.inval.ir execute', () async {
      core.mode = PrivilegeMode.supervisor;
      expect(await core.cycle(0x1000, 0x18000073), 0x1004);
      expect(await core.cycle(0x1000, 0x18100073), 0x1004);
    });
  });
}
