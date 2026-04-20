import 'dart:async';

import 'package:bintools/bintools.dart';
import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

/// Reproduce the silent-bundle COPY bug in the emulator. The HDL flash-read bug
/// is fixed (the on-hardware probe now dumps dense flash), but the maskrom's
/// flash->SRAM copy left SRAM all-zero except word0 (= the firmware's trailing
/// `jal`), i.e. the destination pointer never advanced. The emulator models the
/// flash as perfect memory, so if the COPY LOOP the ADL emits is broken this
/// test reproduces it (SRAM holds only word0); if the copy is correct here, the
/// fault is HDL-core lw/sw lane handling instead.
RiverCoreConfig _rv64() => RiverCoreConfigV1.micro(
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
  resetVector: 0x70000000,
);

void main() {
  test('bundleselftest copy lands the whole firmware in SRAM', () async {
    const romBase = 0x70000000; // selftest runs from here
    const flashBase = 0x20000000;
    const fwOffset = 0x100000;
    const uartBase = 0x10000000;
    const ramBase = 0x80000000;

    final config = _rv64();

    // The firmware that gets copied (and its length -> copyWords).
    final fw = RiverFlashHexdump(
      isa: config.isa,
      uartBase: uartBase,
      flashBase: flashBase,
      dumpBytes: 16,
      clockHz: 10000,
      baud: 1250,
    );
    await fw.build();
    final fwBytes = fw.generateBytes();
    final copyWords = (fwBytes.length + 3) >> 2;

    final probe = RiverBundleSelfTest(
      isa: config.isa,
      uartBase: uartBase,
      flashSource: flashBase + fwOffset,
      copyDest: ramBase,
      copyWords: copyWords,
      probeBytes: 32,
      clockHz: 10000,
      baud: 1250,
    );
    await probe.build();
    final probeBytes = probe.generateBytes();

    final rom = Sram(
      RiverDevice(
        name: 'rom',
        compatible: 'river,sram',
        range: BusAddressRange(romBase, 0x10000),
        clockFrequency: 10000,
      ),
    );
    final flash = Sram(
      RiverDevice(
        name: 'flash',
        compatible: 'river,sram',
        range: BusAddressRange(flashBase, 0x200000),
        clockFrequency: 10000,
      ),
    );
    final sram = Sram(
      RiverDevice(
        name: 'sram',
        compatible: 'river,sram',
        range: BusAddressRange(ramBase, 0x10000),
        clockFrequency: 10000,
      ),
    );

    final outputController = StreamController<List<int>>(sync: true);
    final inputController = StreamController<List<int>>(sync: true);
    final uartOutput = <int>[];
    outputController.stream.listen(uartOutput.addAll);
    final uart = Uart(
      RiverDevice(
        name: 'uart0',
        compatible: 'ns16550a',
        range: BusAddressRange(uartBase, 0x100),
        interrupts: [0],
        clockFrequency: 10000,
      ),
      input: inputController.stream,
      output: outputController.sink,
    );

    // selftest in ROM, firmware in flash at fwOffset.
    for (var i = 0; i < probeBytes.length; i++) {
      rom.data[i] = probeBytes[i];
    }
    for (var i = 0; i < fwBytes.length; i++) {
      flash.data[fwOffset + i] = fwBytes[i];
    }

    final core = RiverCore(
      config,
      memDevices: Map.fromEntries([rom.mem!, flash.mem!, sram.mem!, uart.mem!]),
    );

    var pc = romBase;
    for (var i = 0; i < 2000000; i++) {
      final instr = await core.fetch(pc);
      final next = await core.cycle(pc, instr);
      if (next == pc) break; // hit a spin (firmware's jal done, or trap)
      pc = next;
    }
    await uart.flush();
    await Future<void>.delayed(Duration.zero);

    // Check the SRAM the copy produced, directly (independent of UART parsing).
    final fw0 =
        fwBytes[0] |
        (fwBytes[1] << 8) |
        (fwBytes[2] << 16) |
        (fwBytes[3] << 24);
    final sr0 =
        sram.data[0] |
        (sram.data[1] << 8) |
        (sram.data[2] << 16) |
        (sram.data[3] << 24);
    final fw4 =
        fwBytes[4] |
        (fwBytes[5] << 8) |
        (fwBytes[6] << 16) |
        (fwBytes[7] << 24);
    final sr4 =
        sram.data[4] |
        (sram.data[5] << 8) |
        (sram.data[6] << 16) |
        (sram.data[7] << 24);
    // ignore: avoid_print
    print(
      'fw[0]=0x${fw0.toRadixString(16)} sram[0]=0x${sr0.toRadixString(16)} '
      'fw[4]=0x${fw4.toRadixString(16)} sram[4]=0x${sr4.toRadixString(16)}',
    );

    expect(sr0, equals(fw0), reason: 'SRAM word0 != firmware word0 (copy bug)');
    expect(
      sr4,
      equals(fw4),
      reason: 'SRAM word1 == 0 -> dst pointer never advanced (copy bug)',
    );
  });
}
