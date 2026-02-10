import 'soc/creek.dart';
import 'soc/stream.dart';

import 'core.dart' show RiverCoreChoice;
import '../river_base.dart';

export 'soc/creek.dart';
export 'soc/stream.dart';

/// Possible choices for River SoC's
enum RiverSoCChoice {
  creek_v1('creek-v1', RiverCoreChoice.rc1_s),
  stream_v1('stream-v1', RiverCoreChoice.rc1_n);

  const RiverSoCChoice(this.name, this.core);

  final String name;
  final RiverCoreChoice core;

  RiverSoC? configure(Map<String, dynamic> options) => switch (this) {
    RiverSoCChoice.creek_v1 => CreekV1SoC.configure(options),
    RiverSoCChoice.stream_v1 => StreamV1SoC.configure(options),
  };

  static RiverSoCChoice? getChoice(String name) {
    for (final choice in RiverSoCChoice.values) {
      if (choice.name == name) return choice;
    }
    return null;
  }
}
