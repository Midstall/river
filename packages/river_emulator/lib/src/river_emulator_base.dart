import 'soc.dart';

class RiverEmulator {
  RiverSoC soc;

  RiverEmulator({required this.soc});

  void reset() {
    soc.reset();
  }

  @override
  String toString() => 'RiverEmulator(soc: $soc)';
}
