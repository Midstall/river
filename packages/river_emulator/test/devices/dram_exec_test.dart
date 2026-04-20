import 'dart:async';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

/// Validates [RiverDramExec]'s logic functionally: it must print "DEXEC", copy
/// its banner stub into DRAM (a plain Sram here), jalr into it, and then stream
/// "DRAM EXEC OK" from code running IN DRAM. If this passes in the emulator but
/// the same program goes silent after "DEXEC" on real silicon, the copy+jump is
/// sound and the hardware fetch-from-DRAM path is the suspect, not the program.
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
    'RiverDramExec copies a stub into DRAM and executes it from there',
    () async {
      const romBase = 0x10000;
      const dramBase = 0x80000000;
      const uartBase = 0x10000000;
      final config = _rv64(romBase);

      final stub = RiverHelloWorld(
        isa: config.isa,
        uartBase: uartBase,
        ramBase: dramBase + 0x10000,
        clockHz: 12000000,
        message: 'DRAM EXEC OK\r\n',
        loop: true,
      );
      await stub.build();

      final prog = RiverDramExec(
        isa: config.isa,
        uartBase: uartBase,
        dramBase: dramBase,
        clockHz: 12000000,
        stubBytes: stub.generateBinary(),
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
      for (var i = 0; i < 4000000; i++) {
        final instr = await core.fetch(pc);
        pc = await core.cycle(pc, instr);
        final s = String.fromCharCodes(uartOut);
        if ('DRAM EXEC OK'.allMatches(s).length >= 2) break;
      }

      final out = String.fromCharCodes(uartOut);
      expect(out, contains('DEXEC'), reason: 'boot ROM program must run: $out');
      expect(
        out,
        contains('DRAM EXEC OK'),
        reason: 'stub must execute FROM DRAM; got: ${out.codeUnits}',
      );
    },
  );
}
