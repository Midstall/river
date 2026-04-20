import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

import '../constants.dart';

void main() {
  group('HDL compressed decode (pattern match)', () {
    final config = kCpuConfigs['RC1.n']!;
    final rom = MicrocodeRom(config.isa, encodings: kMicroOpTable);

    test('identifies c.j (0xbfcd)', () {
      expect(rom.lookup(0xbfcd)?.mnemonic, 'c.j');
    });
    test('identifies c.addi (0x0285)', () {
      expect(rom.lookup(0x0285)?.mnemonic, 'c.addi');
    });
    test('identifies c.lw (0x4040)', () {
      expect(rom.lookup(0x4040)?.mnemonic, 'c.lw');
    });
    test('distinguishes c.mv (0x852e) from c.add (0x952e)', () {
      expect(rom.lookup(0x852e)?.mnemonic, 'c.mv');
      expect(rom.lookup(0x952e)?.mnemonic, 'c.add');
    });
    test('CA arithmetic c.sub (0x8c05) / c.and (0x8c65)', () {
      expect(rom.lookup(0x8c05)?.mnemonic, 'c.sub');
      expect(rom.lookup(0x8c65)?.mnemonic, 'c.and');
    });
    test('CB-arith c.srli (0x8005) / c.andi (0x987d)', () {
      expect(rom.lookup(0x8005)?.mnemonic, 'c.srli');
      expect(rom.lookup(0x987d)?.mnemonic, 'c.andi');
    });
    test('CR jumps: c.jr (0x8082) / c.jalr (0x9082) / c.ebreak (0x9002)', () {
      expect(rom.lookup(0x8082)?.mnemonic, 'c.jr');
      expect(rom.lookup(0x9082)?.mnemonic, 'c.jalr');
      expect(rom.lookup(0x9002)?.mnemonic, 'c.ebreak');
    });
    test('c.addi16sp (0x7139, rd=x2) vs c.lui (0x6285, rd=x10)', () {
      // 0x7139 = addi sp,sp,-64 (won't fit c.addi's 6-bit imm); c.addi sp,sp,-16
      // (0x1141) is a separate, valid encoding.
      expect(rom.lookup(0x7139)?.mnemonic, 'c.addi16sp');
      expect(rom.lookup(0x6285)?.mnemonic, 'c.lui');
      expect(rom.lookup(0x1141)?.mnemonic, 'c.addi');
    });
  });
}
