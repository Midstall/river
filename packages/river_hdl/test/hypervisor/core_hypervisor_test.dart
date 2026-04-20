import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// Hypervisor (H) phase. H0: the H + VS-shadow CSRs exist and are read/write
/// when the config has H (gated on hasHypervisor). See project_hypervisor.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // RV64 + supervisor + hypervisor. H virtualizes S, so supervisor is required.
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

  // csrrw x0, csr, rs1  (write csr = rs1); csrrs rd, csr, x0 (read csr -> rd).
  int csrw(int csr, int rs1) =>
      (csr << 20) | (rs1 << 15) | (0x1 << 12) | (0 << 7) | 0x73;
  int csrr(int csr, int rd) =>
      (csr << 20) | (0 << 15) | (0x2 << 12) | (rd << 7) | 0x73;
  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
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

  // H0: hgatp (0x680) and hstatus (0x600) round-trip via csrw/csrr.
  // a0 (x10) is preloaded; csrw writes it, csrr reads it back into a reg.
  test(
    'H CSRs read/write (hgatp, hstatus)',
    timeout: Timeout(Duration(seconds: 300)),
    () {
      return coreTest(
        prog([
          csrw(0x680, 10), // csrw hgatp, a0   (a0 = 0x123)
          csrr(0x680, 11), // csrr a1, hgatp   -> a1 = 0x123
          iimm(0x55, 0, 0x0, 12), // x12 = 0x55
          csrw(0x600, 12), // csrw hstatus, x12
          csrr(0x600, 13), // csrr a3, hstatus -> a3 = 0x55
          0x00000013, // nop (halt target)
        ]),
        {Register.x11: 0x123, Register.x13: 0x55},
        config,
        initRegisters: {Register.x10: 0x123},
        nextPc: 0x14,
      );
    },
  );
}
