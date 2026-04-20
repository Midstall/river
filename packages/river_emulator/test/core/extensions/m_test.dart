import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import '../../constants.dart';

void main() {
  cpuTests('M extension', (config) {
    late Sram sram;
    late RiverCore core;
    late int pc;

    setUp(() {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: (config.clock.rate as HarborFixedClockRate).frequency,
        ),
      );

      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
      pc = config.resetVector;
    });

    test('mul multiplies two registers', () async {
      core.xregs[Register.x5] = 6;
      core.xregs[Register.x6] = 7;

      final mul = 0x025303b3;
      await core.cycle(pc, mul);

      expect(core.xregs[Register.x7], 42);
    });

    test('mulh high part is zero for small operands', () async {
      core.xregs[Register.x5] = 1234;
      core.xregs[Register.x6] = 5678;

      final mulh = 0x025313b3;
      await core.cycle(pc, mulh);

      expect(core.xregs[Register.x7], 0);
    });

    test('div signed division truncates toward zero', () async {
      core.xregs[Register.x5] = 3;
      core.xregs[Register.x6] = -7;

      final div = 0x025343b3;
      await core.cycle(pc, div);

      expect(core.xregs[Register.x7], -2);
    });

    test('rem signed remainder has same sign as dividend', () async {
      core.xregs[Register.x5] = 3;
      core.xregs[Register.x6] = -7;

      final rem = 0x025363b3;
      await core.cycle(pc, rem);

      expect(core.xregs[Register.x7], -1);
    });

    test('divu unsigned division', () async {
      core.xregs[Register.x5] = 3;
      core.xregs[Register.x6] = 7;

      final divu = 0x025353b3;
      await core.cycle(pc, divu);

      expect(core.xregs[Register.x7], 2);
    });

    test('remu unsigned remainder', () async {
      core.xregs[Register.x5] = 3;
      core.xregs[Register.x6] = 7;

      final remu = 0x025373b3;
      await core.cycle(pc, remu);

      expect(core.xregs[Register.x7], 1);
    });

    test('div by zero returns -1 (all ones)', () async {
      core.xregs[Register.x5] = 0;
      core.xregs[Register.x6] = 123;

      final div = 0x025343b3;
      await core.cycle(pc, div);

      expect(core.xregs[Register.x7], -1);
    });

    test('divu by zero returns all ones (-1)', () async {
      core.xregs[Register.x5] = 0;
      core.xregs[Register.x6] = 123;

      final divu = 0x025353b3;
      await core.cycle(pc, divu);

      // All-ones in the emulator's Dart-int convention: toSigned(64) maps the
      // 64-bit all-ones to -1 and leaves the 32-bit value (4294967295) positive.
      // (Plain .toInt() would clamp the 64-bit value to maxInt - that was a bug.)
      expect(
        core.xregs[Register.x7],
        ((BigInt.one << config.mxlen.size) - BigInt.one).toSigned(64).toInt(),
      );
    });

    test('rem/div by zero leaves remainder equal to dividend', () async {
      core.xregs[Register.x5] = 0;
      core.xregs[Register.x6] = -42;

      final rem = 0x025363b3;
      await core.cycle(pc, rem);

      expect(core.xregs[Register.x7], -42);
    });

    if (config.mxlen == RiscVMxlen.rv64) {
      test('mulw uses 32-bit product and sign-extends to XLEN', () async {
        core.xregs[Register.x5] = 2;
        core.xregs[Register.x6] = 0x00000000FFFFFFFF;

        final mulw = 0x025303bb;
        await core.cycle(pc, mulw);

        expect(core.xregs[Register.x7], -2);
      });

      test('divw truncates toward zero and sign-extends', () async {
        core.xregs[Register.x5] = 2;
        core.xregs[Register.x6] = -7;

        final divw = 0x025343bb;
        await core.cycle(pc, divw);

        expect(core.xregs[Register.x7], -3);
      });

      test(
        'remw has remainder with sign of dividend and sign-extends',
        () async {
          core.xregs[Register.x5] = 2;
          core.xregs[Register.x6] = -7;

          final remw = 0x025363bb;
          await core.cycle(pc, remw);

          expect(core.xregs[Register.x7], -1);
        },
      );

      test('divuw uses unsigned 32-bit semantics', () async {
        core.xregs[Register.x5] = 2;
        core.xregs[Register.x6] = 0x00000000FFFFFFFE;

        final divuw = 0x025353bb;
        await core.cycle(pc, divuw);

        expect(core.xregs[Register.x7], 0x7FFFFFFF);
      });

      test('remuw returns unsigned 32-bit remainder, zero-extended', () async {
        core.xregs[Register.x5] = 3;
        core.xregs[Register.x6] = 0x00000000FFFFFFFE;

        final remuw = 0x025373bb;
        await core.cycle(pc, remuw);

        expect(core.xregs[Register.x7], 2);
      });
    }
  }, condition: (config) => config.extensions.any((e) => e.name == 'M'));
}
