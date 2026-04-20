import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// H3 (groundwork): guest VS-stage translation. With virt=1 (entered via MRET),
/// data accesses translate through vsatp instead of HS satp; the G-stage is
/// identity (bare hgatp). A load from guest-virtual 0x20000 must reach physical
/// 0x30000 via the vsatp page table, proving the V-bit routes to the VS-stage.
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
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x0 << 12) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  int orr(int rd, int rs1, int rs2) =>
      (rs2 << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x33;
  int lui(int rd, int imm20) => (imm20 << 12) | (rd << 7) | 0x37;
  int ld(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x03;
  const mret = 0x30200073;

  String prog(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  // a0(x10)=vsatp value (Sv39|root 0x10) preloaded. Build mstatus (MPP=S|MPV)
  // and mepc=0x28 in-program, MRET into VS-mode, then translate a load.
  test(
    'VS-stage translates guest load 0x20000 -> 0x30000',
    timeout: Timeout(Duration(seconds: 120)),
    () {
      return coreTest(
        // NOTE: MPV (bit 39) is built with two slli<32 shifts, slli with
        // shamt>=32 currently hangs the in-order decoder (separate RV64 gap).
        '${prog([
          csrw(0x280, 10), // 0x00 csrw vsatp, a0
          addi(11, 0, 0x2c), // 0x04 a1 = 0x2c (mepc target)
          csrw(0x341, 11), // 0x08 csrw mepc, a1
          addi(12, 0, 1), // 0x0c a2 = 1
          slli(12, 12, 11), // 0x10 a2 = 0x800   (MPP=S)
          addi(13, 0, 1), // 0x14 a3 = 1
          slli(13, 13, 20), // 0x18 a3 = 0x100000
          slli(13, 13, 19), // 0x1c a3 = 1<<39 (MPV)
          orr(12, 12, 13), // 0x20 a2 = 0x8000000800
          csrw(0x300, 12), // 0x24 csrw mstatus, a2
          mret, // 0x28 -> VS-mode (S, virt=1), pc=0x2c
          lui(13, 0x20), // 0x2c a3 = 0x20000 (guest virtual)
          ld(14, 13, 0), // 0x30 a4 = *(translate(0x20000))
          0x00000013, // 0x34 nop
        ]).trimRight()}\n'
        '@10000\n01 44 00 00 00 00 00 00\n'
        '@11000\n01 48 00 00 00 00 00 00\n'
        '@12100\n0F C0 00 00 00 00 00 00\n'
        '@30000\n0D F0 FE CA 00 00 00 00\n',
        {Register.x14: 0xCAFEF00D},
        config,
        initRegisters: {Register.x10: 0x8000000000000010},
        nextPc: 0x38,
      );
    },
  );
}
