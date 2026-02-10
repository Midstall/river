import 'impl/core.dart';
import 'impl/soc.dart';
import 'river_base.dart';

export 'impl/core.dart';
export 'impl/devices.dart';
export 'impl/soc.dart';

enum RiverPlatformChoice {
  alpha('alpha', RiverSoCChoice.creek_v1),
  icesugar('icesugar', RiverSoCChoice.stream_v1);

  const RiverPlatformChoice(this.name, this.soc);

  final String name;
  final RiverSoCChoice soc;

  RiverCoreChoice get core => soc.core;

  RiverSoC? configureSoC(Map<String, dynamic> options) =>
      soc.configure({...options, 'platform': name});

  static RiverPlatformChoice? getChoice(String name) {
    for (final choice in RiverPlatformChoice.values) {
      if (choice.name == name) return choice;
    }
    return null;
  }
}
