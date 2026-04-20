import 'package:river/river.dart';
import 'package:test/test.dart';

/// Atomic (A) decode regression: every AMO/LR/SC decodes at its SPEC encoding,
/// where the funct7 field (inst[31:25]) = funct5<<2 (aq=rl=0). Guards the fix for
/// the systematic Harbor bug where atomic funct7 values were funct5<<3 - which made
/// amoxor/amoor/amomin mis-decode (e.g. amoxor.w -> lr.w) and amomax/amominu/amomaxu
/// undecodable (funct7 > 0x7F). Only amoadd (funct5=0) was accidentally correct.
void main() {
  final config = RiverCoreConfigV1.macro(
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  );

  // funct5 -> mnemonic stem (RISC-V A spec). funct3 selects .w (0x2) / .d (0x3).
  const funct5 = {
    0x00: 'amoadd',
    0x01: 'amoswap',
    0x02: 'lr',
    0x03: 'sc',
    0x04: 'amoxor',
    0x08: 'amoor',
    0x0C: 'amoand',
    0x10: 'amomin',
    0x14: 'amomax',
    0x18: 'amominu',
    0x1C: 'amomaxu',
  };

  for (final width in const [(0x2, 'w'), (0x3, 'd')]) {
    test('atomics decode at spec encodings (.${width.$2})', () {
      for (final e in funct5.entries) {
        // funct7 = funct5<<2 (aq=rl=0); opcode AMO = 0x2F; rs2=rs1=rd=0.
        final instr = ((e.key << 2) << 25) | (width.$1 << 12) | 0x2F;
        final op = config.isa.findOperation(instr);
        expect(
          op?.mnemonic,
          '${e.value}.${width.$2}',
          reason:
              'funct5=0x${e.key.toRadixString(16)} instr='
              '0x${instr.toRadixString(16)} should be ${e.value}.${width.$2}',
        );
      }
    });
  }
}
