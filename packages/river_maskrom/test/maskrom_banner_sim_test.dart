import 'dart:async';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

/// Emulator sim of the xipLaunch maskrom banner: proves the boot ROM brings up
/// the UART and prints its banner before it hands off to the FSBL. The banner
/// runs after the flash warm-up read and before the jalr to the FSBL entry, so
/// the test breaks the instant the full banner lands (it never has to reach a
/// valid FSBL).
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
  test('xipLaunch maskrom prints its banner over the UART', () async {
    const romBase = 0x10000;
    const uartBase = 0x10000000;
    const flashBase = 0x20000000;
    const banner =
        'River maskrom (RC1.f, Delta V1), jumping to FSBL in flash\r\n';
    final config = _rv64(romBase);

    final rom = RiverMaskrom(
      RiverMaskromConfig(
        isa: config.isa,
        resetVector: romBase,
        flashSource: flashBase, // warm-up read window
        copyDest: flashBase, // FSBL entry (never reached: we break on banner)
        copySize: 64,
        stackTop: romBase + 0x8000,
        bootMode: RiverBootMode.xipLaunch,
        bootMessage: banner,
        uartBase: uartBase,
        uartDivisor: 12000000 ~/ 115200,
      ),
    );
    await rom.build();
    final romBytes = rom.generateBinary();

    final romMem = Sram(
      RiverDevice(
        name: 'rom',
        compatible: 'river,sram',
        range: BusAddressRange(romBase, 0x10000),
        clockFrequency: 12000000,
      ),
    );
    // Flash region the warm-up read walks (contents do not matter).
    final flash = Sram(
      RiverDevice(
        name: 'flash',
        compatible: 'river,sram',
        range: BusAddressRange(flashBase, 0x1000),
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

    for (var i = 0; i < romBytes.length; i++) {
      romMem.data[i] = romBytes[i];
    }

    final core = RiverCore(
      config,
      memDevices: Map.fromEntries([romMem.mem!, flash.mem!, uart.mem!]),
    );

    var pc = romBase;
    try {
      for (var i = 0; i < 2000000; i++) {
        final instr = await core.fetch(pc);
        pc = await core.cycle(pc, instr);
        if (String.fromCharCodes(uartOut).contains(banner)) break;
      }
    } on Object {
      // Running off into the (empty) flash after the jalr to the FSBL entry is
      // expected: the banner prints before the handoff, so the capture below
      // is already complete.
    }

    // The emulated UART drains its TX FIFO on async timers, so the final byte
    // can still be in flight when the core stops. Let it settle.
    await uart.flush();

    final out = String.fromCharCodes(uartOut);
    // ignore: avoid_print
    print(
      'maskrom UART: ${out.replaceAll('\r', '\\r').replaceAll('\n', '\\n')}',
    );
    expect(
      out,
      contains(banner),
      reason: 'maskrom did not print its banner; got: $out',
    );
  });
}
