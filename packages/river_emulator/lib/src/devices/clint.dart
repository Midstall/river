import 'dart:async';

import 'package:river/river.dart';

import '../dev.dart';
import '../soc.dart';

class Clint extends Device {
  int msip = 0;
  int mtimecmp = 0;
  int _mtimeBase = 0;

  final Stopwatch _stopwatch = Stopwatch();

  Clint(super.config) {
    _stopwatch.start();
  }

  int get mtime {
    final hz = config.clockFrequency ?? 0;
    if (hz <= 0) {
      return _mtimeBase + _stopwatch.elapsedMicroseconds;
    }

    final elapsedUs = _stopwatch.elapsedMicroseconds;
    final ticks = elapsedUs * hz ~/ 1000000;
    return _mtimeBase + ticks;
  }

  set mtime(int value) {
    _mtimeBase = value;
    _stopwatch
      ..reset()
      ..start();
  }

  bool get softwareInterruptPending => (msip & 0x1) != 0;

  bool get timerInterruptPending => mtimecmp != 0 && mtime >= mtimecmp;

  @override
  Map<int, bool> interrupts(int hart) {
    return {0: softwareInterruptPending, 1: timerInterruptPending};
  }

  @override
  void reset() {
    msip = 0;
    mtimecmp = 0;
    _mtimeBase = 0;
    _stopwatch
      ..reset()
      ..start();
  }

  @override
  DeviceAccessor? get memAccessor => ClintAccessor(this);

  static Device create(
    RiverDevice config,
    Map<String, String> options,
    RiverSoC soc,
  ) {
    return Clint(config);
  }
}

class ClintAccessor extends DeviceAccessor {
  final Clint device;

  ClintAccessor(this.device) : super(type: DeviceAccessorType.io);

  @override
  Future<int> read(int addr, int width) async {
    // CLINT register map:
    // 0x0000: msip (4 bytes)
    // 0x4000: mtimecmp (8 bytes)
    // 0xBFF8: mtime (8 bytes)
    if (addr >= 0x0000 && addr < 0x0004) {
      return device.msip & 0xFFFFFFFF;
    } else if (addr >= 0x4000 && addr < 0x4008) {
      final offset = addr - 0x4000;
      return (device.mtimecmp >> (offset * 8)) & ((1 << (width * 8)) - 1);
    } else if (addr >= 0xBFF8 && addr < 0xC000) {
      final offset = addr - 0xBFF8;
      return (device.mtime >> (offset * 8)) & ((1 << (width * 8)) - 1);
    }
    return 0;
  }

  @override
  Future<void> write(int addr, int value, int width) async {
    if (addr >= 0x0000 && addr < 0x0004) {
      device.msip = value & 0x1;
    } else if (addr >= 0x4000 && addr < 0x4008) {
      final offset = addr - 0x4000;
      final mask = ((1 << (width * 8)) - 1) << (offset * 8);
      device.mtimecmp =
          (device.mtimecmp & ~mask) | ((value << (offset * 8)) & mask);
    } else if (addr >= 0xBFF8 && addr < 0xC000) {
      final offset = addr - 0xBFF8;
      final mask = ((1 << (width * 8)) - 1) << (offset * 8);
      device.mtime = (device.mtime & ~mask) | ((value << (offset * 8)) & mask);
    }
  }
}
