import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Comprehensive differential integrity check for the delta intermittent wedge:
/// an async interrupt taken at ANY cycle over a diverse instruction stream
/// (loads, AMOs, arithmetic) must be transparent to the architectural registers.
/// The handler touches only x28 and mrets, so a correct core leaves x18..x24 at
/// their computed values regardless of when the IRQ fires. If River corrupts a
/// load's or AMO's destination (or any reg) on the take/return, one value
/// diverges, the corrupted-pointer root of the misaligned-amoor.d / duplicate-
/// ticket HW wedge.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

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

  const park = 0x0000006f;
  const mret = 0x30200073;
  int addi(int rd, int rs1, int imm) =>
      ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
  int ld(int rd, int rs1) => (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
  int sd(int rs2, int rs1) => (rs2 << 20) | (rs1 << 15) | (3 << 12) | 0x23;
  // amoadd.d rd, rs2, (rs1): funct7=0 amoadd, funct3=3 (.d)
  int amoaddD(int rd, int rs2, int rs1) =>
      (rs2 << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2F;

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

  const setup = [
    0x30529073,
    0x30431073,
    0x3003a073,
  ]; // mtvec,x5 ; mie,x6 ; mstatus,x7
  // x10 = data base 0x2000. Stream: load pointers/values, do an AMO, arithmetic.
  // x18 = *0x2000 ; x19 = *0x2008 ; x20 = x18+x19 ; amoadd.d x21,x19,(x10) ;
  // x22 = *0x2000 (post-amo) ; x23 = x20 ^ ... ; x24 = x18 + 0x10.
  final body = <int>[
    ...setup,
    ld(18, 10), // x18 = mem[x10]
    ld(19, 10), // x19 = mem[x10] (same, both known)
    addi(20, 18, 0x10), // x20 = x18 + 0x10
    amoaddD(21, 19, 10), // x21 = old mem[x10]; mem[x10] += x19
    ld(22, 10), // x22 = mem[x10] (post-amo)
    addi(23, 20, 0x20), // x23 = x20 + 0x20
    addi(24, 18, 0x30), // x24 = x18 + 0x30
    for (var i = 0; i < 16; i++) 0x00000013, // nop pad
    park,
  ];
  final parkPc = (body.length - 1) * 4;
  final handler = <int>[0x0ab00e13, mret]; // addi x28,x0,0xAB ; mret
  String prog() => mem({0x0: body, 0x300: handler});

  // mem[0x2000] = 0x100. x10 = 0x2000. After: x18=x19=x22-... x21=old=0x100,
  // mem[0x2000]=0x100+0x100=0x200, x22=0x200. x20=0x110, x23=0x130, x24=0x130.
  final init = {
    Register.x5: 0x300,
    Register.x6: 1 << 7,
    Register.x7: 1 << 3,
    Register.x10: 0x2000,
  };
  String progWithData() => prog() + '@2000\n00 01 00 00 00 00 00 00\n';

  final expected = {
    Register.x18: 0x100,
    Register.x19: 0x100,
    Register.x20: 0x110,
    Register.x21: 0x100,
    Register.x22: 0x200,
    Register.x23: 0x130,
    Register.x24: 0x130,
  };

  // Fire the IRQ at every cycle over the whole stream+pad. Every cycle must
  // leave all x18..x24 at [expected] (interrupt is transparent). A divergence
  // pinpoints the cycle/instruction where the take corrupts a register.
  for (var at = 8; at <= 48; at++) {
    test(
      'IRQ at cycle $at preserves all registers (diverse stream)',
      timeout: Timeout(Duration(minutes: 3)),
      () {
        return coreTest(
          progWithData(),
          expected,
          cfg(),
          initRegisters: init,
          nextPc: parkPc,
          maxCycles: 5000,
          memLatency: 2,
          raiseTimerIrqAt: at,
          lowerTimerIrqAt: at + 3,
        );
      },
    );
  }
}
