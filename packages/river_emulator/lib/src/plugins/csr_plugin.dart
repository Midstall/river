import 'package:river/river.dart';

import '../csr.dart';
import '../mmu.dart';
import 'mmu_plugin.dart';

class CsrPlugin extends FiberPlugin implements CsrContext {
  @override
  final RiverCoreConfig config;

  late final CsrFile csrs;

  @override
  PrivilegeMode mode = PrivilegeMode.machine;

  /// Virtualization bit (H extension). When true the effective mode is the
  /// virtualized form (VS/VU) of [mode]. Always false on a core without H.
  bool virt = false;

  late final Mmu _mmu;

  @override
  Mmu get mmu => _mmu;

  @override
  String get name => 'csr';

  CsrPlugin(this.config);

  void bind(Mmu mmu) {
    _mmu = mmu;
    csrs = CsrFile(
      config.mxlen,
      hasSupervisor: config.hasSupervisor,
      hasUser: config.hasUser,
      hasHypervisor: config.hasHypervisor,
      hasStateen: config.hasStateen,
      rpipelineCap: config.rpipelineCap,
    );
  }

  int read(int address) => csrs.read(address, this);

  void write(int address, int value) => csrs.write(address, value, this);

  void reset() {
    mode = PrivilegeMode.machine;
    virt = false;
    csrs.reset();
  }

  void increment() => csrs.increment();

  @override
  void init() {
    during.setup(() async {
      final mmuPlugin = host.apply<MmuPlugin>();
      bind(mmuPlugin.mmu);
    });
  }

  @override
  Map<String, dynamic> toJson() => {'name': name};
}
