import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// H4 (CSR redirect): in VS-mode (virt=1) a supervisor-CSR access redirects to
/// the VS shadow. A VS-mode `csrw satp` must land in vsatp, verified by reading
/// vsatp back directly (x5) and via the redirected `csrr satp` (x6); both equal
/// the written value, which is impossible without the redirect (vsatp would
/// stay 0). Flow: MRET into VS-mode, then the three CSR ops, then loop.
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
  const jalLoop = 0x0000006F;

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
    'VS-mode csrw satp redirects to vsatp',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      final prog = words([
        addi(11, 0, 0x24), //  0 x11 = 0x24 (VS code address)
        csrw(0x341, 11), //    1 csrw mepc, x11
        addi(12, 0, 1), //     2
        slli(12, 12, 11), //   3 x12 = 0x800 (MPP=S)
        addi(13, 0, 1), //     4
        slli(13, 13, 39), //   5 x13 = MPV
        orr(12, 12, 13), //    6 x12 = 0x8000000800
        csrw(0x300, 12), //    7 csrw mstatus, x12
        0x30200073, //         8 @0x20 mret -> VS-mode (S, virt=1), pc=0x24
        csrw(0x180, 10), //    9 @0x24 VS: csrw satp,a0 -> redirects to vsatp
        csrr(
          0x280,
          5,
        ), //    10 @0x28 csrr x5, vsatp (direct: 0x280 not redirected)
        csrr(0x180, 6), //    11 @0x2c csrr x6, satp  (redirects to vsatp)
        jalLoop, //           12 @0x30 loop
      ]);
      return coreTest(
        '@0\n$prog\n',
        {
          Register.x5:
              0x8000000000000042, // vsatp received the VS-mode satp write
          Register.x6:
              0x8000000000000042, // VS-mode csrr satp redirects to vsatp
        },
        config,
        initRegisters: {Register.x10: 0x8000000000000042},
        nextPc: 0x30,
      );
    },
  );
}
