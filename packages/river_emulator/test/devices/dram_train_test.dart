import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// The emulator DRAM read-training model: the array is unusable until the read
/// tap is walked into the valid eye via the MMIO control window, so a BIOS
/// training sweep is testable in the emulator. Mirrors the HDL
/// HarborDdrController trainable path. See project_ddr_training.
void main() {
  const arraySize = 0x1000;
  const ctrlSize = Dram.trainCtrlSize; // 0x1000
  const eyeLo = 8, eyeHi = 40;

  // Control-window register offsets (relative to the device base).
  const rdtap = arraySize + 0x00;
  const ctl = arraySize + 0x08;
  const rdslack = arraySize + 0x10;
  const status = arraySize + 0x18;
  const setBit = 0x1, loadBit = 0x2;

  Dram makeDram() => Dram(
    const RiverDevice(
      name: 'dram',
      compatible: 'river,dram',
      range: BusAddressRange(0x80000000, arraySize + ctrlSize),
    ),
    trainable: true,
    eyeLo: eyeLo,
    eyeHi: eyeHi,
  );

  test('untrained array reads return garbage; in-eye tap fixes it', () async {
    final d = makeDram();
    final acc = d.memAccessor!;

    // Write a pattern (writes always land, even untrained).
    await acc.write(0x100, 0xDEADBEEF, 4);

    // Untrained (tap 0, below the eye): read is corrupted.
    expect(await acc.read(0x100, 4), isNot(0xDEADBEEF));

    // Train: target tap 20 (in the eye), pulse SET.
    await acc.write(rdtap, 20, 4);
    await acc.write(ctl, setBit, 4);

    // Now the array reads correctly.
    expect(await acc.read(0x100, 4), 0xDEADBEEF);
    // STATUS reports the current tap in bits [8:1], busy (bit0) clear.
    expect(await acc.read(status, 4), 20 << 1);
  });

  test('a tap outside the eye corrupts reads again', () async {
    final d = makeDram();
    final acc = d.memAccessor!;
    await acc.write(0x200, 0xCAFEF00D, 4);

    // In-eye -> good.
    await acc.write(rdtap, eyeHi, 4);
    await acc.write(ctl, setBit, 4);
    expect(await acc.read(0x200, 4), 0xCAFEF00D);

    // One past the eye -> garbage.
    await acc.write(rdtap, eyeHi + 1, 4);
    await acc.write(ctl, setBit, 4);
    expect(await acc.read(0x200, 4), isNot(0xCAFEF00D));
  });

  test('LOAD resets the tap to 0 (out of eye)', () async {
    final d = makeDram();
    final acc = d.memAccessor!;
    await acc.write(0x10, 0x12345678, 4);
    await acc.write(rdtap, 16, 4);
    await acc.write(ctl, setBit, 4);
    expect(await acc.read(0x10, 4), 0x12345678);

    await acc.write(ctl, loadBit, 4);
    expect(await acc.read(status, 4), 0); // tap back to 0
    expect(await acc.read(0x10, 4), isNot(0x12345678));
  });

  test('RDSLACK round-trips through the control window', () async {
    final d = makeDram();
    final acc = d.memAccessor!;
    await acc.write(rdslack, 3, 4);
    expect(await acc.read(rdslack, 4), 3);
  });

  test('a sweep finds the eye (the BIOS training algorithm)', () async {
    final d = makeDram();
    final acc = d.memAccessor!;
    const probe = 0xA5A5A5A5;
    await acc.write(0x000, probe, 4);

    // Sweep every tap, recording which ones read the pattern back correctly.
    final good = <int>[];
    for (var tap = 0; tap < 128; tap++) {
      await acc.write(rdtap, tap, 4);
      await acc.write(ctl, setBit, 4);
      if (await acc.read(0x000, 4) == probe) good.add(tap);
    }

    // The contiguous good window is exactly the configured eye.
    expect(good.first, eyeLo);
    expect(good.last, eyeHi);
    expect(good.length, eyeHi - eyeLo + 1);
  });

  test(
    'untrainable DRAM ignores the control window and is always reliable',
    () async {
      final d = Dram(
        const RiverDevice(
          name: 'dram',
          compatible: 'river,dram',
          range: BusAddressRange(0x80000000, arraySize),
        ),
      );
      final acc = d.memAccessor!;
      await acc.write(0x40, 0x99887766, 4);
      expect(await acc.read(0x40, 4), 0x99887766); // no training needed
    },
  );
}
