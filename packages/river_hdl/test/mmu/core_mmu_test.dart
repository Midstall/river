import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// Sv39 page-table-walk verification for the HDL MMU. Mirrors the emulator's
/// `rva22_smode_test.dart` page-table setup: a 3-level walk that maps a virtual
/// page to a *different* physical page, proving the MMU actually translates
/// (rather than passing the address through). See project_hdl_mmu in memory.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

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

  // Page tables (identity within physical memory):
  //   l2 @ 0x10000  (satp root, PPN 0x10)
  //   l1 @ 0x11000
  //   l0 @ 0x12000
  // Maps vaddr 0x20000 -> paddr 0x30000 (a *different* page).
  //   vpn2=0, vpn1=0, vpn0=0x20  ->  l0 PTE at 0x12000 + 0x20*8 = 0x12100
  // PTEs: non-leaf = (nextPPN<<10)|V; leaf = (physPPN<<10)|V|R|W|X.
  //   l2[0]   @ 0x10000 = (0x11<<10)|1     = 0x4401
  //   l1[0]   @ 0x11000 = (0x12<<10)|1     = 0x4801
  //   l0[0x20]@ 0x12100 = (0x30<<10)|0xF   = 0xC00F
  // Diagnostic: bare (paging off) 64-bit load through the modified MMU, no walk.
  test(
    'bare ld (no paging) loads 0x30000',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      // lui a2, 0x30   (0x00030637)  -> a2 = 0x30000
      // ld  a1, 0(a2)  (0x00063583)
      // nop
      '''@0
37 06 03 00 83 35 06 00 13 00 00 00
@30000
0D F0 FE CA 00 00 00 00
''',
      {Register.x11: 0xCAFEF00D},
      config,
      nextPc: 0x0C,
    ),
  );

  test(
    'Sv39 dport load translates 0x20000 -> 0x30000',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      // satp (MODE=8 Sv39, root PPN 0x10) is preloaded into a0; enable paging,
      // then load from virtual 0x20000 (mapped to physical 0x30000).
      //   csrw satp, a0      (0x18051073)
      //   lui  a2, 0x20      (0x00020637)  -> a2 = 0x20000 (virtual)
      //   ld   a1, 0(a2)     (0x00063583)
      //   nop                (0x00000013)
      '''@0
73 10 05 18 37 06 02 00 83 35 06 00 13 00 00 00
@10000
01 44 00 00 00 00 00 00
@11000
01 48 00 00 00 00 00 00
@12100
0F C0 00 00 00 00 00 00
@30000
0D F0 FE CA 00 00 00 00
''',
      {Register.x11: 0xCAFEF00D},
      config,
      initRegisters: {
        // satp: MODE=8 (Sv39) bits 63:60, root PPN = 0x10000>>12 = 0x10.
        Register.x10: 0x8000000000000010,
      },
      nextPc: 0x10,
    ),
  );

  test(
    'Sv39 dport store translates 0x20000 -> 0x30000',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      // Enable Sv39, build a3 in-program, then store it to virtual 0x20000
      // (-> physical 0x30000). a3 is set in-program because the harness's
      // initRegisters can only reliably preload a single register.
      //   csrw satp, a0       (0x18051073)
      //   lui  a2, 0x20       (0x00020637)  -> a2 = 0x20000 (virtual)
      //   addi a3, x0, 0x234  (0x23400693)
      //   sd   a3, 0(a2)      (0x00d63023)
      //   nop                 (0x00000013)
      '''@0
73 10 05 18 37 06 02 00 93 06 40 23 23 30 d6 00
13 00 00 00
@10000
01 44 00 00 00 00 00 00
@11000
01 48 00 00 00 00 00 00
@12100
0F C0 00 00 00 00 00 00
@30000
00 00 00 00 00 00 00 00
''',
      const {},
      config,
      initRegisters: {Register.x10: 0x8000000000000010},
      // The translated physical address 0x30000 holds the stored value.
      memStates: {0x30000: 0x234},
      nextPc: 0x14,
    ),
  );

  final sv48Config = RiverCoreConfig(
    mxlen: RiscVMxlen.rv64,
    extensions: kRva22S64Extensions,
    type: RiverCoreType.general,
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [
        RiscVPagingMode.bare,
        RiscVPagingMode.sv39,
        RiscVPagingMode.sv48,
      ],
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

  // Sv48: 4-level walk. Page tables identity within memory:
  //   l3 @ 0x10000 (root, PPN 0x10), l2 @ 0x11000, l1 @ 0x12000, l0 @ 0x13000.
  // Maps vaddr 0x20000 -> paddr 0x30000.
  //   vpn3=0, vpn2=0, vpn1=0, vpn0=0x20  -> l0 PTE at 0x13000 + 0x20*8 = 0x13100
  //   l3[0] @ 0x10000 = (0x11<<10)|1 = 0x4401
  //   l2[0] @ 0x11000 = (0x12<<10)|1 = 0x4801
  //   l1[0] @ 0x12000 = (0x13<<10)|1 = 0x4C01
  //   l0[0x20] @ 0x13100 = (0x30<<10)|0xF = 0xC00F
  test(
    'Sv48 dport load translates 0x20000 -> 0x30000 (4-level)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      // satp MODE=9 (Sv48), root PPN 0x10.
      '''@0
73 10 05 18 37 06 02 00 83 35 06 00 13 00 00 00
@10000
01 44 00 00 00 00 00 00
@11000
01 48 00 00 00 00 00 00
@12000
01 4C 00 00 00 00 00 00
@13100
0F C0 00 00 00 00 00 00
@30000
0D F0 FE CA 00 00 00 00
''',
      {Register.x11: 0xCAFEF00D},
      sv48Config,
      initRegisters: {
        // satp: MODE=9 (Sv48) bits 63:60, root PPN 0x10.
        Register.x10: 0x9000000000000010,
      },
      nextPc: 0x10,
    ),
  );
}
