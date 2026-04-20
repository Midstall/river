import 'package:river/river.dart';
import '../dev.dart';
import '../soc.dart';

class Sram extends Device {
  List<int> data;

  Sram(super.config) : data = List.filled(config.range!.size, 0);

  @override
  void reset() {
    data.fillRange(0, data.length, 0);
  }

  @override
  DeviceAccessor? get memAccessor => SramAccessor(this);

  @override
  String toString() => 'Sram(config: $config)';

  static Device create(
    RiverDevice config,
    Map<String, String> options,
    RiverSoC soc,
  ) => Sram(config);
}

class SramAccessor extends DeviceAccessor {
  final Sram sram;

  SramAccessor(this.sram);

  @override
  Future<int> read(int addr, int width) {
    int value = sram.data
        .getRange(addr, addr + width)
        .toList()
        .reversed
        .fold(0, (v, i) => (v << 8) | (i & 0xFF));
    return Future.value(value);
  }

  @override
  Future<void> write(int addr, int value, int width) async {
    for (int i = 0; i < width; i++) {
      final byte = (value >> (8 * i)) & 0xFF;
      sram.data[addr + i] = byte;
    }
  }
}
