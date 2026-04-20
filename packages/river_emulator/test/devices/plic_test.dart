import 'dart:async';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import '../constants.dart';

void main() {
  cpuTests('PLIC Device', (config) {
    late Sram sram;
    late Plic plic;
    late RiverCore core;

    const plicAddr = 0x40000;

    setUp(() {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: (config.clock.rate as HarborFixedClockRate).frequency,
        ),
      );

      plic = Plic(
        RiverDevice(
          name: 'plic',
          compatible: 'riscv,plic0',
          range: BusAddressRange(plicAddr, 0x4000000),
          interrupts: [0],
          clockFrequency: (config.clock.rate as HarborFixedClockRate).frequency,
        ),
        numSources: 8,
      );

      core = RiverCore(
        config,
        memDevices: Map.fromEntries([sram.mem!, plic.mem!]),
      );
    });

    Future<void> writeWord(int addr, int val) => core.mmu.write(addr, val, 4);

    Future<int> readWord(int addr) => core.mmu.read(addr, 4);

    test('No interrupt when pending=0', () {
      final irq = plic.interrupts(0)[0];
      expect(irq, isFalse);
    });

    test('Interrupt does not fire unless enabled', () {
      plic.setSourcePending(1, true);
      expect(plic.interrupts(0)[0], isFalse);
    });

    test('Interrupt fires when pending AND enabled', () async {
      await writeWord(plicAddr + 0x4, 1);
      await writeWord(plicAddr + 0x2000, 1 << 1);
      await writeWord(plicAddr + 0x200000, 0);

      plic.setSourcePending(1, true);

      expect(plic.interrupts(0)[0], isTrue);
    });

    test('Claim returns correct ID and clears pending', () async {
      await writeWord(plicAddr + 0x4, 1);
      await writeWord(plicAddr + 0x2000, 1 << 1);
      await writeWord(plicAddr + 0x200000, 0);

      // Assert interrupt
      plic.setSourcePending(1, true);
      expect(plic.interrupts(0)[0], isTrue);

      final id = await readWord(plicAddr + 0x200004);
      expect(id, 1);

      final pending = await readWord(plicAddr + 0x1000);
      expect((pending & (1 << 1)) != 0, isFalse);

      expect(plic.interrupts(0)[0], isFalse);
    });

    test('Threshold blocks lower priority interrupts', () async {
      await writeWord(plicAddr + 0x4, 1);
      await writeWord(plicAddr + 0x2000, 1 << 1);
      await writeWord(plicAddr + 0x200000, 2);

      plic.setSourcePending(1, true);
      expect(plic.interrupts(0)[0], isFalse);
    });

    test('Higher priority interrupt wins', () async {
      await writeWord(plicAddr + 0x4, 1);

      plic.setPriority(2, 3);

      await writeWord(plicAddr + 0x2000, (1 << 1) | (1 << 2));
      await writeWord(plicAddr + 0x200000, 0);

      plic.setSourcePending(1, true);
      plic.setSourcePending(2, true);

      expect(await readWord(plicAddr + 0x200004), 2);
    });
  });
}
