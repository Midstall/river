import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

import '../../constants.dart';

int _fR(int funct7, int rs2, int rs1, int rm, int rd) =>
    (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | 0x53;

int _fLoad(int imm, int rs1, int funct3, int rd) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x07;

int _fStore(int imm, int rs2, int rs1, int funct3) =>
    (((imm >> 5) & 0x7F) << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (funct3 << 12) |
    ((imm & 0x1F) << 7) |
    0x27;

int f64bits(double v) {
  final bd = ByteData(8);
  bd.setFloat64(0, v, Endian.little);
  return bd.getUint64(0, Endian.little);
}

double f64val(int bits) {
  final bd = ByteData(8);
  bd.setUint64(0, bits, Endian.little);
  return bd.getFloat64(0, Endian.little);
}

void writeDword(Sram sram, int addr, int value) {
  for (int i = 0; i < 8; i++) {
    sram.data[addr + i] = (value >> (i * 8)) & 0xFF;
  }
}

int readDword(Sram sram, int addr) {
  int v = 0;
  for (int i = 0; i < 8; i++) {
    v |= sram.data[addr + i] << (i * 8);
  }
  return v;
}

void main() {
  cpuTests('D extension', (config) {
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

    test('fadd.d adds two doubles', () async {
      core.xregs[Register.x5] = f64bits(3.0);
      core.xregs[Register.x6] = f64bits(4.5);

      // fadd.d f7, f5, f6 (funct7=0x01)
      final fadd = _fR(0x01, 6, 5, 0, 7);
      pc = await core.cycle(pc, fadd);

      expect(f64val(core.xregs[Register.x7]!), closeTo(7.5, 1e-12));
    });

    test('fsub.d subtracts two doubles', () async {
      core.xregs[Register.x5] = f64bits(10.0);
      core.xregs[Register.x6] = f64bits(3.5);

      // fsub.d f7, f5, f6 (funct7=0x05)
      final fsub = _fR(0x05, 6, 5, 0, 7);
      pc = await core.cycle(pc, fsub);

      expect(f64val(core.xregs[Register.x7]!), closeTo(6.5, 1e-12));
    });

    test('fmul.d multiplies two doubles', () async {
      core.xregs[Register.x5] = f64bits(3.0);
      core.xregs[Register.x6] = f64bits(2.5);

      // fmul.d f7, f5, f6 (funct7=0x09)
      final fmul = _fR(0x09, 6, 5, 0, 7);
      pc = await core.cycle(pc, fmul);

      expect(f64val(core.xregs[Register.x7]!), closeTo(7.5, 1e-12));
    });

    test('fdiv.d divides two doubles', () async {
      core.xregs[Register.x5] = f64bits(10.0);
      core.xregs[Register.x6] = f64bits(4.0);

      // fdiv.d f7, f5, f6 (funct7=0x0D)
      final fdiv = _fR(0x0D, 6, 5, 0, 7);
      pc = await core.cycle(pc, fdiv);

      expect(f64val(core.xregs[Register.x7]!), closeTo(2.5, 1e-12));
    });

    test('fsqrt.d computes square root', () async {
      core.xregs[Register.x5] = f64bits(9.0);

      // fsqrt.d f7, f5 (funct7=0x2D, rs2=0)
      final fsqrt = _fR(0x2D, 0, 5, 0, 7);
      pc = await core.cycle(pc, fsqrt);

      expect(f64val(core.xregs[Register.x7]!), closeTo(3.0, 1e-12));
    });

    test('feq.d returns 1 when equal', () async {
      core.xregs[Register.x5] = f64bits(2.5);
      core.xregs[Register.x6] = f64bits(2.5);

      // feq.d x7, f5, f6 (funct7=0x51, funct3=0x2)
      final feq = _fR(0x51, 6, 5, 2, 7);
      pc = await core.cycle(pc, feq);

      expect(core.xregs[Register.x7], 1);
    });

    test('feq.d returns 0 when not equal', () async {
      core.xregs[Register.x5] = f64bits(2.5);
      core.xregs[Register.x6] = f64bits(3.0);

      final feq = _fR(0x51, 6, 5, 2, 7);
      pc = await core.cycle(pc, feq);

      expect(core.xregs[Register.x7], 0);
    });

    test('flt.d returns 1 when less than', () async {
      core.xregs[Register.x5] = f64bits(2.0);
      core.xregs[Register.x6] = f64bits(3.0);

      // flt.d x7, f5, f6 (funct7=0x51, funct3=0x1)
      final flt = _fR(0x51, 6, 5, 1, 7);
      pc = await core.cycle(pc, flt);

      expect(core.xregs[Register.x7], 1);
    });

    test('fle.d returns 1 when less or equal', () async {
      core.xregs[Register.x5] = f64bits(3.0);
      core.xregs[Register.x6] = f64bits(3.0);

      // fle.d x7, f5, f6 (funct7=0x51, funct3=0x0)
      final fle = _fR(0x51, 6, 5, 0, 7);
      pc = await core.cycle(pc, fle);

      expect(core.xregs[Register.x7], 1);
    });

    test('fcvt.w.d converts double to signed int', () async {
      core.xregs[Register.x5] = f64bits(42.7);

      // fcvt.w.d x7, f5 (funct7=0x61, rs2=0, rm=1 RTZ -> truncate)
      final fcvtwd = _fR(0x61, 0, 5, 1, 7);
      pc = await core.cycle(pc, fcvtwd);

      expect(core.xregs[Register.x7]! & 0xFFFFFFFF, 42);
    });

    test('fcvt.d.w converts signed int to double', () async {
      core.xregs[Register.x5] = 42;

      // fcvt.d.w f7, x5 (funct7=0x69, rs2=0)
      final fcvtdw = _fR(0x69, 0, 5, 0, 7);
      pc = await core.cycle(pc, fcvtdw);

      expect(f64val(core.xregs[Register.x7]!), closeTo(42.0, 1e-12));
    });

    test('fld loads double from memory', () async {
      core.xregs[Register.x10] = 0x100;
      writeDword(sram, 0x100, f64bits(1.5));

      // fld f7, 0(x10) (funct3=0x3)
      final fld = _fLoad(0, 10, 0x3, 7);
      pc = await core.cycle(pc, fld);

      expect(f64val(core.xregs[Register.x7]!), closeTo(1.5, 1e-12));
    });

    test('fsd stores double to memory', () async {
      core.xregs[Register.x10] = 0x200;
      core.xregs[Register.x7] = f64bits(3.14159);

      // fsd f7, 0(x10) (funct3=0x3)
      final fsd = _fStore(0, 7, 10, 0x3);
      pc = await core.cycle(pc, fsd);

      expect(f64val(readDword(sram, 0x200)), closeTo(3.14159, 1e-5));
    });

    test('fadd.d with negative numbers', () async {
      core.xregs[Register.x5] = f64bits(-100.5);
      core.xregs[Register.x6] = f64bits(50.25);

      final fadd = _fR(0x01, 6, 5, 0, 7);
      pc = await core.cycle(pc, fadd);

      expect(f64val(core.xregs[Register.x7]!), closeTo(-50.25, 1e-12));
    });

    test('fdiv.d precision', () async {
      core.xregs[Register.x5] = f64bits(1.0);
      core.xregs[Register.x6] = f64bits(3.0);

      final fdiv = _fR(0x0D, 6, 5, 0, 7);
      pc = await core.cycle(pc, fdiv);

      expect(f64val(core.xregs[Register.x7]!), closeTo(1.0 / 3.0, 1e-15));
    });
  }, condition: (config) => config.extensions.any((e) => e.name == 'D'));
}
