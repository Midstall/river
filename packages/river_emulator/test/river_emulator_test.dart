import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

RiverSoCConfig _testConfig() {
  final sysclk = HarborClockConfig(
    name: 'sysclk',
    rate: HarborFixedClockRate(48000000),
  );

  return RiverSoCConfig(
    devices: [
      const RiverDevice(
        name: 'clint',
        compatible: 'riscv,clint0',
        range: BusAddressRange(0x02000000, 0x10000),
      ),
      const RiverDevice(
        name: 'plic',
        compatible: 'riscv,plic0',
        range: BusAddressRange(0x04000000, 0x4000000),
        interrupts: [0],
      ),
      const RiverDevice(
        name: 'uart0',
        compatible: 'ns16550a',
        range: BusAddressRange(0x10000000, 0x8),
        interrupts: [1],
      ),
      const RiverDevice(
        name: 'flash',
        compatible: 'river,flash',
        range: BusAddressRange(0x20000000, 0x1000000),
      ),
      const RiverDevice(
        name: 'sram',
        compatible: 'river,sram',
        range: BusAddressRange(0x80000000, 0x100000),
      ),
    ],
    cores: [
      RiverCoreConfigV1.nano(
        mmu: HarborMmuConfig(
          mxlen: RiscVMxlen.rv32,
          pagingModes: const [RiscVPagingMode.bare],
          tlbLevels: const [],
          pmp: HarborPmpConfig.none,
        ),
        interrupts: [],
        clock: sysclk,
        resetVector: 0x20000000,
      ),
    ],
  );
}

void main() {
  group('Emulator', () {
    final config = _testConfig();
    late RiverSoC soc;

    setUp(() {
      soc = RiverSoC(
        config,
        deviceOptions: {
          'uart0': {'input.empty': 'true', 'output.empty': 'true'},
        },
      );
    });

    test('Configure', () {
      soc.reset();

      expect(soc.devices.length, 5);
      expect(soc.cores.length, 1);
    });

    test('Read data', () async {
      final soc = RiverSoC(
        config,
        deviceOptions: {
          'flash': {'bytes': '002081B3'},
          'uart0': {'input.empty': 'true', 'output.empty': 'true'},
        },
      );

      final range = soc.getDevice('flash')!.config.range!;

      soc.reset();

      expect(
        await soc.cores[0].read(range.start, soc.cores[0].config.mxlen.bytes),
        0x002081B3,
      );
    });

    test('Reset & execute', () async {
      final soc = RiverSoC(
        config,
        deviceOptions: {
          'flash': {'bytes': '00A08293'},
          'uart0': {'input.empty': 'true', 'output.empty': 'true'},
        },
      );

      final range = soc.getDevice('flash')!.config.range!;

      soc.reset();

      soc.cores[0].xregs[Register.x1] = 12;

      final pc = (await soc.runPipelines({}))[0]!;
      expect(config.cores[0].resetVector, range.start);
      expect(config.cores[0].resetVector, pc - 4);
      expect(soc.cores[0].xregs[Register.x5], 22);
    });
  });
}
