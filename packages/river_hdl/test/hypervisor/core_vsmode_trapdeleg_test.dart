import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// H4 (trap delegation to VS-mode): a trap taken in VS-mode whose cause is
/// delegated by BOTH medeleg (M->HS) and hedeleg (HS->VS) must trap to vstvec
/// (staying virtualized), not to stvec. vstvec and stvec point at distinct
/// handlers; reaching the vstvec handler (x5=0x111) proves the VS delegation.
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
  int csrr(int csr, int rd) => (csr << 20) | (0x2 << 12) | (rd << 7) | 0x73;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int slli(int rd, int rs1, int sh) =>
      (sh << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13;
  int orr(int rd, int rs1, int rs2) =>
      (rs2 << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x33;
  const ecall = 0x00000073;
  const jalLoop = 0x0000006F;
  const nop = 0x00000013;

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

  test(
    'VS-mode trap delegates to vstvec (hedeleg)',
    timeout: Timeout(Duration(seconds: 200)),
    () {
      final prog = words([
        addi(
          10,
          0,
          0x400,
        ), //  0 x10 = 1<<10 (delegate cause-10 = ecall-from-VS)
        csrw(0x302, 10), //     1 csrw medeleg, x10  (M->HS)
        csrw(0x602, 10), //     2 csrw hedeleg, x10  (HS->VS)
        addi(11, 0, 0x60), //   3 x11 = 0x60 (vstvec handler)
        csrw(0x205, 11), //     4 csrw vstvec, x11
        addi(12, 0, 0x70), //   5 x12 = 0x70 (stvec handler)
        csrw(0x105, 12), //     6 csrw stvec, x12
        addi(13, 0, 0x40), //   7 x13 = 0x40 (mepc = VS code)
        csrw(0x341, 13), //     8 csrw mepc, x13
        addi(14, 0, 1), //      9
        slli(14, 14, 11), //   10 x14 = 0x800 (MPP=S)
        addi(15, 0, 1), //     11
        slli(15, 15, 39), //   12 x15 = MPV
        orr(14, 14, 15), //    13 x14 = 0x8000000800
        csrw(0x300, 14), //    14 csrw mstatus, x14
        0x30200073, //         15 @0x3c mret -> VS-mode, pc=0x40
        ecall, //              16 @0x40 VS ecall -> delegated to VS (vstvec=0x60)
        nop, nop, nop, nop, nop, nop, nop, //  17-23 @0x44..0x5c filler
        // VS handler: read the cause via csrr scause (redirects to vscause in
        // VS-mode), proves the trap landed in VS *and* vscause = ecallVS (10).
        csrr(0x142, 5), //     24 @0x60 x5 = vscause (== 10)
        jalLoop, //            25 @0x64 loop
        nop, nop, //           26-27 @0x68,0x6c
        addi(5, 0, 0x222), //  28 @0x70 HS handler (must NOT run): x5 = 0x222
        jalLoop, //            29 @0x74 loop
      ]);
      return coreTest(
        '@0\n$prog\n',
        {
          Register.x5: 10,
        }, // vscause == ecallVS: reached VS handler with right cause
        config,
        nextPc: 0x64,
      );
    },
  );
}
