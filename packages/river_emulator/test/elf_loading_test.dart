import 'package:bintools/bintools.dart';
import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import 'constants.dart';

Elf _buildElf(List<int> words, {int addr = 0}) {
  final section = Section('.text');
  for (final w in words) {
    section.emitWord(w);
  }
  final writer = ElfWriter(entryPoint: addr);
  writer.addSection(section, address: addr);
  return Elf.load(writer.write());
}

RiverSoC _makeSoC(RiverCoreConfig config, Sram sram) {
  final core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
  return RiverSoC.fromDevicesAndCores(cores: [core], devices: [sram]);
}

void main() {
  group('ELF loading', () {
    test('loadBytes writes data at correct offset', () {
      final config = kCpuConfigs['RC1.mi']!;
      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0x1000, 0x2000),
          clockFrequency: 10000,
        ),
      );

      final soc = _makeSoC(config, sram);
      soc.loadBytes(0x1000, [0xDE, 0xAD, 0xBE, 0xEF]);

      expect(sram.data[0], 0xDE);
      expect(sram.data[1], 0xAD);
      expect(sram.data[2], 0xBE);
      expect(sram.data[3], 0xEF);
    });

    test('loadBytes at offset within device', () {
      final config = kCpuConfigs['RC1.mi']!;
      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0x1000, 0x2000),
          clockFrequency: 10000,
        ),
      );

      final soc = _makeSoC(config, sram);
      soc.loadBytes(0x1010, [0x01, 0x02]);

      expect(sram.data[0x10], 0x01);
      expect(sram.data[0x11], 0x02);
    });

    test('loadElf loads PT_LOAD segment into memory', () {
      final config = kCpuConfigs['RC1.mi']!;
      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: 10000,
        ),
      );

      final soc = _makeSoC(config, sram);

      // addi x5, x0, 42 -> 0x02A00293
      final elf = _buildElf([0x02A00293, 0x00700313]);
      soc.loadElf(elf);

      // Little-endian: 0x02A00293 -> [0x93, 0x02, 0xA0, 0x02]
      expect(sram.data[0], 0x93);
      expect(sram.data[1], 0x02);
      expect(sram.data[2], 0xA0);
      expect(sram.data[3], 0x02);
    });

    test('loaded ELF executes correctly', () async {
      final config = kCpuConfigs['RC1.mi']!;
      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: 10000,
        ),
      );

      final soc = _makeSoC(config, sram);
      final core = soc.cores[0];

      // addi x5, x0, 42
      soc.loadElf(_buildElf([0x02A00293]));

      var pc = config.resetVector;
      pc = await core.runPipeline(pc);

      expect(core.xregs[Register.x5], 42);
    });

    test('multiple ELFs load to different regions', () {
      final config = kCpuConfigs['RC1.mi']!;
      final sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: 10000,
        ),
      );

      final soc = _makeSoC(config, sram);

      // Firmware at 0x0000
      soc.loadElf(_buildElf([0x02A00293], addr: 0x0000));
      // Payload at 0x1000
      soc.loadElf(_buildElf([0x00700313], addr: 0x1000));

      // Check firmware at 0x0000
      expect(sram.data[0], 0x93);
      expect(sram.data[3], 0x02);

      // Check payload at 0x1000
      expect(sram.data[0x1000], 0x13);
      expect(sram.data[0x1003], 0x00);
    });

    test('ELF entry point is preserved', () {
      final elf = _buildElf([0x02A00293], addr: 0x8000);
      expect(elf.header.entry, 0x8000);
    });
  });
}
