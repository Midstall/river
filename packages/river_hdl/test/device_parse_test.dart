import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  group('Device.parse - legacy device forms', () {
    test('type:addr', () {
      final d = Device.parse('uart:0x10000000');
      expect(d.type, 'uart');
      expect(d.name, 'uart');
      expect(d.address, 0x10000000);
      expect(d.size, isNull);
      expect(d.effectiveSize, 0x1000); // uart class default
    });

    test('type:addr:compat', () {
      final d = Device.parse('uart:0x10000000:ns16550a');
      expect(d.type, 'uart');
      expect(d.address, 0x10000000);
      expect(d.compatible, 'ns16550a');
      expect(d.board, isNull);
    });

    test('name=type:addr:compat', () {
      final d = Device.parse('myuart=uart:0x10000000:ns16550a');
      expect(d.name, 'myuart');
      expect(d.type, 'uart');
      expect(d.address, 0x10000000);
      expect(d.compatible, 'ns16550a');
    });

    test('clint with class-default size', () {
      final d = Device.parse('clint:0x02000000');
      expect(d.type, 'clint');
      expect(d.effectiveSize, 0x10000);
    });
  });

  group('Device.parse - memory-backed forms', () {
    test('sram addr:size', () {
      final d = Device.parse('sram:0x08000000:64K');
      expect(d.type, 'sram');
      expect(d.address, 0x08000000);
      expect(d.size, 64 * 1024);
      expect(d.isMemoryBacked, isTrue);
    });

    test('flash addr:size:board', () {
      final d = Device.parse('flash:0x20000000:16M:arty-s7');
      expect(d.type, 'flash');
      expect(d.address, 0x20000000);
      expect(d.size, 16 * 1024 * 1024);
      expect(d.board, 'arty-s7');
      expect(d.flashBoard, isNotNull);
    });

    test('second bare number becomes size', () {
      final d = Device.parse('sram:0x08000000:65536');
      expect(d.address, 0x08000000);
      expect(d.size, 65536);
    });

    test('dram addr:size:board (no params)', () {
      final d = Device.parse('dram:0x80000000:128M:arty-s7-x8');
      expect(d.type, 'dram');
      expect(d.address, 0x80000000);
      expect(d.size, 128 * 1024 * 1024);
      expect(d.board, 'arty-s7-x8');
      expect(d.ddrBoard, isNotNull);
      expect(d.params, isNull);
    });
  });

  group('Device.parse - params', () {
    test('dram with ddr clock params', () {
      final d = Device.parse(
        'dram:0x80000000:128M:arty-s7-x8:ddr3fast=true,clockfreq=200000000',
      );
      expect(d.board, 'arty-s7-x8');
      expect(d.params, isNotNull);
      expect(d.params!.ddr3Fast, isTrue);
      expect(d.params!.clockFreq, 200000000);
    });

    test('dram tuning params still parse (back-compat)', () {
      final d = Device.parse(
        'dram:0x80000000:128M:arty-s7-x8:cmdslot=2,wrshift=-1,readretry=6',
      );
      expect(d.params!.cmdSlot, 2);
      expect(d.params!.wrShift, -1); // negative int
      expect(d.params!.readRetry, 6);
    });

    test('usb-dfu with mode', () {
      final d = Device.parse('usb-dfu:0x0C000000:mode=software');
      expect(d.type, 'usb-dfu');
      expect(d.address, 0x0C000000);
      expect(d.params!.mode, 'software');
    });

    test('flash-firmware offset + path (addr is the flash offset)', () {
      final d = Device.parse('flash-firmware:0x100000:path=weir-fsbl.bin');
      expect(d.type, 'flash-firmware');
      expect(d.address, 0x100000);
      expect(d.params!.path, 'weir-fsbl.bin');
    });
  });

  group('Device.parse - addressless', () {
    test('debug-jtag is type only', () {
      final d = Device.parse('debug-jtag');
      expect(d.type, 'debug-jtag');
      expect(d.address, isNull);
      expect(d.size, isNull);
      expect(d.board, isNull);
      expect(d.params, isNull);
    });
  });

  group('Device.parse - validation', () {
    test('memory-backed type without size throws', () {
      expect(() => Device.parse('sram:0x08000000'), throwsFormatException);
    });

    test('memory-backed type without address throws', () {
      expect(() => Device.parse('dram'), throwsFormatException);
    });

    test('unknown dram board throws', () {
      expect(
        () => Device.parse('dram:0x80000000:128M:no-such-board'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('dram size mismatch against the part throws', () {
      expect(
        () => Device.parse('dram:0x80000000:64M:arty-s7-x8'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('bad usb-dfu mode throws', () {
      expect(
        () => Device.parse('usb-dfu:0x0C000000:mode=bogus'),
        throwsFormatException,
      );
    });

    test('unknown param key throws', () {
      expect(
        () => Device.parse('dram:0x80000000:128M:arty-s7-x8:nonsense=1'),
        throwsFormatException,
      );
    });

    test('a bare word in the board slot is treated as a board name', () {
      // `mode` (no '=') is not a param; on a dram it is read as a board name,
      // which is unknown -> ArgumentError. This is why params always need '='.
      expect(
        () => Device.parse('dram:0x80000000:128M:mode'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('DDR clock-tree agreement (buildSoC validation)', () {
    test('two dram controllers disagreeing on ddr3fast throws', () {
      final config = RiverGenIpConfig(
        name: 'two_dram',
        cores: const ['rc1-s'],
        devices: [
          Device.parse('dram:0x80000000:128M:arty-s7-x8:ddr3fast=true'),
          Device.parse('dram:0x90000000:128M:arty-s7-x8:ddr3fast=false'),
          Device.parse('uart:0x10000000:ns16550a'),
        ],
      );
      // The validation is the first line of buildSoC, so it rejects before any
      // heavy elaboration.
      expect(config.buildSoC(), throwsA(isA<ArgumentError>()));
    });

    test('two dram controllers disagreeing on clockfreq throws', () {
      final config = RiverGenIpConfig(
        name: 'two_dram',
        cores: const ['rc1-s'],
        devices: [
          Device.parse('dram:0x80000000:128M:arty-s7-x8:clockfreq=200000000'),
          Device.parse('dram:0x90000000:128M:arty-s7-x8:clockfreq=333333333'),
          Device.parse('uart:0x10000000:ns16550a'),
        ],
      );
      expect(config.buildSoC(), throwsA(isA<ArgumentError>()));
    });
  });

  group('--board (HarborBoard wiring)', () {
    RiverGenIpConfig cfg() => RiverGenIpConfig(
      name: 'b',
      cores: const ['rc1-s'],
      boardName: 'arty-s7-50',
      devices: [Device.parse('uart:0x10000000:ns16550a')],
    );

    test('board synthesises the target when --target is unset', () {
      final t = cfg().effectiveTarget;
      expect(t, isA<FpgaTarget>());
      final f = t as FpgaTarget;
      expect(f.vendor, 'spartan7'); // openXc7 board -> spartan7 target path
      expect(f.device, 'xc7s50');
      expect(f.package, 'csga324');
    });

    test('explicit --target wins over the board target', () {
      final config = RiverGenIpConfig(
        name: 'b',
        cores: const ['rc1-s'],
        boardName: 'arty-s7-50',
        target: Target.parse('ecp5:lfe5u-25f:CSFBGA285'),
        devices: [Device.parse('uart:0x10000000:ns16550a')],
      );
      expect((config.effectiveTarget as FpgaTarget).vendor, 'ecp5');
    });

    test('board catalog uart_tx binds to the uart device port', () {
      final tx = cfg().effectivePins.firstWhere(
        (p) => p.externalName == 'uart_tx',
      );
      expect(tx.isDevicePin, isTrue);
      expect(tx.deviceName, 'uart');
      expect(tx.portName, 'tx');
    });

    test('board catalog clk is a simple (non-device) pin in fpgaPinMap', () {
      final config = cfg();
      final clk = config.effectivePins.firstWhere(
        (p) => p.externalName == 'clk',
      );
      expect(clk.isDevicePin, isFalse);
      expect(config.fpgaPinMap['clk'], startsWith('R2'));
    });

    test('explicit --pin overrides the board catalog entry', () {
      final config = RiverGenIpConfig(
        name: 'b',
        cores: const ['rc1-s'],
        boardName: 'arty-s7-50',
        pins: [PinAssignment.parse('clk=Z99')],
        devices: [Device.parse('uart:0x10000000:ns16550a')],
      );
      expect(config.fpgaPinMap['clk'], 'Z99');
    });
  });
}
