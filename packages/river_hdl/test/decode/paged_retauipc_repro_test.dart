import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Paged repro of the HW illegal-trap on Linux's `_start_kernel` return targets.
///
/// The bare-mode call->ret->auipc repro PASSES, but on delta the trap happens
/// under PAGING (satp=swapper, 2MB superpage) at a jalr return target. This
/// mirrors that: an identity 2MB superpage (L1 leaf), S-mode, a call whose
/// return target is an `auipc` at a vaddr with vpn0 != 0 (0x100c, so
/// vaddr[20:12]=1, exactly the superpage sub-page bit that 0x...1160 exercises).
/// Fetching that return target goes through the MMU after a redirect.
///
/// Page tables (identity superpage over virtual 0..2MB-1):
///   L2 @ 0x10000 (root, PPN 0x10):  L2[0] = (0x11<<10)|V     = 0x4401
///   L1 @ 0x11000:                   L1[0] = (0<<10)|V|R|W|X  = 0x000F  (2MB leaf)
///
/// Program:
///   @0x00 csrw satp, a0      enable Sv39 + the superpage
///   @0x04 jal  x0, +0xffc    jump to 0x1000 (into the vpn0=1 sub-page)
///   @0x1000 addi x6, x0, 0x11
///   @0x1004 auipc ra, 0      ra = 0x1004
///   @0x1008 jalr  ra, 20(ra) call 0x1018, return ra = 0x100c
///   @0x100c auipc a0, 0      RETURN TARGET (vaddr[20:12]=1) -> a0 = 0x100c
///   @0x1010 jal   x0, 0      park
///   @0x1018 jalr  x0, 0(ra)  ret -> 0x100c
///
/// Pass: x6=0x11, a0=0x100c, parks at 0x1010. Trap => reproduced in sim.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig full() => RiverCoreConfigV1.full(
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

  // Build the @-addressed hex memory image.
  String mem(Map<int, List<int>> words) {
    final sb = StringBuffer();
    final addrs = words.keys.toList()..sort();
    for (final a in addrs) {
      sb.writeln('@${a.toRadixString(16)}');
      for (final w in words[a]!) {
        for (var i = 0; i < 4; i++) {
          sb.write(((w >> (i * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
          sb.write(' ');
        }
      }
      sb.writeln();
    }
    return sb.toString();
  }

  String prog() => mem({
    0x00: [
      0x18051073, // csrw satp, a0
      0x7FD0006F, // jal x0, +0xffc  -> 0x1000
    ],
    0x1000: [
      0x01100313, // addi x6, x0, 0x11
      0x00000097, // auipc ra, 0        ra = 0x1004
      0x014080e7, // jalr ra, 20(ra)    -> 0x1018, ra = 0x100c
      0x00000517, // auipc a0, 0        RETURN TARGET (0x100c) -> a0 = 0x100c
      0x0000006f, // jal x0, 0          park @ 0x1010
      0x00000013, // nop @ 0x1014
      0x00008067, // jalr x0, 0(ra)     ret -> 0x100c  (@0x1018)
    ],
    0x10000: [0x00004401, 0x0], // L2[0]
    0x11000: [0x0000000F, 0x0], // L1[0] 2MB leaf, PPN 0
  });

  // Control: same paged superpage, but STRAIGHT-LINE (no call/ret redirect).
  // Isolates whether the redirect is the trigger vs the superpage fetch itself.
  String progStraight() => mem({
    0x00: [
      0x18051073, // csrw satp, a0
      0x7FD0006F, // jal x0, +0xffc -> 0x1000
    ],
    0x1000: [
      0x01100313, // addi x6, x0, 0x11
      0x00000517, // auipc a0, 0   (0x1004, straight-line) -> a0 = 0x1004
      0x0000006f, // jal x0, 0     park @ 0x1008
    ],
    0x10000: [0x00004401, 0x0],
    0x11000: [0x0000000F, 0x0],
  });

  test(
    'CONTROL paged superpage straight-line auipc (no redirect)',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      progStraight(),
      {Register.x6: 0x11, Register.x10: 0x1004},
      full(),
      startPriv: PrivilegeMode.supervisor,
      initRegisters: {Register.x10: 0x8000000000000010},
      nextPc: 0x1008,
    ),
  );

  test(
    'paged superpage: auipc at a jalr return target (vpn0=1) decodes',
    timeout: Timeout(Duration(minutes: 6)),
    () => coreTest(
      prog(),
      {Register.x6: 0x11, Register.x10: 0x100c},
      full(),
      startPriv: PrivilegeMode.supervisor,
      initRegisters: {Register.x10: 0x8000000000000010},
      nextPc: 0x1010,
    ),
  );

  test(
    'paged redirect with HIGH memLatency (mimic DDR refill)',
    timeout: Timeout(Duration(minutes: 8)),
    () => coreTest(
      prog(),
      {Register.x6: 0x11, Register.x10: 0x100c},
      full(),
      startPriv: PrivilegeMode.supervisor,
      initRegisters: {Register.x10: 0x8000000000000010},
      nextPc: 0x1010,
      memLatency: 20,
    ),
  );
}
