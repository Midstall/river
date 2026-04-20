import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import '../../constants.dart';

// R-type FP: funct7[31:25] | rs2[24:20] | rs1[19:15] | rm[14:12] | rd[11:7] | opcode[6:0]
int _fR(int funct7, int rs2, int rs1, int rm, int rd) =>
    (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | 0x53;

// R4-type FMA: rs3[31:27] | fmt[26:25] | rs2[24:20] | rs1[19:15] | rm | rd | op.
int _fR4(int opcode, int rs3, int rs2, int rs1, int rd, {int fmt = 0}) =>
    (rs3 << 27) | (fmt << 25) | (rs2 << 20) | (rs1 << 15) | (rd << 7) | opcode;

// I-type FP load: imm[31:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
int _fLoad(int imm, int rs1, int funct3, int rd) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x07;

// S-type FP store: imm[11:5][31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | imm[4:0][11:7] | opcode[6:0]
int _fStore(int imm, int rs2, int rs1, int funct3) =>
    (((imm >> 5) & 0x7F) << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (funct3 << 12) |
    ((imm & 0x1F) << 7) |
    0x27;

int f32bits(double v) {
  final bd = ByteData(4);
  bd.setFloat32(0, v, Endian.little);
  return bd.getUint32(0, Endian.little);
}

double f32val(int bits) {
  final bd = ByteData(4);
  bd.setUint32(0, bits & 0xFFFFFFFF, Endian.little);
  return bd.getFloat32(0, Endian.little);
}

void writeWord(Sram sram, int addr, int value) {
  for (int i = 0; i < 4; i++) {
    sram.data[addr + i] = (value >> (i * 8)) & 0xFF;
  }
}

int readWord(Sram sram, int addr) {
  int v = 0;
  for (int i = 0; i < 4; i++) {
    v |= sram.data[addr + i] << (i * 8);
  }
  return v;
}

void main() {
  cpuTests('F extension', (config) {
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

    test('fadd.s adds two floats', () async {
      core.xregs[Register.x5] = f32bits(3.0);
      core.xregs[Register.x6] = f32bits(4.5);

      // fadd.s f7, f5, f6 (funct7=0x00)
      final fadd = _fR(0x00, 6, 5, 0, 7);
      pc = await core.cycle(pc, fadd);

      expect(f32val(core.xregs[Register.x7]!), closeTo(7.5, 1e-6));
    });

    test('fsub.s subtracts two floats', () async {
      core.xregs[Register.x5] = f32bits(10.0);
      core.xregs[Register.x6] = f32bits(3.5);

      // fsub.s f7, f5, f6 (funct7=0x04)
      final fsub = _fR(0x04, 6, 5, 0, 7);
      pc = await core.cycle(pc, fsub);

      expect(f32val(core.xregs[Register.x7]!), closeTo(6.5, 1e-6));
    });

    test('fmul.s multiplies two floats', () async {
      core.xregs[Register.x5] = f32bits(3.0);
      core.xregs[Register.x6] = f32bits(2.5);

      // fmul.s f7, f5, f6 (funct7=0x08)
      final fmul = _fR(0x08, 6, 5, 0, 7);
      pc = await core.cycle(pc, fmul);

      expect(f32val(core.xregs[Register.x7]!), closeTo(7.5, 1e-6));
    });

    test('fdiv.s divides two floats', () async {
      core.xregs[Register.x5] = f32bits(10.0);
      core.xregs[Register.x6] = f32bits(4.0);

      // fdiv.s f7, f5, f6 (funct7=0x0C)
      final fdiv = _fR(0x0C, 6, 5, 0, 7);
      pc = await core.cycle(pc, fdiv);

      expect(f32val(core.xregs[Register.x7]!), closeTo(2.5, 1e-6));
    });

    test('fsqrt.s computes square root', () async {
      core.xregs[Register.x5] = f32bits(9.0);

      // fsqrt.s f7, f5 (funct7=0x2C, rs2=0)
      final fsqrt = _fR(0x2C, 0, 5, 0, 7);
      pc = await core.cycle(pc, fsqrt);

      expect(f32val(core.xregs[Register.x7]!), closeTo(3.0, 1e-6));
    });

    test('feq.s returns 1 when equal', () async {
      core.xregs[Register.x5] = f32bits(2.5);
      core.xregs[Register.x6] = f32bits(2.5);

      // feq.s x7, f5, f6 (funct7=0x50, funct3=0x2)
      final feq = _fR(0x50, 6, 5, 2, 7);
      pc = await core.cycle(pc, feq);

      expect(core.xregs[Register.x7], 1);
    });

    test('feq.s returns 0 when not equal', () async {
      core.xregs[Register.x5] = f32bits(2.5);
      core.xregs[Register.x6] = f32bits(3.0);

      final feq = _fR(0x50, 6, 5, 2, 7);
      pc = await core.cycle(pc, feq);

      expect(core.xregs[Register.x7], 0);
    });

    test('flt.s returns 1 when less than', () async {
      core.xregs[Register.x5] = f32bits(2.0);
      core.xregs[Register.x6] = f32bits(3.0);

      // flt.s x7, f5, f6 (funct7=0x50, funct3=0x1)
      final flt = _fR(0x50, 6, 5, 1, 7);
      pc = await core.cycle(pc, flt);

      expect(core.xregs[Register.x7], 1);
    });

    test('flt.s returns 0 when not less than', () async {
      core.xregs[Register.x5] = f32bits(5.0);
      core.xregs[Register.x6] = f32bits(3.0);

      final flt = _fR(0x50, 6, 5, 1, 7);
      pc = await core.cycle(pc, flt);

      expect(core.xregs[Register.x7], 0);
    });

    test('fle.s returns 1 when less or equal', () async {
      core.xregs[Register.x5] = f32bits(3.0);
      core.xregs[Register.x6] = f32bits(3.0);

      // fle.s x7, f5, f6 (funct7=0x50, funct3=0x0)
      final fle = _fR(0x50, 6, 5, 0, 7);
      pc = await core.cycle(pc, fle);

      expect(core.xregs[Register.x7], 1);
    });

    test('fcvt.w.s converts float to signed int', () async {
      core.xregs[Register.x5] = f32bits(42.7);

      // fcvt.w.s x7, f5 (funct7=0x60, rs2=0, rm=1 RTZ -> truncate)
      final fcvtws = _fR(0x60, 0, 5, 1, 7);
      pc = await core.cycle(pc, fcvtws);

      expect(core.xregs[Register.x7], 42);
    });

    test('fcvt.w.s converts negative float to signed int', () async {
      core.xregs[Register.x5] = f32bits(-7.9);

      final fcvtws = _fR(0x60, 0, 5, 1, 7); // rm=1 RTZ -> truncate
      pc = await core.cycle(pc, fcvtws);

      expect(core.xregs[Register.x7]! & 0xFFFFFFFF, (-7 & 0xFFFFFFFF));
    });

    test('fcvt.s.w converts signed int to float', () async {
      core.xregs[Register.x5] = 42;

      // fcvt.s.w f7, x5 (funct7=0x68, rs2=0)
      final fcvtsw = _fR(0x68, 0, 5, 0, 7);
      pc = await core.cycle(pc, fcvtsw);

      expect(f32val(core.xregs[Register.x7]!), closeTo(42.0, 1e-6));
    });

    // fcvt variants select int width+sign from the rs2 field (1=wu, 2=l, 3=lu),
    // not the mnemonic. These distinguish the rs2-driven paths from the rs2=0
    // signed-word default.
    test('fcvt.wu.s: negative float saturates to 0 (unsigned)', () async {
      core.xregs[Register.x5] = f32bits(-7.9);
      pc = await core.cycle(pc, _fR(0x60, 1, 5, 0, 7)); // rs2=1 -> wu
      expect(core.xregs[Register.x7], 0);
    });

    test('fcvt.wu.s: value above int32 max (unsigned 32)', () async {
      core.xregs[Register.x5] = f32bits(3221225472.0); // 0xC0000000
      pc = await core.cycle(pc, _fR(0x60, 1, 5, 0, 7));
      expect(core.xregs[Register.x7]! & 0xFFFFFFFF, 0xC0000000);
    });

    test('fcvt.w.s: 2^31 saturates to int32 max', () async {
      core.xregs[Register.x5] = f32bits(2147483648.0);
      pc = await core.cycle(pc, _fR(0x60, 0, 5, 0, 7)); // rs2=0 -> w
      expect(core.xregs[Register.x7]! & 0xFFFFFFFF, 0x7FFFFFFF);
    });

    test('fcvt.l.s: 2^31 converts to signed 64 (no W saturation)', () async {
      core.xregs[Register.x5] = f32bits(2147483648.0);
      pc = await core.cycle(pc, _fR(0x60, 2, 5, 0, 7)); // rs2=2 -> l
      expect(core.xregs[Register.x7], 2147483648);
    });

    test('fcvt.s.wu: 0xFFFFFFFF is +4.29e9, not -1.0', () async {
      core.xregs[Register.x5] = 0xFFFFFFFF;
      pc = await core.cycle(pc, _fR(0x68, 1, 5, 0, 7)); // rs2=1 -> s.wu
      expect(f32val(core.xregs[Register.x7]!), closeTo(4294967295.0, 256.0));
    });

    test('fcvt.s.lu: max u64 converts as unsigned (not -1)', () async {
      core.xregs[Register.x5] = -1; // 0xFFFFFFFFFFFFFFFF
      pc = await core.cycle(pc, _fR(0x68, 3, 5, 0, 7)); // rs2=3 -> s.lu
      expect(
        f32val(core.xregs[Register.x7]!),
        closeTo(1.8446744073709552e19, 1e13),
      );
    });

    // Fused multiply-add: rd = +-(rs1*rs2) +- rs3. a=2, b=3, c=4.
    test('fmadd.s = a*b + c', () async {
      core.xregs[Register.x5] = f32bits(2.0);
      core.xregs[Register.x6] = f32bits(3.0);
      core.xregs[Register.x7] = f32bits(4.0);
      pc = await core.cycle(pc, _fR4(0x43, 7, 6, 5, 8)); // fmadd.s x8
      expect(f32val(core.xregs[Register.x8]!), closeTo(10.0, 1e-6));
    });

    test('fmsub.s = a*b - c', () async {
      core.xregs[Register.x5] = f32bits(2.0);
      core.xregs[Register.x6] = f32bits(3.0);
      core.xregs[Register.x7] = f32bits(4.0);
      pc = await core.cycle(pc, _fR4(0x47, 7, 6, 5, 8)); // fmsub.s x8
      expect(f32val(core.xregs[Register.x8]!), closeTo(2.0, 1e-6));
    });

    test('fnmsub.s = -(a*b) + c', () async {
      core.xregs[Register.x5] = f32bits(2.0);
      core.xregs[Register.x6] = f32bits(3.0);
      core.xregs[Register.x7] = f32bits(4.0);
      pc = await core.cycle(pc, _fR4(0x4B, 7, 6, 5, 8)); // fnmsub.s x8
      expect(f32val(core.xregs[Register.x8]!), closeTo(-2.0, 1e-6));
    });

    test('fnmadd.s = -(a*b) - c', () async {
      core.xregs[Register.x5] = f32bits(2.0);
      core.xregs[Register.x6] = f32bits(3.0);
      core.xregs[Register.x7] = f32bits(4.0);
      pc = await core.cycle(pc, _fR4(0x4F, 7, 6, 5, 8)); // fnmadd.s x8
      expect(f32val(core.xregs[Register.x8]!), closeTo(-10.0, 1e-6));
    });

    // fcvt.w.s rounding modes (rm = funct3): 0=RNE,1=RTZ,2=RDN,3=RUP,4=RMM.
    // 2.5 distinguishes them (RNE->2 ties-even, RUP/RMM->3, RTZ/RDN->2).
    for (final (rm, want) in const [(0, 2), (1, 2), (2, 2), (3, 3), (4, 3)]) {
      test('fcvt.w.s 2.5 rm=$rm -> $want', () async {
        core.xregs[Register.x5] = f32bits(2.5);
        pc = await core.cycle(pc, _fR(0x60, 0, 5, rm, 6));
        expect(core.xregs[Register.x6]! & 0xFFFFFFFF, want);
      });
    }

    test('fcvt.w.s 3.5 RNE -> 4 (ties to even)', () async {
      core.xregs[Register.x5] = f32bits(3.5);
      pc = await core.cycle(pc, _fR(0x60, 0, 5, 0, 6)); // RNE
      expect(core.xregs[Register.x6]! & 0xFFFFFFFF, 4);
    });

    test('fcvt.w.s -2.5 RDN -> -3, RUP -> -2', () async {
      core.xregs[Register.x5] = f32bits(-2.5);
      pc = await core.cycle(pc, _fR(0x60, 0, 5, 2, 6)); // RDN
      expect(core.xregs[Register.x6]! & 0xFFFFFFFF, (-3) & 0xFFFFFFFF);
      core.xregs[Register.x5] = f32bits(-2.5);
      pc = await core.cycle(pc, _fR(0x60, 0, 5, 3, 7)); // RUP
      expect(core.xregs[Register.x7]! & 0xFFFFFFFF, (-2) & 0xFFFFFFFF);
    });

    test('flw loads float from memory', () async {
      core.xregs[Register.x10] = 0x100;
      writeWord(sram, 0x100, f32bits(1.5));

      // flw f7, 0(x10) (funct3=0x2)
      final flw = _fLoad(0, 10, 0x2, 7);
      pc = await core.cycle(pc, flw);

      expect(f32val(core.xregs[Register.x7]!), closeTo(1.5, 1e-6));
    });

    test('flw loads float with offset', () async {
      core.xregs[Register.x10] = 0x100;
      writeWord(sram, 0x108, f32bits(99.5));

      // flw f7, 8(x10)
      final flw = _fLoad(8, 10, 0x2, 7);
      pc = await core.cycle(pc, flw);

      expect(f32val(core.xregs[Register.x7]!), closeTo(99.5, 1e-6));
    });

    test('fsw stores float to memory', () async {
      core.xregs[Register.x10] = 0x200;
      core.xregs[Register.x7] = f32bits(3.14);

      // fsw f7, 0(x10) (funct3=0x2)
      final fsw = _fStore(0, 7, 10, 0x2);
      pc = await core.cycle(pc, fsw);

      expect(f32val(readWord(sram, 0x200)), closeTo(3.14, 0.01));
    });

    test('fsw stores float with offset', () async {
      core.xregs[Register.x10] = 0x200;
      core.xregs[Register.x7] = f32bits(2.718);

      // fsw f7, 4(x10)
      final fsw = _fStore(4, 7, 10, 0x2);
      pc = await core.cycle(pc, fsw);

      expect(f32val(readWord(sram, 0x204)), closeTo(2.718, 0.01));
    });

    test('fadd.s with negative numbers', () async {
      core.xregs[Register.x5] = f32bits(-3.0);
      core.xregs[Register.x6] = f32bits(1.5);

      final fadd = _fR(0x00, 6, 5, 0, 7);
      pc = await core.cycle(pc, fadd);

      expect(f32val(core.xregs[Register.x7]!), closeTo(-1.5, 1e-6));
    });

    test('fmul.s with zero', () async {
      core.xregs[Register.x5] = f32bits(123.456);
      core.xregs[Register.x6] = f32bits(0.0);

      final fmul = _fR(0x08, 6, 5, 0, 7);
      pc = await core.cycle(pc, fmul);

      expect(f32val(core.xregs[Register.x7]!), 0.0);
    });
  }, condition: (config) => config.extensions.any((e) => e.name == 'F'));
}
