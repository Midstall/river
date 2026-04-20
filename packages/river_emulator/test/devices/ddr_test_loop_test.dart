import 'dart:async';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

/// Runs the looping [RiverDdrTest] straight from ROM against a WORKING DRAM
/// (a plain Sram) in the emulator and captures the UART. With sound storage the
/// verdict must be a clean, REPEATED "DDR OK" - this validates the looping
/// program's control flow (the hardware-readout fix) independently of any real
/// DDR PHY, so a garbled/ER result on silicon can be attributed to hardware.
RiverCoreConfig _rv64(int romBase) => RiverCoreConfigV1.small(
  mmu: HarborMmuConfig(
    mxlen: RiscVMxlen.rv64,
    pagingModes: const [RiscVPagingMode.bare, RiscVPagingMode.sv39],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
    hasSupervisorUserMemory: true,
    hasMakeExecutableReadable: true,
  ),
  interrupts: [],
  clock: const HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(12000000),
  ),
  resetVector: romBase,
);

void main() {
  test(
    'looping RiverDdrTest prints repeated clean "DDR OK" on good DRAM',
    () async {
      const romBase = 0x10000;
      const dramBase = 0x80000000;
      const uartBase = 0x10000000;
      final config = _rv64(romBase);

      final prog = RiverDdrTest(
        isa: config.isa,
        uartBase: uartBase,
        dramBase: dramBase,
        clockHz: 12000000,
        loopForever: true,
      );
      await prog.build();
      final progBytes = prog.generateBinary();

      final romMem = Sram(
        RiverDevice(
          name: 'rom',
          compatible: 'river,sram',
          range: BusAddressRange(romBase, 0x10000),
          clockFrequency: 12000000,
        ),
      );
      final dram = Sram(
        RiverDevice(
          name: 'dram',
          compatible: 'river,sram',
          range: BusAddressRange(dramBase, 0x8000000),
          clockFrequency: 12000000,
        ),
      );
      final uartOut = <int>[];
      final outCtl = StreamController<List<int>>(sync: true);
      final inCtl = StreamController<List<int>>(sync: true);
      outCtl.stream.listen(uartOut.addAll);
      final uart = Uart(
        RiverDevice(
          name: 'uart0',
          compatible: 'ns16550a',
          range: BusAddressRange(uartBase, 0x1000),
          interrupts: [0],
          clockFrequency: 12000000,
        ),
        input: inCtl.stream,
        output: outCtl.sink,
      );

      for (var i = 0; i < progBytes.length; i++) {
        romMem.data[i] = progBytes[i];
      }

      final core = RiverCore(
        config,
        memDevices: Map.fromEntries([romMem.mem!, dram.mem!, uart.mem!]),
      );

      var pc = romBase;
      for (var i = 0; i < 2000000; i++) {
        final instr = await core.fetch(pc);
        pc = await core.cycle(pc, instr);
        // Stop once we have caught at least two verdict lines.
        final s = String.fromCharCodes(uartOut);
        if ('DDR OK'.allMatches(s).length >= 2) break;
      }

      final out = String.fromCharCodes(uartOut);
      expect(out, contains('DDR OK'), reason: 'output was: ${out.codeUnits}');
      expect(out, isNot(contains('DDR ER')), reason: 'got: $out');
      // Looping must produce more than one copy.
      expect(
        'DDR OK'.allMatches(out).length,
        greaterThanOrEqualTo(2),
        reason: 'looping should repeat the verdict; got: $out',
      );
    },
  );
}
