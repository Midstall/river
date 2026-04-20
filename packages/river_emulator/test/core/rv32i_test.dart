import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import '../constants.dart';

void main() {
  cpuTests('RV32I', (config) {
    late Sram sram;
    late RiverCore core;
    late int pc;

    setUp(() {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: (config.clock.rate as HarborFixedClockRate).frequency,
        ),
      );

      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
      pc = config.resetVector;
    });

    Future<void> writeWord(int addr, int value) =>
        core.mmu.write(addr, value, 4);

    Future<int> readWord(int addr) => core.mmu.read(addr, 4);

    test('addi increments register', () async {
      core.reset();

      final instr = 0x00A00293;
      final nextPc = await core.cycle(pc, instr);

      expect(core.xregs[Register.x5], equals(10));
      expect(nextPc, pc + 4);
    });

    test('add performs register addition', () async {
      core.reset();

      core.xregs[Register.x5] = 7;
      core.xregs[Register.x6] = 9;

      final instr = 0x005303B3;
      final nextPc = await core.cycle(pc, instr);

      expect(core.xregs[Register.x7], equals(16));
      expect(nextPc, pc + 4);
    });

    test('lw loads from memory', () async {
      core.reset();

      core.xregs[Register.x5] = 0x20;
      await writeWord(0x24, 0xDEADBEEF);

      final instr = 0x0042A303;
      final nextPc = await core.cycle(pc, instr);

      expect(core.xregs[Register.x6]!.toUnsigned(32), equals(0xDEADBEEF));
      expect(nextPc, pc + 4);
    });

    test('sw stores to memory', () async {
      core.reset();

      core.xregs[Register.x5] = 0x20;
      core.xregs[Register.x6] = 0xCAFEBABE;

      const instr = 0x0062A223;
      final nextPc = await core.cycle(pc, instr);

      expect(await readWord(0x24), equals(0xCAFEBABE));
      expect(nextPc, pc + 4);
    });

    test('beq takes branch when equal', () async {
      core.reset();

      core.xregs[Register.x5] = 5;
      core.xregs[Register.x6] = 5;

      const instr = 0x00628463;
      final nextPc = await core.cycle(pc, instr);

      expect(nextPc, equals(pc + 8));
    });

    test('beq does not branch when not equal', () async {
      core.reset();

      core.xregs[Register.x5] = 5;
      core.xregs[Register.x6] = 7;

      const instr = 0x00628463;
      final nextPc = await core.cycle(pc, instr);

      expect(nextPc, equals(pc + 4));
    });

    test('lui loads upper immediate', () async {
      core.reset();

      const instr = 0x123452B7;
      final nextPc = await core.cycle(pc, instr);

      expect(core.xregs[Register.x5], equals(0x12345000));
      expect(nextPc, equals(pc + 4));
    });

    test('jal writes ra and jumps', () async {
      core.reset();

      const instr = 0x100002EF;
      final nextPc = await core.cycle(pc, instr);

      expect(core.xregs[Register.x5], equals(pc + 4));
      expect(nextPc, equals(pc + 0x100));
    });

    test('auipc adds immediate to PC', () async {
      const instr = 0x00010297;
      final nextPc = await core.cycle(pc, instr);

      expect(core.xregs[Register.x5], equals(pc + 0x10000));
      expect(nextPc, equals(pc + 4));
    });

    test('slti sets when less-than immediate', () async {
      core.xregs[Register.x4] = 5;

      const instr = 0x00A22293;
      final nextPc = await core.cycle(pc, instr);

      expect(core.xregs[Register.x5], equals(1));
      expect(nextPc, equals(pc + 4));
    });
  });
}
