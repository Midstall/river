import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// HW repro attempt for the intermittent delta boot wedge. On silicon the boot
/// hangs at a misaligned `amoor.d` in riscv_v_first_use_handler whose address
/// (rs1 = tp) should be 8-aligned. That instruction sits at a 2-byte-aligned
/// address that STRADDLES the 8-byte L1 I-cache line boundary (rc1 lineSize=8).
/// The hypothesis: when the second line (holding the AMO's high halfword) is a
/// cold miss, the fetch buffer assembles the 32-bit AMO with a stale/garbage
/// high half, mis-decoding rs1 -> a bogus (misaligned) address -> trap/hang.
///
/// This places an `amoor.d x5, x13, (x12)` so its 4 bytes span an 8-byte line
/// boundary, with the second line cold at decode time (memLatency > 0), and
/// checks the AMO uses the CORRECT aligned address (rs1 = x12) and completes.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // .small shares the EXACT rc1-f fetch/MMU/CSR/_rc1L1 icache datapath (8-byte
  // line) but drops the FPU, so the fetch-straddle behaviour is identical and
  // the sim is fast. Bare mode: the straddle is a pure fetch issue.
  RiverCoreConfig cfg() => RiverCoreConfigV1.small(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: const HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
  );

  // amoor.d x5, x13, (x12): funct7=0x20 (funct5=0x08 amoor, aq=rl=0),
  // rs2=x13, rs1=x12, funct3=3 (.d), rd=x5, opcode=0x2F.
  const amoorD =
      (0x20 << 25) | (13 << 20) | (12 << 15) | (3 << 12) | (5 << 7) | 0x2F;
  // ld x28, 0(x12): read back the AMO target to verify the write landed.
  const ldX28 = (12 << 15) | (3 << 12) | (28 << 7) | 0x03;
  const cnop = 0x0001; // c.nop (2 bytes)
  const park = 0x0000006F;

  // Build a contiguous byte image from 0x0 (8-aligned start) with 2-byte
  // halfwords at the given byte addresses, gaps zero-filled, emitted as one
  // @0 block of space-separated bytes (the format loadMemString expects).
  String memHalves(List<(int, int)> halves) {
    var maxAddr = 0;
    for (final (addr, _) in halves) {
      if (addr + 2 > maxAddr) maxAddr = addr + 2;
    }
    final bytes = List<int>.filled(maxAddr, 0);
    for (final (addr, hw) in halves) {
      bytes[addr] = hw & 0xFF;
      bytes[addr + 1] = (hw >> 8) & 0xFF;
    }
    final sb = StringBuffer()..writeln('@0');
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    sb.writeln();
    // Data block: the AMO target mem[0x1000] preloaded with 0x1 (8 bytes LE).
    sb.writeln('@1000');
    sb.write('01 00 00 00 00 00 00 00');
    sb.writeln();
    return sb.toString();
  }

  // Place c.nops from 0x0 so the amoor.d lands at [amoAddr]. A 4-byte op at an
  // address whose low 3 bits are 6 straddles the 8-byte line (e.g. 0x16 spans
  // 0x16..0x19, crossing the 0x18 line boundary; its high half is a cold line).
  String prog(int amoAddr) {
    final halves = <(int, int)>[];
    for (var a = 0; a < amoAddr; a += 2) {
      halves.add((a, cnop));
    }
    halves.add((amoAddr, amoorD & 0xFFFF));
    halves.add((amoAddr + 2, (amoorD >> 16) & 0xFFFF));
    halves.add((amoAddr + 4, ldX28 & 0xFFFF));
    halves.add((amoAddr + 6, (ldX28 >> 16) & 0xFFFF));
    halves.add((amoAddr + 8, park & 0xFFFF));
    halves.add((amoAddr + 10, (park >> 16) & 0xFFFF));
    return memHalves(halves);
  }

  final init = {
    Register.x12: 0x1000, // a2 = aligned AMO target address
    Register.x13: 0x20000, // a3 = the OR operand (like the real set-bit)
  };

  // Straddling amoor.d at offset-6 addresses across several lines, swept over
  // the miss latency of the second (cold) line. A correct core loads the old
  // value into x5, ORs 0x20000 into mem[0x1000], and x28 reads back 0x20001.
  for (final amoAddr in const [0x16, 0x1e, 0x26]) {
    for (final lat in const [0, 2, 4, 8, 16]) {
      test(
        'straddling amoor.d @0x${amoAddr.toRadixString(16)} memLatency=$lat '
        'uses the aligned addr and completes',
        timeout: Timeout(Duration(minutes: 3)),
        () {
          final parkPc = amoAddr + 8;
          return coreTest(
            prog(amoAddr),
            {
              Register.x5: 0x1, // AMO rd = old value at mem[0x1000]
              Register.x28: 0x20001, // read-back = old | 0x20000
            },
            cfg(),
            initRegisters: init,
            memStates: {0x1000: 0x20001},
            nextPc: parkPc,
            maxCycles: 4000,
            memLatency: lat,
          );
        },
      );
    }
  }

  // Control: the SAME amoor.d aligned (not straddling), to prove the harness
  // executes the AMO correctly when there is no line-straddle.
  test(
    'control: aligned amoor.d executes correctly',
    timeout: Timeout(Duration(minutes: 3)),
    () {
      // Put the amoor.d at 0x8 (4-byte aligned, within one 8-byte line 0x8..0xf).
      final halves = <(int, int)>[
        (0x0, cnop),
        (0x2, cnop),
        (0x4, cnop),
        (0x6, cnop),
        (0x8, amoorD & 0xFFFF),
        (0xa, (amoorD >> 16) & 0xFFFF),
        (0xc, ldX28 & 0xFFFF),
        (0xe, (ldX28 >> 16) & 0xFFFF),
        (0x10, park & 0xFFFF),
        (0x12, (park >> 16) & 0xFFFF),
      ];
      return coreTest(
        memHalves(halves),
        {Register.x5: 0x1, Register.x28: 0x20001},
        cfg(),
        initRegisters: init,
        memStates: {0x1000: 0x20001},
        nextPc: 0x10,
        maxCycles: 4000,
        memLatency: 8,
      );
    },
  );
}
