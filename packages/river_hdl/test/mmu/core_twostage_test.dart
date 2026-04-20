import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// H3: full two-stage translation. A guest load is translated VS-stage
/// (vsatp: gva 0x20000 -> gpa 0x30000) and then every VS page-table access AND
/// the final gpa are G-translated (hgatp). The G-stage identity-maps the VS
/// table pages but REMAPS gpa 0x30000 -> host 0x40000, where the data lives,
/// so the load only returns the right value if BOTH stages walk correctly.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final config = RiverCoreConfig(
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvPriv, rvH],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
  );

  int csrw(int csr, int rs1) => (csr << 20) | (rs1 << 15) | (0x1 << 12) | 0x73;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  int orr(int rd, int rs1, int rs2) =>
      (rs2 << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x33;
  int lui(int rd, int imm20) => (imm20 << 12) | (rd << 7) | 0x37;
  int ld(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x03;
  const mret = 0x30200073;

  String words(List<int> ws) {
    final sb = StringBuffer();
    for (final w in ws) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return sb.toString().trimRight();
  }

  // 8-byte little-endian PTE string.
  String pte(int v) {
    final sb = StringBuffer();
    for (var b = 0; b < 8; b++) {
      sb.write(((v >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return sb.toString().trimRight();
  }

  test(
    'two-stage VS+G translates guest load to remapped host page',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      final prog = words([
        csrw(0x280, 10), //  0 csrw vsatp, a0    (Sv39 | root gpa-PPN 0x10)
        addi(15, 0, 1), //   1 x15 = 1
        slli(15, 15, 63), // 2 x15 = 1<<63
        addi(14, 0, 0x50), //3 x14 = 0x50
        orr(14, 14, 15), // 4 x14 = hgatp (Sv39 | root host-PPN 0x50)
        csrw(0x680, 14), // 5 csrw hgatp, x14
        addi(12, 0, 1), //   6 x12 = 1
        slli(12, 12, 11), // 7 x12 = 0x800 (MPP=S)
        addi(13, 0, 1), //   8 x13 = 1
        slli(13, 13, 39), // 9 x13 = MPV bit
        orr(12, 12, 13), //10 x12 = 0x8000000800
        csrw(0x300, 12), //11 csrw mstatus, x12
        addi(11, 0, 0x3c), //12 x11 = 0x3c (mepc target = idx15)
        csrw(0x341, 11), //13 csrw mepc, x11
        mret, //           14 -> VS-mode (S, virt=1), pc=0x3c
        lui(13, 0x20), //  15 x13 = 0x20000 (guest virtual)
        ld(3, 13, 0), //   16 x3 = *(two-stage translate(0x20000))
        0x00000013, //     17 nop
      ]);
      return coreTest(
        '@0\n$prog\n'
        // VS-stage tables (live at host = identity of their gpa via G-stage):
        '@10000\n${pte(0x4401)}\n' // vs_l2[0] -> gpa 0x11000
        '@11000\n${pte(0x4801)}\n' // vs_l1[0] -> gpa 0x12000
        '@12100\n${pte(0xC00F)}\n' // vs_l0[0x20] leaf -> gpa 0x30000
        // Data lives at HOST 0x40000 (gpa 0x30000 remapped by the G-stage):
        '@40000\n${pte(0xCAFEF00D)}\n'
        // G-stage tables (host-physical; hgatp root host-PPN 0x50):
        '@50000\n${pte(0x14401)}\n' // g_l2[0] -> host 0x51000
        '@51000\n${pte(0x14801)}\n' // g_l1[0] -> host 0x52000
        '@52080\n${pte(0x401F)}\n' // g_l0[0x10] gpa0x10->host0x10 (V|R|W|X|U)
        '@52088\n${pte(0x441F)}\n' // g_l0[0x11] gpa0x11->host0x11
        '@52090\n${pte(0x481F)}\n' // g_l0[0x12] gpa0x12->host0x12
        '@52180\n${pte(0x1001F)}\n', // g_l0[0x30] gpa0x30->host0x40 (remap!)
        {Register.x3: 0xCAFEF00D},
        config,
        initRegisters: {Register.x10: 0x8000000000000010},
        nextPc: 0x48,
      );
    },
  );
}
