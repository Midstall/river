import 'package:river/river.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

RiverCoreConfig _microConfig() => RiverCoreConfigV1.micro(
  mmu: HarborMmuConfig(
    mxlen: RiscVMxlen.rv32,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  ),
  interrupts: [],
  clock: const HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(10000),
  ),
  resetVector: 0x0,
);

void main() {
  test('maskrom binary is valid for HDL loading', () async {
    final config = _microConfig();

    final rom = RiverMaskrom(
      RiverMaskromConfig(
        isa: config.isa,
        resetVector: 0x0,
        flashSource: 0x400,
        copyDest: 0x800,
        copySize: 4,
        stackTop: 0xC00,
      ),
    );

    await rom.build();

    final binary = rom.generateBinary();
    expect(binary.length, greaterThan(0));
    expect(binary.length % 4, 0);

    // Every 4-byte word should be a valid 32-bit instruction
    for (var i = 0; i < binary.length; i += 4) {
      final word =
          binary[i] |
          (binary[i + 1] << 8) |
          (binary[i + 2] << 16) |
          (binary[i + 3] << 24);
      // Bottom 2 bits = 0x3 for 32-bit instructions
      expect(word & 0x3, 0x3, reason: 'instruction at offset $i is not 32-bit');
    }

    final asm = rom.generateAssembly();
    expect(asm, contains('lw'));
    expect(asm, contains('sw'));
    expect(asm, contains('bne'));
    expect(asm, contains('jalr'));
    expect(asm, contains('csrrw'));
  });

  test('CAR maskrom includes cache lock CSRs', () async {
    final config = _microConfig();

    final rom = RiverMaskrom(
      RiverMaskromConfig(
        isa: config.isa,
        resetVector: 0x0,
        flashSource: 0x400,
        copyDest: 0x800,
        copySize: 4,
        stackTop: 0xC00,
        bootMode: RiverBootMode.cacheAsRam,
      ),
    );

    await rom.build();
    final asm = rom.generateAssembly();

    // Should have CSR writes for rcachectl (0x7C0), rcacheaddr (0x7C1), rcachesize (0x7C2)
    final csrWrites = asm
        .split('\n')
        .where((l) => l.contains('csrrw'))
        .toList();
    expect(csrWrites.length, greaterThanOrEqualTo(4)); // mtvec + 3 cache CSRs
  });
}
