import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

// amocas.w/.d: compare mem[rs1] against rd; if equal store rs2; rd <- loaded.
// funct7 = funct5(00101)<<2 = 0x14, funct3 = 0x2 (w) / 0x3 (d), opcode 0x2F.
int _amocas(int rs2, int rs1, int funct3, int rd) =>
    (0x14 << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (funct3 << 12) |
    (rd << 7) |
    0x2F;

void main() {
  group('Zacas (amocas)', () {
    late RiverCore core;
    late int pc;

    setUp(() {
      final config = RiverCoreConfig(
        clock: const HarborClockConfig(
          name: 'test',
          rate: HarborFixedClockRate(10000),
        ),
        mxlen: RiscVMxlen.rv64,
        extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvA, rvZacas],
        interrupts: [],
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv64,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        type: RiverCoreType.general,
      );
      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: 10000,
        ),
      );
      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
      pc = config.resetVector;
    });

    test(
      'amocas.w stores rs2 when compare matches; rd gets loaded value',
      () async {
        await core.mmu.write(0x1000, 42, 4);
        core.xregs[Register.x5] = 0x1000; // addr
        core.xregs[Register.x3] = 42; // compare value (== mem) -> swap happens
        core.xregs[Register.x6] = 99; // swap value

        await core.cycle(pc, _amocas(6, 5, 0x2, 3)); // amocas.w x3,x6,(x5)

        expect(core.xregs[Register.x3], 42, reason: 'rd <- loaded value');
        expect(
          await core.mmu.read(0x1000, 4),
          99,
          reason: 'mem swapped to rs2',
        );
      },
    );

    test('amocas.w leaves memory unchanged when compare mismatches', () async {
      await core.mmu.write(0x1000, 42, 4);
      core.xregs[Register.x5] = 0x1000;
      core.xregs[Register.x3] = 7; // compare value (!= mem) -> no swap
      core.xregs[Register.x6] = 99;

      await core.cycle(pc, _amocas(6, 5, 0x2, 3));

      expect(core.xregs[Register.x3], 42, reason: 'rd <- loaded value');
      expect(await core.mmu.read(0x1000, 4), 42, reason: 'mem unchanged');
    });

    test('amocas.d compare-and-swap on a full doubleword', () async {
      await core.mmu.write(0x1008, 0xDEADBEEFCAFEBABE, 8);
      core.xregs[Register.x5] = 0x1008;
      core.xregs[Register.x3] = 0xDEADBEEFCAFEBABE; // matches
      core.xregs[Register.x6] = 0x0123456789ABCDEF;

      await core.cycle(pc, _amocas(6, 5, 0x3, 3)); // amocas.d x3,x6,(x5)

      expect(core.xregs[Register.x3], 0xDEADBEEFCAFEBABE);
      expect(await core.mmu.read(0x1008, 8), 0x0123456789ABCDEF);
    });
  });
}
