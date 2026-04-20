import 'dart:collection';
import 'package:bintools/bintools.dart';
import 'package:river/river.dart';
import 'core.dart';
import 'dev.dart';
import 'devices.dart';

const _emptyConfig = RiverSoCConfig();

/// Emulator of the SoC
class RiverSoC {
  List<RiverCore> _cores;
  List<Device> _devices;

  final RiverSoCConfig config;

  UnmodifiableListView<RiverCore> get cores => UnmodifiableListView(_cores);
  UnmodifiableListView<Device> get devices => UnmodifiableListView(_devices);

  RiverSoC(
    this.config, {
    Map<String, Map<String, String>> deviceOptions = const {},
    Map<String, DeviceFactory> deviceFactory = kDeviceFactory,
  }) : _cores = const [],
       _devices = const [] {
    _devices = config.devices.map((dev) {
      if (deviceFactory.containsKey(dev.compatible)) {
        return deviceFactory[dev.compatible]!(
          dev,
          deviceOptions[dev.name] ?? {},
          this,
        );
      }

      return Device(dev);
    }).toList();

    final memDevices = Map.fromEntries(
      _devices.map((dev) => dev.mem).nonNulls.toList(),
    );
    _cores = config.cores
        .map((core) => RiverCore(core, memDevices: memDevices))
        .toList();
  }

  RiverSoC.fromDevicesAndCores({
    required List<RiverCore> cores,
    required List<Device> devices,
  }) : config = _emptyConfig,
       _cores = cores,
       _devices = devices;

  Device? getDevice(String name) {
    for (final dev in devices) {
      if (dev.config.name == name) return dev;
    }
    return null;
  }

  void reset() {
    for (final core in _cores) {
      core.reset();
    }
    for (final dev in _devices) {
      dev.reset();
    }
  }

  void increment() {
    for (final dev in _devices) {
      dev.increment();
    }
    for (final core in _cores) {
      core.csrs.increment();
    }
  }

  void interrupts() {
    for (final dev in _devices) {
      for (final core in _cores) {
        final interrupts = dev.interrupts(core.config.hartId);

        for (final entry in interrupts.entries) {
          final id = entry.key;
          final value = entry.value;

          if (id >= dev.config.interrupts.length) {
            // Device emits an interrupt with no configured routing (e.g. a
            // CLI-defined SoC without an interrupt map); nothing to deliver.
            continue;
          }

          final irq = dev.config.interrupts[id];

          for (final ctrl in core.interrupts) {
            final line = ctrl.config.lines
                .where((l) => l.irq == irq)
                .firstOrNull;

            if (line == null) continue;

            if (line.target != '/cpu${core.config.hartId}') continue;

            if (value) {
              ctrl.raise(line.source, line.irq);
            } else {
              ctrl.lower(line.source, line.irq);
            }
          }
        }
      }
    }
  }

  Future<Map<int, int>> runPipelines(Map<int, int> pcs) async {
    return Map.fromEntries(
      await Future.wait(
        cores.map((core) async {
          var pc = pcs[core.config.hartId] ?? core.config.resetVector;
          return MapEntry(core.config.hartId, await core.runPipeline(pc));
        }),
      ),
    );
  }

  Future<Map<int, int>> run(Map<int, int> pcs) async {
    increment();
    pcs = await runPipelines(pcs);
    interrupts();
    return pcs;
  }

  List<int>? _deviceData(Device dev) {
    if (dev is Sram) return dev.data;
    if (dev is Dram) return dev.data;
    if (dev is Flash) return dev.data;
    return null;
  }

  void loadBytes(int addr, List<int> bytes) {
    for (final dev in _devices) {
      if (dev.config.range == null) continue;
      final range = dev.config.range!;
      final data = _deviceData(dev);
      if (data == null) continue;

      if (addr >= range.start && addr < range.end) {
        final offset = addr - range.start;
        for (var i = 0; i < bytes.length && offset + i < data.length; i++) {
          data[offset + i] = bytes[i];
        }
        return;
      }
    }
  }

  void loadElf(Elf elf) {
    for (final ph in elf.programHeaders) {
      if (ph.type != 1) continue;
      if (ph.fileSize == 0 && ph.memSize == 0) continue;

      final paddr = ph.pAddr;
      final segData = elf.segmentData(ph);

      for (final dev in _devices) {
        if (dev.config.range == null) continue;
        final range = dev.config.range!;
        final devData = _deviceData(dev);
        if (devData == null) continue;

        if (paddr >= range.start && paddr < range.end) {
          final offset = paddr - range.start;
          for (
            var i = 0;
            i < segData.length && offset + i < devData.length;
            i++
          ) {
            devData[offset + i] = segData[i];
          }
          if (ph.memSize > ph.fileSize) {
            final bssStart = offset + ph.fileSize;
            final bssEnd = offset + ph.memSize;
            for (var i = bssStart; i < bssEnd && i < devData.length; i++) {
              devData[i] = 0;
            }
          }
          break;
        }
      }
    }
  }

  Future<void> loadMaskrom(Elf elf, {int? hartId}) async {
    final core = hartId != null
        ? _cores.firstWhere((c) => c.config.hartId == hartId)
        : _cores.first;

    final l1i = core.l1i;
    final l1d = core.l1d;

    if (l1i == null) {
      throw StateError('Cannot load maskrom: core has no L1I cache');
    }

    for (final ph in elf.programHeaders) {
      if (ph.type != 1) continue;
      final data = elf.segmentData(ph);
      if (data.isEmpty) continue;

      final addr = ph.vAddr;

      if ((ph.flags & 0x1) != 0) {
        // Executable: load as instructions into L1I
        var i = 0;
        while (i < data.length) {
          final hw = data[i] | (data[i + 1] << 8);
          if ((hw & 0x3) != 0x3) {
            await l1i.write(addr + i, hw, 2);
            i += 2;
          } else {
            final word = hw | (data[i + 2] << 16) | (data[i + 3] << 24);
            await l1i.write(addr + i, word, 4);
            i += 4;
          }
        }
      } else if (l1d != null) {
        // Data: load into L1D
        for (var i = 0; i < data.length; i++) {
          await l1d.write(addr + i, data[i], 1);
        }
      }
    }
  }

  @override
  String toString() => 'RiverSoC(cores: $cores, devices: $devices)';
}
