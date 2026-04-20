import 'dart:async';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

/// Emulator sim of the [RiverTrapWfiTest] boot program: proves the program
/// STRUCTURE is sound (the jal-over landing pad, and MRET redirecting to
/// romBase+4) independent of any FPGA. The emulator halts on WFI (idle), so it
/// stops after "CREEK M R "; the WFI NOP-advance itself is covered by the HDL
/// core_wfi_test. Seeing "R" proves MRET landed at mepc.
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
  test('trapwfi boot program: core runs + MRET lands (emulator)', () async {
    const romBase = 0x10000;
    const uartBase = 0x10000000;
    final config = _rv64(romBase);

    final prog = RiverTrapWfiTest(
      isa: config.isa,
      uartBase: uartBase,
      romBase: romBase,
      clockHz: 12000000,
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
      memDevices: Map.fromEntries([romMem.mem!, uart.mem!]),
    );

    var pc = romBase;
    for (var i = 0; i < 2000000; i++) {
      final instr = await core.fetch(pc);
      pc = await core.cycle(pc, instr);
      final s = String.fromCharCodes(uartOut);
      if (s.contains('R ')) break; // MRET landed
    }

    final out = String.fromCharCodes(uartOut);
    // ignore: avoid_print
    print(
      'trapwfi emulator UART: ${out.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}',
    );
    expect(out, contains('CREEK'), reason: 'core did not run; got: $out');
    expect(out, contains('M '), reason: 'never reached MRET; got: $out');
    expect(
      out,
      contains('R '),
      reason: 'MRET did not land at mepc (still looping?); got: $out',
    );
    expect(
      out,
      isNot(contains('MFAIL')),
      reason: 'MRET fell through instead of redirecting; got: $out',
    );
  });
}
