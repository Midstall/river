import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// RVA22U64 user-mode instruction verification on the emulator, using the
/// RVA22 profile config. Each test executes a single instruction (encodings
/// taken from the GNU assembler) and checks the architectural result.
void main() {
  group('RVA22 U-mode', () {
    late Sram sram;
    late RiverCore core;
    late int pc;

    final config = RiverCoreConfig(
      mxlen: RiscVMxlen.rv64,
      extensions: kRva22S64Extensions,
      type: RiverCoreType.general,
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
        rate: HarborFixedClockRate(10000),
      ),
    );

    setUp(() {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: 10000,
        ),
      );
      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
      pc = config.resetVector;
    });

    // Execute one instruction with the given register inputs; returns nextPc.
    Future<int> run(int instr, [Map<Register, int> regs = const {}]) async {
      core.reset();
      regs.forEach((r, v) => core.xregs[r] = v);
      return core.cycle(pc, instr);
    }

    int x(Register r) => core.xregs[r]!;

    // ---- Working today ----
    test('pause is a no-op hint', () async {
      final next = await run(0x0100000f);
      expect(next, pc + 4);
    });
    test('cbo.zero executes and advances pc', () async {
      final next = await run(0x0043200f, {Register.x6: 0x40});
      expect(next, pc + 4);
    });

    // The bit-manipulation extensions (Zba/Zbb/Zbs) and the Zicntr counters are
    // decode-defined in Harbor but their *execution* is stubbed: RiscVAluFunct
    // has no bit-manip values, the microcode uses placeholder funct (e.g.
    // sh1add is `RiscVAlu(add,...)`), and the emulator/HDL ALUs don't implement
    // them. These tests encode the correct expected behavior and are ready to
    // enable once that lands. See project_rva22 in memory.
    group('Zb + Zicntr execution', () {
      // ---- Zbb: logical-with-complement ----
      test('andn (Zbb)', () async {
        await run(0x4062f3b3, {Register.x5: 0xFF00, Register.x6: 0x0F0F});
        expect(x(Register.x7), 0xFF00 & ~0x0F0F);
      });
      test('orn (Zbb)', () async {
        await run(0x4062e433, {Register.x5: 0x0F0F, Register.x6: 0xF0F0});
        expect(x(Register.x8), 0x0F0F | ~0xF0F0);
      });
      test('xnor (Zbb)', () async {
        await run(0x4062c4b3, {Register.x5: 0xF0F0, Register.x6: 0x0F0F});
        expect(x(Register.x9), ~(0xF0F0 ^ 0x0F0F));
      });

      // ---- Zbb: min/max ----
      test('min / max (Zbb, signed)', () async {
        await run(0x0a62c533, {Register.x5: 5, Register.x6: -3});
        expect(x(Register.x10), -3);
        await run(0x0a62e5b3, {Register.x5: 5, Register.x6: -3});
        expect(x(Register.x11), 5);
      });
      test('minu / maxu (Zbb, unsigned)', () async {
        // -1 is the largest unsigned value.
        await run(0x0a62d633, {Register.x5: 5, Register.x6: -1});
        expect(x(Register.x12), 5);
        await run(0x0a62f6b3, {Register.x5: 5, Register.x6: -1});
        expect(x(Register.x13), -1);
      });

      // ---- Zbb: bit counts ----
      test('clz (Zbb, 64-bit)', () async {
        await run(0x60029713, {Register.x5: 1});
        expect(x(Register.x14), 63);
      });
      test('ctz (Zbb)', () async {
        await run(0x60129793, {Register.x5: 8});
        expect(x(Register.x15), 3);
      });
      test('cpop (Zbb)', () async {
        await run(0x60229813, {Register.x5: 0xFF});
        expect(x(Register.x16), 8);
      });

      // ---- Zbb: sign/zero extend & byte ops ----
      test('sext.b (Zbb)', () async {
        await run(0x60429893, {Register.x5: 0x80});
        expect(x(Register.x17), -128);
      });
      test('zext.h (Zbb)', () async {
        await run(0x0802c9bb, {Register.x5: -1});
        expect(x(Register.x19), 0xFFFF);
      });
      test('rev8 (Zbb, 64-bit)', () async {
        await run(0x6b82da13, {Register.x5: 0x0102030405060708});
        expect(x(Register.x20), 0x0807060504030201);
      });
      test('orc.b (Zbb)', () async {
        await run(0x2872dc13, {Register.x5: 0x0100000000000001});
        expect(x(Register.x24), 0xFF000000000000FF);
      });

      // ---- Zbb: rotates ----
      test('ror (Zbb)', () async {
        await run(0x6062db33, {Register.x5: 0x1, Register.x6: 1});
        expect(x(Register.x22), 0x8000000000000000);
      });
      test('rol (Zbb)', () async {
        await run(0x60629ab3, {
          Register.x5: 0x8000000000000000,
          Register.x6: 1,
        });
        expect(x(Register.x21), 0x1);
      });

      // ---- Zba: shift-add ----
      test('sh1add / sh2add / sh3add (Zba)', () async {
        await run(0x2062acb3, {Register.x5: 3, Register.x6: 10});
        expect(x(Register.x25), (3 << 1) + 10);
        await run(0x2062cd33, {Register.x5: 3, Register.x6: 10});
        expect(x(Register.x26), (3 << 2) + 10);
        await run(0x2062edb3, {Register.x5: 3, Register.x6: 10});
        expect(x(Register.x27), (3 << 3) + 10);
      });
      test('add.uw (Zba, RV64)', () async {
        await run(0x08628e3b, {Register.x5: 0x1FFFFFFF5, Register.x6: 10});
        expect(x(Register.x28), 0xFFFFFFF5 + 10);
      });

      // ---- Zbs: single-bit ----
      test('bset / bclr / bext / binv (Zbs)', () async {
        await run(0x28629f33, {Register.x5: 0, Register.x6: 5});
        expect(x(Register.x30), 1 << 5);
        await run(0x48629fb3, {Register.x5: 0xFF, Register.x6: 0});
        expect(x(Register.x31), 0xFE);
        await run(0x4862d0b3, {Register.x5: 0x4, Register.x6: 2});
        expect(x(Register.x1), 1);
        await run(0x68629133, {Register.x5: 0xF, Register.x6: 0});
        expect(x(Register.x2), 0xE);
      });

      // ---- Zicntr: counters readable ----
      test('rdcycle executes and advances pc', () async {
        final next = await run(0xc0002273);
        expect(core.xregs[Register.x4], isNotNull);
        expect(next, pc + 4);
      });
      test('rdinstret executes and advances pc', () async {
        final next = await run(0xc02022f3);
        expect(core.xregs[Register.x5], isNotNull);
        expect(next, pc + 4);
      });
    });
  });
}
