import 'package:riscv/riscv.dart';
import '../../devices/clint.dart';
import '../../devices/dram.dart';
import '../../devices/plic.dart';
import '../../devices/uart.dart';
import '../../core/v1.dart';
import '../../../interconnect/base.dart';
import '../../../interconnect/wishbone.dart';
import '../../../bus.dart';
import '../../../cache.dart';
import '../../../clock.dart';
import '../../../dev.dart';
import '../../../mem.dart';
import '../../../river_base.dart';

/// Creek V1 SoC
class CreekV1SoC extends RiverSoC {
  final ClockDomainConfig sysclk;
  final ClockDomainConfig lfclk;
  final int flashSize;
  final int dramSize;
  final int l1Size;
  final int l1iSize;
  final int l1dSize;

  @override
  List<Device> get devices => [
    RiscVClint(name: 'clint', address: 0x02000000, clock: sysclk.clock),
    RiscVPlic(
      name: 'plic',
      address: 0x04000000,
      clock: sysclk.clock,
      interrupt: 0,
    ),
    RiverUart(
      name: 'uart0',
      address: 0x10000000,
      clock: sysclk.clock,
      interrupt: 1,
    ),
    Device.simple(
      name: 'gpio',
      compatible: 'river,gpio',
      interrupts: const [2],
      range: const BusAddressRange(0x10001000, 0x00001000),
      fields: const {
        0: DeviceField('input', 4),
        1: DeviceField('output', 4),
        2: DeviceField('dir', 4),
      },
      type: DeviceAccessorType.io,
      clock: sysclk.clock,
    ),
    Device.simple(
      name: 'flash',
      compatible: 'river,flash',
      range: BusAddressRange(0x20000000, flashSize),
      type: DeviceAccessorType.memory,
      fields: const {0: DeviceField('read', 4)},
    ),
    RiverDram(
      name: 'dram',
      address: 0x7fffffe1,
      maxSize: dramSize,
      channels: 1,
      clock: sysclk.clock,
    ),
  ];

  @override
  List<BusClientPort> get clients =>
      devices.map((dev) => dev.clientPort).nonNulls.toList();

  @override
  List<RiverCore> get cores => [
    RiverCoreV1.small(
      interrupts: const [
        InterruptController(
          name: '/cpu0/interrupts',
          baseAddr: 0x0C000000,
          lines: interrupts,
        ),
      ],
      mmu: Mmu(mxlen: Mxlen.mxlen_64, blocks: mmap),
      clock: sysclk.clock,
      l1cache: L1Cache.split(
        iSize: l1iSize,
        dSize: l1dSize,
        ways: 4,
        lineSize: 64,
      ),
      resetVector: 0x20000000,
    ),
  ];

  @override
  Interconnect get fabric => WishboneFabric(
    arbitration: BusArbitration.priority,
    hosts: const [BusHostPort('/cpu0')],
    clients: clients,
  );

  @override
  List<ClockDomain> get clocks => [
    sysclk.getDomain(
      consumers: [
        '/cpu0',
        ...devices
            .where((dev) => dev.clock?.name == sysclk.name)
            .map((dev) => dev.name)
            .toList(),
      ],
    ),
    lfclk.getDomain(
      consumers: devices
          .where((dev) => dev.clock?.name == lfclk.name)
          .map((dev) => dev.name)
          .toList(),
    ),
  ];

  @override
  List<RiverPortMap> get ports => [
    const RiverPortMap('uart_rx', [4], {'uart0': 'rx'}),
    const RiverPortMap('uart_tx', [6], {'uart0': 'tx'}, isOutput: true),
  ];

  List<MemoryBlock> get mmap =>
      devices.map((dev) => dev.mmap).nonNulls.toList();

  const CreekV1SoC({
    required this.sysclk,
    required this.lfclk,
    required this.flashSize,
    required this.dramSize,
    required this.l1iSize,
    required this.l1dSize,
  }) : l1Size = l1iSize + l1dSize;

  /// Alpha Creek V1 SoC
  const CreekV1SoC.alpha({this.l1iSize = 0x10000, this.l1dSize = 0x10000})
    : sysclk = const ClockDomainConfig(
        name: 'sysclk',
        freqHz: 48e6,
        divisors: const [1, 2, 4, 8],
      ),
      lfclk = const ClockDomainConfig(
        name: 'lfclk',
        freqHz: 10e3,
        divisors: const [1, 2, 4, 8],
      ),
      flashSize = 0x01000000,
      dramSize = 0x100000,
      l1Size = 0x20000;

  static const List<InterruptLine> interrupts = [
    InterruptLine(irq: 1, source: '/uart0', target: '/cpu0'),
    InterruptLine(irq: 2, source: '/gpio', target: '/cpu0'),
  ];

  static CreekV1SoC? configure(Map<String, dynamic> options) {
    final l1iSize = options['l1iSize'] as int?;
    final l1dSize = options['l1dSize'] as int?;

    if (options.containsKey('platform')) {
      switch (options['platform']) {
        case 'alpha':
          return CreekV1SoC.alpha(
            l1iSize: l1iSize ?? 0x10000,
            l1dSize: l1dSize ?? 0x10000,
          );
        default:
          return null;
      }
    }

    final sysclk =
        ClockDomainConfig.from(options['sysclk'] ?? (throw 'Missing sysclk')) ??
        (throw 'Invalid sysclk');
    final lfclk =
        ClockDomainConfig.from(options['lfclk'] ?? (throw 'Missing lfclk')) ??
        (throw 'Invalid lfclk');
    final flashSize =
        (options['flashSize'] ?? (throw 'Missing flash size')) as int;
    final dramSize =
        (options['dramSize'] ?? (throw 'Missing DRAM size')) as int;

    return CreekV1SoC(
      sysclk: sysclk,
      lfclk: lfclk,
      flashSize: flashSize,
      dramSize: dramSize,
      l1iSize: l1iSize ?? (throw 'Missing l1i size'),
      l1dSize: l1dSize ?? (throw 'Missing l1d size'),
    );
  }
}
