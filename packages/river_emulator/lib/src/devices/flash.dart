import 'dart:io';

import 'package:river/river.dart';
import '../core.dart';
import '../dev.dart';
import '../soc.dart';

class Flash extends Device {
  final List<int> data;
  bool enabled;

  Flash(super.config, this.data) : enabled = true;

  @override
  DeviceAccessor? get memAccessor => FlashAccessor(this);

  @override
  String toString() => 'Flash(config: $config)';

  static Device create(
    RiverDevice config,
    Map<String, String> options,
    RiverSoC soc,
  ) {
    var data = List.filled(config.range!.size, 0);

    if (options.containsKey('file')) {
      data = File(options['file']!).readAsBytesSync();
    } else if (options.containsKey('bytes')) {
      final bytes = options['bytes']!;
      data = Iterable<int>.generate(bytes.length ~/ 2)
          .map((i) => int.parse(bytes.substring(i * 2, i * 2 + 2), radix: 16))
          .toList()
          .reversed
          .toList();
    }

    if (data.length < config.range!.size) {
      data = [...data, ...List.filled(config.range!.size - data.length, 0)];
    }

    return Flash(config, data);
  }
}

class FlashAccessor extends DeviceAccessor {
  final Flash rom;

  FlashAccessor(this.rom);

  @override
  Future<int> read(int addr, int width) {
    if (!rom.enabled) throw TrapException(Trap.loadAccess, addr);
    int value = rom.data
        .getRange(addr, addr + width)
        .toList()
        .reversed
        .fold(0, (v, i) => (v << 8) | (i & 0xFF));
    return Future.value(value);
  }
}
