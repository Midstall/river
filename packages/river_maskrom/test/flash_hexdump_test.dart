import 'dart:async';

import 'package:bintools/bintools.dart';
import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

RiverCoreConfig _microConfig() => RiverCoreConfigV1.micro(
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
  resetVector: 0x80000000,
);

void main() {
  group('RiverFlashHexdump', () {
    test('emits a non-empty binary with the UART and flash bases', () async {
      final fw = RiverFlashHexdump(
        isa: _microConfig().isa,
        uartBase: 0x10000000,
        flashBase: 0x20000000,
        clockHz: 12000000,
      );
      await fw.build();
      final bin = fw.generateBytes();
      expect(bin, isNotEmpty);

      final asm = fw.generateAssembly();
      // UART setup, flash read, hex-dump control flow.
      expect(asm, contains('lbu'));
      expect(asm, contains('sb'));
      expect(asm, contains('andi'));
      expect(asm, contains('srli'));
      expect(asm, contains('bne'));

      // A valid ELF can wrap it for the sim path.
      final elf = Elf.load(fw.emitElfBytes(entryPoint: 0x80000000));
      expect(elf.header.entry, 0x80000000);
    });

    test('dumps flash bytes over the UART as a hex dump', () async {
      // Run the firmware in the emulator from SRAM, reading a small flash
      // window, and check the streamed hex dump.
      const flashBase = 0x20000000;
      const uartBase = 0x10000000;
      const ramBase = 0x80000000;
      const dumpBytes = 32; // 2 lines, keeps the cycle count modest.

      final config = _microConfig();
      final fw = RiverFlashHexdump(
        isa: config.isa,
        uartBase: uartBase,
        flashBase: flashBase,
        dumpBytes: dumpBytes,
        clockHz: 10000,
        baud: 1250, // divisor 8: non-zero so TX drains quickly in sim
      );
      await fw.build();
      final bin = fw.generateBytes();

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

      // The firmware executes from SRAM (the bundled-flash path: maskrom copied
      // it here). Load it at ramBase.
      for (var i = 0; i < bin.length; i++) {
        sram.data[i] = bin[i];
      }

      // Known flash contents: a recognizable ramp so we can check the hex.
      for (var i = 0; i < dumpBytes; i++) {
        flash.data[i] = i & 0xff;
      }

      final core = RiverCore(
        config,
        memDevices: Map.fromEntries([flash.mem!, sram.mem!, uart.mem!]),
      );

      var pc = ramBase;
      for (var i = 0; i < 200000; i++) {
        final instr = await core.fetch(pc);
        final next = await core.cycle(pc, instr);
        // The firmware spins on itself at the end (jal done): detect the
        // self-loop and stop.
        if (next == pc) break;
        pc = next;
      }

      await uart.flush();
      await Future<void>.delayed(Duration.zero);

      final text = String.fromCharCodes(uartOutput);
      // First line: offset 00000000, bytes 00..0f.
      expect(
        text,
        contains('00000000: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f'),
      );
      // Second line: offset 00000010, bytes 10..1f.
      expect(
        text,
        contains('00000010: 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f'),
      );
      expect(text, contains('DUMP DONE'));
    });

    test('dumps two regions with headers (SILENT bring-up probe)', () async {
      // The diagnostic probe: dump two flash windows in one boot, each with its
      // own header. Region A = a known pattern at the flash base; region B = a
      // different known pattern 0x100000 above it. This proves the probe logic
      // before silicon. Both windows are read by lbu XIP from flash.
      const flashBase = 0x20000000;
      const uartBase = 0x10000000;
      const ramBase = 0x80000000;
      const regionBLen = 16; // one line, keeps the cycle count modest.
      const regionAOffset = 0x0;
      const regionBOffset = 0x100000;

      final config = _microConfig();
      final fw = RiverFlashHexdump(
        isa: config.isa,
        uartBase: uartBase,
        flashBase: flashBase,
        clockHz: 10000,
        baud: 1250, // divisor 8: non-zero so TX drains quickly in sim
        regions: [
          // Region A: a 16-byte window with an ascending ramp (stand-in for the
          // ECP5 bitstream preamble).
          HexdumpRegion(base: flashBase, length: 16, header: 'FLASH @0:'),
          // Region B: a 16-byte window at +0x100000 with a 0xa? pattern
          // (stand-in for the firmware slot).
          HexdumpRegion(
            base: flashBase + regionBOffset,
            length: regionBLen,
            header: 'FLASH @100000:',
          ),
        ],
      );
      await fw.build();
      final bin = fw.generateBytes();

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

      // The probe executes from SRAM here (in the real bitstream it runs from
      // the boot ROM); load it at ramBase.
      for (var i = 0; i < bin.length; i++) {
        sram.data[i] = bin[i];
      }

      // Region A pattern: an ascending ramp at flash offset 0.
      for (var i = 0; i < 16; i++) {
        flash.data[regionAOffset + i] = i & 0xff;
      }
      // Region B pattern: 0xa0 | i at flash offset 0x100000 (distinct from A).
      for (var i = 0; i < regionBLen; i++) {
        flash.data[regionBOffset + i] = (0xa0 | i) & 0xff;
      }

      final core = RiverCore(
        config,
        memDevices: Map.fromEntries([flash.mem!, sram.mem!, uart.mem!]),
      );

      var pc = ramBase;
      for (var i = 0; i < 400000; i++) {
        final instr = await core.fetch(pc);
        final next = await core.cycle(pc, instr);
        if (next == pc) break; // self-loop at the end (jal done)
        pc = next;
      }

      await uart.flush();
      await Future<void>.delayed(Duration.zero);

      final text = String.fromCharCodes(uartOutput);
      // Region A header + its bytes.
      expect(text, contains('FLASH @0:'));
      expect(
        text,
        contains('00000000: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f'),
      );
      // Region B header + its bytes (distinct pattern).
      expect(text, contains('FLASH @100000:'));
      expect(
        text,
        contains('00000000: a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 aa ab ac ad ae af'),
      );
      // Header A must precede header B in the stream.
      expect(
        text.indexOf('FLASH @0:') < text.indexOf('FLASH @100000:'),
        isTrue,
      );
      expect(text, contains('DUMP DONE'));
    });
  });
}
