import 'dart:async';
import 'package:river/river.dart';

import '../dev.dart';
import '../soc.dart';

class DramEmulator extends DeviceEmulator {
  DramEmulator(super.config);

  @override
  void reset() {}

  @override
  DeviceAccessorEmulator? get memAccessor => DramAccessorEmulator(this);

  static DeviceEmulator create(
    Device config,
    Map<String, String> options,
    RiverSoCEmulator _soc,
  ) {
    return DramEmulator(config);
  }
}

class DramAccessorEmulator extends DeviceFieldAccessorEmulator<DramEmulator> {
  DramAccessorEmulator(super.device);

  @override
  Future<int> readPath(String name) async {
    return 0;
  }

  @override
  Future<void> writePath(String name, int value) async {}

  @override
  Future<int> read(int addr, int width) async {
    final fields = config.getFields(addr, width);

    if (fields.isNotEmpty) {
      return super.read(addr, width);
    }

    // TODO: we're reading from one of the memory banks
    return 0;
  }

  @override
  Future<void> write(int addr, int value, int width) async {
    final fields = config.getFields(addr, width);

    if (fields.isNotEmpty) {
      return super.write(addr, value, width);
    }

    // TODO: we're writing to one of the memory banks
  }
}
