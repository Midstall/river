import 'package:bintools/bintools.dart';
import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
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
  resetVector: 0x20000000,
);

RiverMaskromConfig _maskromConfig({int copySize = 64}) => RiverMaskromConfig(
  isa: _microConfig().isa,
  resetVector: 0x20000000,
  flashSource: 0x20100000,
  copyDest: 0x80000000,
  copySize: copySize,
  stackTop: 0x20010000,
);

void main() {
  group('Maskrom', () {
    test('produces assembly with copy loop and jalr', () async {
      final rom = RiverMaskrom(_maskromConfig());
      await rom.build();

      final asm = rom.generateAssembly();
      expect(asm, contains('lw'));
      expect(asm, contains('sw'));
      expect(asm, contains('bne'));
      expect(asm, contains('jalr'));
    });

    test('produces valid ELF', () async {
      final rom = RiverMaskrom(_maskromConfig());
      await rom.build();

      final elf = Elf.load(rom.emitElfBytes(entryPoint: 0x20000000));

      expect(elf.header.entry, 0x20000000);
      expect(elf.programHeaders.where((ph) => ph.type == 1), isNotEmpty);
    });

    test('copies firmware from flash to SRAM and jumps', () async {
      final config = _microConfig();
      final rom = RiverMaskrom(_maskromConfig(copySize: 8));
      await rom.build();

      final flash = Sram(
        RiverDevice(
          name: 'flash',
          compatible: 'river,sram',
          range: BusAddressRange(0x20000000, 0x200000),
          clockFrequency: 10000,
        ),
      );

      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0x80000000, 0x10000),
          clockFrequency: 10000,
        ),
      );

      final core = RiverCore(
        config,
        memDevices: Map.fromEntries([flash.mem!, sram.mem!]),
      );

      final binary = rom.generateBinary();
      for (var i = 0; i < binary.length; i++) {
        flash.data[i] = binary[i];
      }

      // addi x5, x0, 42
      final fwOffset = 0x20100000 - 0x20000000;
      flash.data[fwOffset + 0] = 0x93;
      flash.data[fwOffset + 1] = 0x02;
      flash.data[fwOffset + 2] = 0xA0;
      flash.data[fwOffset + 3] = 0x02;
      // nop
      flash.data[fwOffset + 4] = 0x13;
      flash.data[fwOffset + 5] = 0x00;
      flash.data[fwOffset + 6] = 0x00;
      flash.data[fwOffset + 7] = 0x00;

      var pc = 0x20000000;
      for (var i = 0; i < 200; i++) {
        final instr = await core.fetch(pc);
        pc = await core.cycle(pc, instr);
        if (pc.toUnsigned(32) == 0x80000000) break;
      }

      expect(pc.toUnsigned(32), 0x80000000);
      expect(core.mode, PrivilegeMode.machine);

      expect(sram.data[0], 0x93);
      expect(sram.data[1], 0x02);
      expect(sram.data[2], 0xA0);
      expect(sram.data[3], 0x02);

      final fwInstr = await core.fetch(pc);
      pc = await core.cycle(pc, fwInstr);
      expect(core.xregs[Register.x5], 42);
    });

    test('CAR mode locks cache and copies firmware', () async {
      final coreConfig = RiverCoreConfigV1.micro(
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
        resetVector: 0x20000000,
        l1cache: HarborL1CacheConfig.split(
          iSize: 0x4000,
          dSize: 0x4000,
          ways: 4,
          lineSize: 64,
        ),
      );

      final rom = RiverMaskrom(
        RiverMaskromConfig(
          isa: coreConfig.isa,
          resetVector: 0x20000000,
          flashSource: 0x20100000,
          copyDest: 0x80000000,
          copySize: 8,
          stackTop: 0x80001000,
          bootMode: RiverBootMode.cacheAsRam,
        ),
      );

      await rom.build();
      final asm = rom.generateAssembly();
      expect(asm, contains('csrrw'));
      expect(asm, contains('jalr'));

      final flash = Sram(
        RiverDevice(
          name: 'flash',
          compatible: 'river,sram',
          range: BusAddressRange(0x20000000, 0x200000),
          clockFrequency: 10000,
        ),
      );

      final core = RiverCore(
        coreConfig,
        memDevices: Map.fromEntries([flash.mem!]),
      );

      final binary = rom.generateBinary();
      for (var i = 0; i < binary.length; i++) {
        flash.data[i] = binary[i];
      }

      // Firmware at flash source
      final fwOffset = 0x20100000 - 0x20000000;
      flash.data[fwOffset + 0] = 0x93;
      flash.data[fwOffset + 1] = 0x02;
      flash.data[fwOffset + 2] = 0xA0;
      flash.data[fwOffset + 3] = 0x02;
      flash.data[fwOffset + 4] = 0x13;
      flash.data[fwOffset + 5] = 0x00;
      flash.data[fwOffset + 6] = 0x00;
      flash.data[fwOffset + 7] = 0x00;

      var pc = 0x20000000;
      for (var i = 0; i < 300; i++) {
        final instr = await core.fetch(pc);
        pc = await core.cycle(pc, instr);
        if (pc.toUnsigned(32) == 0x80000000) break;
      }

      expect(pc.toUnsigned(32), 0x80000000);

      // Firmware should be readable from locked L1D cache
      final cached = await core.read(0x80000000, 4);
      expect(cached & 0xFFFFFFFF, 0x02A00293);
    });
  });
}
