import 'package:river/river.dart';
import 'core.dart';
import 'soc.dart';

typedef DeviceFactory =
    Device Function(RiverDevice, Map<String, String>, RiverSoC);

enum DeviceAccessorType { memory, io, mixed }

class Device {
  final RiverDevice config;

  const Device(this.config);

  void reset() {}
  void increment() {}

  Map<int, bool> interrupts(int hart) => {};

  DeviceAccessor? get memAccessor => null;

  MapEntry<BusAddressRange, DeviceAccessor>? get mem {
    if (memAccessor == null || config.range == null) return null;
    return MapEntry(config.range!, memAccessor!);
  }

  @override
  String toString() => 'Device(config: $config)';
}

class DeviceAccessor {
  final DeviceAccessorType type;

  const DeviceAccessor({this.type = DeviceAccessorType.memory});

  Future<int> read(int addr, int width) {
    throw TrapException(Trap.loadAccess, addr, StackTrace.current);
  }

  Future<void> write(int addr, int value, int width) {
    throw TrapException(Trap.storeAccess, addr, StackTrace.current);
  }

  @override
  String toString() => '$runtimeType(type: $type)';
}
