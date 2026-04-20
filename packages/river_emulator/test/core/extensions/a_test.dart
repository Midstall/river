import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import '../../constants.dart';

// AMO instruction builder: funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
int _amo(int funct7, int rs2, int rs1, int funct3, int rd) =>
    (funct7 << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (funct3 << 12) |
    (rd << 7) |
    0x2F;

void main() {
  cpuTests('A extension', (config) {
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

    Future<void> writeDword(int addr, int value) =>
        core.mmu.write(addr, value, 8);

    Future<int> readDword(int addr) => core.mmu.read(addr, 8);

    // funct7 = funct5<<2: lr=0x08, sc=0x0C, amoswap=0x04, amoadd=0x00
    // funct3: word=0x2, dword=0x3

    test('lr.w loads a word and reserves the address', () async {
      await writeWord(0x1000, 0x1234);

      core.xregs[Register.x5] = 0x1000;

      final lrw = _amo(0x08, 0, 5, 2, 1); // lr.w x1, (x5)
      await core.cycle(pc, lrw);

      expect(core.xregs[Register.x1], 0x1234);
      expect(core.reservationSet.contains(0x1000), true);
    });

    test('sc.w succeeds when reservation matches', () async {
      await writeWord(0x1000, 0x1111);
      core.xregs[Register.x5] = 0x1000;
      core.xregs[Register.x6] = 0x2222;

      final lrw = _amo(0x08, 0, 5, 2, 1); // lr.w x1, (x5)
      await core.cycle(pc, lrw);

      final scw = _amo(0x0C, 6, 5, 2, 2); // sc.w x2, x6, (x5)
      await core.cycle(pc, scw);

      expect(await readWord(0x1000), 0x2222);
      expect(core.xregs[Register.x2], 0);
    });

    test('sc.w fails when reservation is lost', () async {
      await writeWord(0x1000, 0x1111);
      core.xregs[Register.x5] = 0x1000;
      core.xregs[Register.x6] = 0x2222;

      final lrw = _amo(0x08, 0, 5, 2, 1); // lr.w x1, (x5)
      await core.cycle(pc, lrw);

      core.clearReservationSet();

      final scw = _amo(0x0C, 6, 5, 2, 3); // sc.w x3, x6, (x5)
      await core.cycle(pc, scw);

      expect(await readWord(0x1000), 0x1111);
      expect(core.xregs[Register.x3] ?? 0, isNot(0));
    });

    test('amoswap.w swaps correctly', () async {
      await writeWord(0x1000, 0xAAAA);
      core.xregs[Register.x5] = 0x1000;
      core.xregs[Register.x6] = 0x5555;

      final amoswap = _amo(0x04, 6, 5, 2, 3); // amoswap.w x3, x6, (x5)
      await core.cycle(pc, amoswap);

      expect(core.xregs[Register.x3], 0xAAAA);
      expect(await readWord(0x1000), 0x5555);
    });

    test('amoadd.w adds correctly', () async {
      await writeWord(0x1000, 10);
      core.xregs[Register.x5] = 0x1000;
      core.xregs[Register.x6] = 3;

      final amoadd = _amo(0x00, 6, 5, 2, 3); // amoadd.w x3, x6, (x5)
      await core.cycle(pc, amoadd);

      expect(core.xregs[Register.x3], 10);
      expect(await readWord(0x1000), 13);
    });

    if (config.mxlen == RiscVMxlen.rv64) {
      test('lr.d loads a doubleword and reserves address', () async {
        await writeDword(0x2000, 0x1122334455667788);
        core.xregs[Register.x5] = 0x2000;

        final lrd = _amo(0x08, 0, 5, 3, 1); // lr.d x1, (x5)
        await core.cycle(pc, lrd);

        expect(core.xregs[Register.x1], 0x1122334455667788);
        expect(core.reservationSet.contains(0x2000), true);
      });

      test('sc.d succeeds when reservation matches', () async {
        await writeDword(0x2000, 0x1111);
        core.xregs[Register.x5] = 0x2000;
        core.xregs[Register.x6] = 0x2222333344445555;

        final lrd = _amo(0x08, 0, 5, 3, 1); // lr.d x1, (x5)
        await core.cycle(pc, lrd);

        final scd = _amo(0x0C, 6, 5, 3, 2); // sc.d x2, x6, (x5)
        await core.cycle(pc, scd);

        expect(await readDword(0x2000), 0x2222333344445555);
        expect(core.xregs[Register.x2], 0);
      });

      test('sc.d fails when reservation lost', () async {
        await writeDword(0x2000, 0x9999);
        core.xregs[Register.x5] = 0x2000;
        core.xregs[Register.x6] = 0x1111;

        final lrd = _amo(0x08, 0, 5, 3, 1); // lr.d x1, (x5)
        await core.cycle(pc, lrd);

        core.clearReservationSet();

        final scd = _amo(0x0C, 6, 5, 3, 3); // sc.d x3, x6, (x5)
        await core.cycle(pc, scd);

        expect(await readDword(0x2000), 0x9999);
        expect(core.xregs[Register.x3], isNot(0));
      });
    }
  }, condition: (config) => config.extensions.any((e) => e.name == 'A'));
}
