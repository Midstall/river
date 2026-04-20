import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

void writeWord(Sram sram, int addr, int value) {
  for (int i = 0; i < 4; i++) {
    sram.data[addr + i] = (value >> (i * 8)) & 0xFF;
  }
}

int readWord(Sram sram, int addr) {
  int v = 0;
  for (int i = 0; i < 4; i++) {
    v |= sram.data[addr + i] << (i * 8);
  }
  return v;
}

void main() {
  group('MMU', () {
    late Sram sram;
    late Mmu mmu;

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
          mxlen: RiscVMxlen.rv32,
          pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv32],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
          hasSupervisorUserMemory: true,
          hasMakeExecutableReadable: true,
        ),
        Map.fromEntries([sram.mem!]),
      );
    });

    test('bare mode passes address through', () async {
      final result = await mmu.translate(0x1000, MemoryAccess.read);
      expect(result, 0x1000);
    });

    group('Sv32', () {
      // Sv32: 2-level page table
      // PTE format: PPN[1] (12 bits) | PPN[0] (10 bits) | RSW (2 bits) | D A G U X W R V
      // VPN[1] = bits [31:22], VPN[0] = bits [21:12], offset = bits [11:0]
      const pageTableBase = 0x10000;
      const secondLevelBase = 0x11000;

      void setupIdentityPage(
        int vaddr, {
        bool r = true,
        bool w = true,
        bool x = true,
        bool u = false,
      }) {
        final vpn1 = (vaddr >> 22) & 0x3FF;
        final vpn0 = (vaddr >> 12) & 0x3FF;
        final physPage = vaddr >> 12;

        // First-level PTE points to second-level table
        final l1Pte = ((secondLevelBase >> 12) << 10) | 0x1; // V=1, not leaf
        writeWord(sram, pageTableBase + vpn1 * 4, l1Pte);

        // Second-level PTE is a leaf mapping to the same physical page
        int flags = 0x1; // V=1
        if (r) flags |= 0x2;
        if (w) flags |= 0x4;
        if (x) flags |= 0x8;
        if (u) flags |= 0x10;
        final l2Pte = (physPage << 10) | flags;
        writeWord(sram, secondLevelBase + vpn0 * 4, l2Pte);
      }

      setUp(() {
        mmu.configure(1, pageTableBase >> 12); // Sv32, ppn = pageTableBase/4096
      });

      test('translates virtual to physical with Sv32', () async {
        setupIdentityPage(0x20000);
        writeWord(sram, 0x20000, 0xDEADBEEF);

        final phys = await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
        );

        expect(phys, 0x20000);
        final val = await mmu.read(
          0x20000,
          4,
          privilege: PrivilegeMode.supervisor,
        );
        expect(val, 0xDEADBEEF);
      });

      test('throws load page fault for invalid PTE', () async {
        // Don't set up any page table entry for 0x30000
        expect(
          () => mmu.translate(
            0x30000,
            MemoryAccess.read,
            privilege: PrivilegeMode.supervisor,
          ),
          throwsA(
            isA<TrapException>().having(
              (e) => e.trap,
              'trap',
              Trap.loadPageFault,
            ),
          ),
        );
      });

      test('throws store page fault for read-only page', () async {
        setupIdentityPage(0x20000, r: true, w: false, x: false);

        expect(
          () => mmu.translate(
            0x20000,
            MemoryAccess.write,
            privilege: PrivilegeMode.supervisor,
          ),
          throwsA(
            isA<TrapException>().having(
              (e) => e.trap,
              'trap',
              Trap.storePageFault,
            ),
          ),
        );
      });

      test('throws instruction page fault for non-executable page', () async {
        setupIdentityPage(0x20000, r: true, w: true, x: false);

        expect(
          () => mmu.translate(
            0x20000,
            MemoryAccess.instr,
            privilege: PrivilegeMode.supervisor,
          ),
          throwsA(
            isA<TrapException>().having(
              (e) => e.trap,
              'trap',
              Trap.instructionPageFault,
            ),
          ),
        );
      });

      test('throws page fault for user accessing supervisor page', () async {
        setupIdentityPage(0x20000, u: false);

        expect(
          () => mmu.translate(
            0x20000,
            MemoryAccess.read,
            privilege: PrivilegeMode.user,
          ),
          throwsA(
            isA<TrapException>().having(
              (e) => e.trap,
              'trap',
              Trap.loadPageFault,
            ),
          ),
        );
      });

      test('sets Accessed bit on read', () async {
        setupIdentityPage(0x20000);
        final vpn0 = (0x20000 >> 12) & 0x3FF;
        final pteBefore = readWord(sram, secondLevelBase + vpn0 * 4);
        expect(pteBefore & (1 << 6), 0); // A bit not set

        await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
        );

        final pteAfter = readWord(sram, secondLevelBase + vpn0 * 4);
        expect(pteAfter & (1 << 6), isNot(0)); // A bit set
      });

      test('sets Dirty bit on write', () async {
        setupIdentityPage(0x20000);
        final vpn0 = (0x20000 >> 12) & 0x3FF;

        await mmu.translate(
          0x20000,
          MemoryAccess.write,
          privilege: PrivilegeMode.supervisor,
        );

        final pteAfter = readWord(sram, secondLevelBase + vpn0 * 4);
        expect(pteAfter & (1 << 6), isNot(0)); // A bit set
        expect(pteAfter & (1 << 7), isNot(0)); // D bit set
      });

      test('does not set Dirty bit on read', () async {
        setupIdentityPage(0x20000);
        final vpn0 = (0x20000 >> 12) & 0x3FF;

        await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
        );

        final pteAfter = readWord(sram, secondLevelBase + vpn0 * 4);
        expect(pteAfter & (1 << 7), 0); // D bit not set
      });

      test('TLB caches translation', () async {
        setupIdentityPage(0x20000);

        await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
        );

        expect(mmu.tlb.misses, 1);
        expect(mmu.tlb.hits, 0);

        await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
        );

        expect(mmu.tlb.hits, 1);
      });

      test('flushTlb invalidates cached entries', () async {
        setupIdentityPage(0x20000);

        await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
        );

        mmu.flushTlb();

        await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
        );

        expect(mmu.tlb.misses, 2);
      });

      test('mxr allows reading executable-only page', () async {
        setupIdentityPage(0x20000, r: false, w: false, x: true);

        await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
          mxr: true,
        );
      });

      test('supervisor cannot access user page without sum', () async {
        setupIdentityPage(0x20000, u: true);

        expect(
          () => mmu.translate(
            0x20000,
            MemoryAccess.read,
            privilege: PrivilegeMode.supervisor,
            sum: false,
          ),
          throwsA(isA<TrapException>()),
        );
      });

      test('supervisor can access user page with sum', () async {
        setupIdentityPage(0x20000, u: true);

        final phys = await mmu.translate(
          0x20000,
          MemoryAccess.read,
          privilege: PrivilegeMode.supervisor,
          sum: true,
        );

        expect(phys, 0x20000);
      });
    });
  });
}
