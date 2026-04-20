import 'package:river/river.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

RiverCoreConfig _cfg() => RiverCoreConfigV1.micro(
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
  resetVector: 0x80000000,
);

void main() {
  test(
    'RiverDdrLevelXilinx generates a non-empty position-independent ROM',
    () async {
      final prog = RiverDdrLevelXilinx(
        isa: _cfg().isa,
        uartBase: 0x10000000,
        dramBase: 0x80000000,
        // Train-control window sits just above a 256M DRAM array (non-DRAM MMIO).
        trainCtrlBase: 0x80000000 + 0x10000000,
      );
      await prog.build();
      final bytes = prog.generateBytes();
      // Non-trivial (the leveling loops are runtime, not Dart-unrolled, so the ROM
      // stays small but is clearly more than the UART setup).
      expect(bytes.length, greaterThan(200));
      // ROM-fit guard (unroll-romfit lesson: stay well under the boot-ROM budget).
      expect(bytes.length, lessThan(8192));
    },
  );
}
