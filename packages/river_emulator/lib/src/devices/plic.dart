import 'dart:async';
import 'package:river/river.dart';

import '../dev.dart';
import '../soc.dart';

class Plic extends Device {
  final int numSources;
  final List<int> _priority;
  final Map<int, int> _enable = {};
  final Map<int, int> _threshold = {};

  int _pending = 0;

  Plic(super.config, {this.numSources = 32})
    : _priority = List<int>.filled(33, 1);

  void setPriority(int i, int value) {
    _priority[i] = value;
  }

  void setSourcePending(int source, bool level) {
    if (source <= 0 || source > numSources) return;

    if (level) {
      _pending |= (1 << source);
    } else {
      _pending &= ~(1 << source);
    }
  }

  int _findBest(int hartId) {
    final enableMask = _enable[hartId] ?? 0;
    final threshold = _threshold[hartId] ?? 0;

    int best = 0;
    int bestPrio = 0;

    for (int id = 1; id <= numSources; id++) {
      final mask = 1 << id;
      if ((_pending & mask) == 0) continue;
      if ((enableMask & mask) == 0) continue;

      final prio = _priority[id];
      if (prio <= threshold) continue;

      if (prio >= bestPrio) {
        bestPrio = prio;
        best = id;
      }
    }

    return best;
  }

  @override
  Map<int, bool> interrupts(int hart) {
    final best = _findBest(hart);
    return {0: best != 0};
  }

  int claim(int hartId) {
    final id = _findBest(hartId);
    if (id != 0) _pending &= ~(1 << id);
    return id;
  }

  void complete(int hartId, int id) {
    if (id <= 0 || id > numSources) return;
    _pending &= ~(1 << id);
  }

  @override
  void reset() {
    for (int i = 0; i < _priority.length; i++) {
      _priority[i] = 1;
    }
    _pending = 0;
    _enable.clear();
    _threshold.clear();
  }

  @override
  DeviceAccessor? get memAccessor => PlicAccessor(this);

  static Device create(
    RiverDevice config,
    Map<String, String> options,
    RiverSoC soc,
  ) {
    final sources = int.tryParse(options['sources'] ?? '') ?? 32;
    return Plic(config, numSources: sources);
  }
}

class PlicAccessor extends DeviceAccessor {
  final Plic device;

  PlicAccessor(this.device) : super(type: DeviceAccessorType.io);

  @override
  Future<int> read(int addr, int width) async {
    // PLIC register map:
    // 0x000000-0x000FFF: source priorities (4 bytes each)
    // 0x001000-0x00107F: pending bits
    // 0x002000-0x0020FF: enable bits for context 0
    // 0x200000: threshold for context 0
    // 0x200004: claim/complete for context 0
    if (addr >= 0x000000 && addr < 0x001000) {
      final source = addr ~/ 4;
      if (source > 0 && source <= device.numSources) {
        return device._priority[source];
      }
    } else if (addr >= 0x001000 && addr < 0x001080) {
      return device._pending;
    } else if (addr >= 0x002000 && addr < 0x002100) {
      final hart = (addr - 0x002000) ~/ 0x80;
      return device._enable[hart] ?? 0;
    } else if (addr >= 0x200000 && addr < 0x400000) {
      final context = (addr - 0x200000) ~/ 0x1000;
      final offset = (addr - 0x200000) % 0x1000;
      if (offset == 0) {
        return device._threshold[context] ?? 0;
      } else if (offset == 4) {
        return device.claim(context);
      }
    }
    return 0;
  }

  @override
  Future<void> write(int addr, int value, int width) async {
    value &= 0xFFFFFFFF;

    if (addr >= 0x000000 && addr < 0x001000) {
      final source = addr ~/ 4;
      if (source > 0 && source <= device.numSources) {
        device._priority[source] = value & 0x7;
      }
    } else if (addr >= 0x002000 && addr < 0x002100) {
      final hart = (addr - 0x002000) ~/ 0x80;
      device._enable[hart] = value;
    } else if (addr >= 0x200000 && addr < 0x400000) {
      final context = (addr - 0x200000) ~/ 0x1000;
      final offset = (addr - 0x200000) % 0x1000;
      if (offset == 0) {
        device._threshold[context] = value & 0x7;
      } else if (offset == 4) {
        device.complete(context, value);
      }
    }
  }
}
