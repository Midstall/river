import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:river_maskrom/river_maskrom.dart';
import 'package:test/test.dart';

/// End-to-end regression for the silent-bundle COPY bug in the PRODUCTION
/// maskrom: it must copy the whole firmware from flash into SRAM (not just the
/// last word to dst[0]) and jump to it. The bug was the ADL dropping the
/// destination-pointer increment in the copy loop. A tiny firmware stores a
/// sentinel to a known SRAM address and spins; we check both that SRAM received
/// the full firmware image AND that the sentinel landed (so the jump ran it).
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
  test('maskrom copies the full firmware to SRAM and jumps to it', () async {
    const romBase = 0x70000000;
    const flashBase = 0x20000000;
    const fwOffset = 0x100000;
    const ramBase = 0x80000000;
    const sentinelAddr = ramBase + 0x4000; // outside the copied image
    const sentinel = 0xdeadbeef;

    final config = _rv64();

    // Tiny position-independent firmware: x5 = sentinelAddr; x6 = sentinel;
    // sw x6,(x5); spin. Hand-assembled RV32/64 (li via lui+addi, sw, jal 0).
    final fwWords = <int>[
      0x80004337, // lui  x6, 0x80004   -> x6 = 0x80004000 (sentinelAddr)
      // addi x6,x6,0 omitted (offset 0)
      0xdeadc2b7, // lui  x5, 0xdeadc   -> x5 = 0xdeadc000
      0xeef28293, // addi x5,x5,-273    -> x5 = 0xdeadbeef (sentinel)
      0x00532023, // sw   x5, 0(x6)     -> mem[sentinelAddr] = sentinel
      0x0000006f, // jal  x0, 0         -> spin
    ];
    final fwBytes = Uint8List(fwWords.length * 4);
    for (var i = 0; i < fwWords.length; i++) {
      fwBytes[i * 4] = fwWords[i] & 0xff;
      fwBytes[i * 4 + 1] = (fwWords[i] >> 8) & 0xff;
      fwBytes[i * 4 + 2] = (fwWords[i] >> 16) & 0xff;
      fwBytes[i * 4 + 3] = (fwWords[i] >> 24) & 0xff;
    }

    final rom = RiverMaskrom(
      RiverMaskromConfig(
        isa: config.isa,
        resetVector: romBase,
        flashSource: flashBase + fwOffset,
        copyDest: ramBase,
        copySize: (fwBytes.length + 3) & ~3,
        stackTop: ramBase + 0x8000,
      ),
    );
    await rom.build();
    final romBytes = rom.generateBinary();

    final romMem = Sram(
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

    for (var i = 0; i < romBytes.length; i++) {
      romMem.data[i] = romBytes[i];
    }
    for (var i = 0; i < fwBytes.length; i++) {
      flash.data[fwOffset + i] = fwBytes[i];
    }

    final core = RiverCore(
      config,
      memDevices: Map.fromEntries([romMem.mem!, flash.mem!, sram.mem!]),
    );

    var pc = romBase;
    var spun = false;
    for (var i = 0; i < 200000; i++) {
      final instr = await core.fetch(pc);
      final next = await core.cycle(pc, instr);
      if (next == pc) {
        spun = true;
        break;
      }
      pc = next;
    }

    // Firmware image must be byte-for-byte in SRAM.
    for (var i = 0; i < fwBytes.length; i++) {
      expect(
        sram.data[i],
        equals(fwBytes[i]),
        reason: 'SRAM[$i] != firmware[$i] (copy dropped bytes)',
      );
    }
    // The jump ran the firmware: the sentinel landed.
    final off = sentinelAddr - ramBase;
    final got =
        sram.data[off] |
        (sram.data[off + 1] << 8) |
        (sram.data[off + 2] << 16) |
        (sram.data[off + 3] << 24);
    expect(
      got,
      equals(sentinel),
      reason: 'sentinel not written -> maskrom never jumped into the copy',
    );
    expect(spun, isTrue, reason: 'firmware never reached its spin loop');
  });
}
