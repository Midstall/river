import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';

/// H2: HSV (hypervisor virtual store). From M-mode, HSV.W must store to guest
/// memory through the guest two-stage translation. Reuses the two-stage tables:
/// gva 0x20000 -VS-> gpa 0x30000 -G-> host 0x40000. After HSV.W of 0x5A5 to the
/// guest address, host physical 0x40000 must hold 0x5A5.
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
  // HSV.W rs2, (rs1): SYSTEM, funct7=0x35, funct3=4.
  int hsvw(int rs1, int rs2) =>
      (0x35 << 25) | (rs2 << 20) | (rs1 << 15) | (0x4 << 12) | 0x73;

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

  String pte(int v) {
    final sb = StringBuffer();
    for (var b = 0; b < 8; b++) {
      sb.write(((v >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    return sb.toString().trimRight();
  }

  test(
    'HSV.W stores guest memory via two-stage translation from M-mode',
    timeout: Timeout(Duration(seconds: 180)),
    () {
      final prog = words([
        csrw(0x280, 10), // 0 csrw vsatp, a0
        addi(14, 0, 0x50), //1
        addi(15, 0, 1), //  2
        slli(15, 15, 63), //3
        orr(14, 14, 15), //4 x14 = hgatp
        csrw(0x680, 14), //5 csrw hgatp, x14
        lui(13, 0x20), //  6 x13 = 0x20000 (guest virtual)
        addi(12, 0, 0x5A5), //7 x12 = 0x5A5 (store data)
        hsvw(13, 12), //   8 hsv.w a2, (a3)
        0x00000013, //     9 nop
      ]);
      return coreTest(
        '@0\n$prog\n'
        '@10000\n${pte(0x4401)}\n'
        '@11000\n${pte(0x4801)}\n'
        '@12100\n${pte(0xC00F)}\n'
        '@40000\n${pte(0x0)}\n'
        '@50000\n${pte(0x14401)}\n'
        '@51000\n${pte(0x14801)}\n'
        '@52080\n${pte(0x401F)}\n'
        '@52088\n${pte(0x441F)}\n'
        '@52090\n${pte(0x481F)}\n'
        '@52180\n${pte(0x1001F)}\n',
        const {},
        config,
        initRegisters: {Register.x10: 0x8000000000000010},
        memStates: {0x40000: 0x5A5},
        nextPc: 0x28,
      );
    },
  );
}
