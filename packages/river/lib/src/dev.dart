import 'bus.dart';
import 'clock.dart';
import 'mem.dart';
import 'river_base.dart';

class DevicePort {
  final String name;
  final int width;
  final bool isOutput;

  const DevicePort(this.name, this.width, {this.isOutput = false});

  @override
  String toString() => 'DevicePort($name, $width, isOutput: $isOutput)';
}

class DeviceField {
  final String name;
  final int width;
  final int? offset;

  const DeviceField(this.name, this.width, {this.offset});

  @override
  String toString() => 'DeviceField($name, $width, offset: $offset)';
}

enum DeviceAccessorType { memory, io, mixed }

class DeviceAccessor {
  final String path;
  final Map<int, DeviceField> fields;
  final DeviceAccessorType type;
  final BusAddressRange? memoryRange;
  final BusAddressRange? ioRange;

  const DeviceAccessor(
    this.path,
    this.fields, {
    this.type = DeviceAccessorType.io,
    this.memoryRange,
    this.ioRange,
  });

  int? fieldAddress(String name) {
    var offset = 0;
    for (final field in fields.values) {
      final start = field.offset ?? offset;
      final end = start + field.width;

      if (name == field.name) {
        return start;
      }

      offset = end;
    }
    return null;
  }

  DeviceField? getField(int addr) {
    var offset = 0;
    for (final field in fields.values) {
      final start = field.offset ?? offset;
      final end = start + field.width;

      if (addr >= start && addr < end) {
        return field;
      }

      offset = end;
    }
    return null;
  }

  List<DeviceField> getFields(int addr, int width) {
    final end = addr + width;

    var offset = 0;
    List<DeviceField> list = [];
    for (final field in fields.values) {
      final start = field.offset ?? offset;
      final fieldEnd = start + field.width;

      final overlaps = (addr < fieldEnd) && (end > start);
      if (overlaps) {
        list.add(field);
      }

      offset = fieldEnd;
    }
    return list;
  }

  String? readPath(int addr) {
    final field = getField(addr);
    if (field == null) return null;
    return '$path/${field.name}%read';
  }

  String? writePath(int addr) {
    final field = getField(addr);
    if (field == null) return null;
    return '$path/${field.name}%write';
  }

  @override
  String toString() => 'DeviceAccessor($path, $fields)';
}

class Device {
  final String name;
  final String compatible;
  final BusAddressRange? range;
  final List<int> interrupts;
  final List<DevicePort> ports;
  final DeviceAccessor? accessor;
  final BusClientPort? clientPort;
  final ClockConfig? clock;

  String get module => (runtimeType.toString() == 'Device')
      ? compatible.replaceAll(',', '_')
      : runtimeType.toString();

  const Device({
    required this.name,
    required this.compatible,
    this.range,
    this.interrupts = const [],
    this.ports = const [],
    this.accessor,
    this.clientPort,
    this.clock,
  });

  factory Device.simple({
    required String name,
    required String compatible,
    String? path,
    BusAddressRange? range,
    List<int> interrupts = const [],
    Map<int, DeviceField>? fields,
    DeviceAccessorType type = DeviceAccessorType.memory,
    ClockConfig? clock,
    List<DevicePort> ports = const [],
  }) {
    path ??= '/$name';
    final accessor = fields != null
        ? DeviceAccessor(path, fields, type: type)
        : null;
    final clientPort = fields != null && range != null
        ? BusClientPort(
            name: path,
            range: range!,
            accessor: DeviceAccessor(path, fields),
          )
        : null;

    return Device(
      name: name,
      compatible: compatible,
      range: range,
      interrupts: interrupts,
      accessor: accessor,
      clientPort: clientPort,
      clock: clock,
      ports: ports,
    );
  }

  MemoryBlock? get mmap {
    if (range != null && accessor != null) {
      return MemoryBlock(range!.start, range!.size, accessor!);
    }
    return null;
  }

  @override
  String toString() =>
      'Device(name: \"$name\", compatible: \"$compatible\", range: $range,'
      ' interrupts: $interrupts, ports: $ports, accessor: $accessor, clientPort: $clientPort, clock: $clock)';
}
