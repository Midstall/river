import 'package:harbor/harbor.dart' hide PrivilegeMode;
import 'package:river/river.dart';

import '../dev.dart';
import '../mmu.dart';

class MmuPlugin extends FiberPlugin {
  final HarborMmuConfig mmuConfig;
  final Map<BusAddressRange, DeviceAccessor> memDevices;

  late final Mmu mmu;

  @override
  String get name => 'mmu';

  MmuPlugin(this.mmuConfig, this.memDevices);

  void reset() => mmu.reset();

  @override
  void init() {
    during.setup(() async {
      mmu = Mmu(mmuConfig, memDevices);
    });
  }

  @override
  Map<String, dynamic> toJson() => {'name': name};
}
