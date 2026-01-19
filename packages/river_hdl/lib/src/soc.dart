import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'core.dart';
import 'dev.dart';
import 'devices.dart';

class RiverSoCIP extends BridgeModule {
  final RiverSoC config;

  RiverSoCIP(
    this.config, {
    Map<String, Map<String, String>> deviceOptions = const {},
    Map<String, DeviceModuleFactory> deviceFactory = kDeviceModuleFactory,
    List<String> staticInstructions = const [],
  }) : super('RiverSoC') {
    createPort('reset', PortDirection.input);

    final reset = port('reset');

    for (final clk in config.clocks) {
      createPort('clk_${clk.name}', PortDirection.input);
    }

    for (final port in config.ports) {
      createPort(
        port.name,
        port.isOutput ? PortDirection.output : PortDirection.input,
        width: port.width,
      );
    }

    final mxlen = config.cores.first.mxlen;

    List<DeviceModule> devices = [];

    for (final entry in config.devices.indexed) {
      final index = entry.$1;
      final devConfig = entry.$2;

      final dev = addSubModule(
        deviceFactory.containsKey(devConfig.compatible)
            ? deviceFactory[devConfig.compatible]!(
                mxlen,
                devConfig,
                deviceOptions[devConfig.name] ?? {},
              )
            : DeviceModule(mxlen, devConfig),
      );
      devices.add(dev);

      connectPorts(reset, dev.port('reset'));

      if (devConfig.clock != null) {
        final clk = port('clk_${devConfig.clock!.name}');
        connectPorts(clk, dev.port('clk'));
      }

      for (final p in devConfig.ports) {
        final host = config.ports.firstWhere(
          (h) => h.devices[devConfig.name] == p.name,
        );

        if (p.isOutput)
          connectPorts(dev.port(p.name), port(host.name));
        else
          connectPorts(port(host.name), dev.port(p.name));
      }
    }

    for (final coreConfig in config.cores) {
      final clk = port('clk_${coreConfig.clock.name}');

      final core = addSubModule(
        RiverCoreIP(coreConfig, staticInstructions: staticInstructions),
      );

      connectPorts(clk, core.port('clk'));
      connectPorts(reset, core.port('reset'));

      for (final entry in coreConfig.mmu.blocks.indexed) {
        final index = entry.$1;
        final block = entry.$2;

        final dev = devices.firstWhere(
          (dev) => dev.config.accessor?.path == block.accessor.path,
        );

        if (dev.config.range == null) continue;

        connectInterfaces(
          core.interface('mmioRead$index'),
          dev.interface('mmioRead'),
        );
        connectInterfaces(
          core.interface('mmioWrite$index'),
          dev.interface('mmioWrite'),
        );
      }
    }
  }
}
