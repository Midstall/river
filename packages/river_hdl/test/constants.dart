import 'package:river/river.dart';
import 'package:test/test.dart';

final kCpuConfigs = <String, RiverCoreConfig>{
  'RC1.n': RiverCoreConfigV1.nano(
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv32,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  ),
  'RC1.mi': RiverCoreConfigV1.micro(
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv32,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  ),
  'RC1.s': RiverCoreConfigV1.small(
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  ),
};

void cpuTests(
  String name,
  dynamic Function(RiverCoreConfig) body, {
  bool Function(RiverCoreConfig)? condition,
}) {
  for (final entry in kCpuConfigs.entries) {
    if (condition != null) {
      if (!condition(entry.value)) continue;
    }
    group('${entry.key} - $name', () => body(entry.value));
  }
}
