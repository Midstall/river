import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';
import 'package:test/test.dart';

/// RVA23 vector (V) bring-up: the canonical vsetvli + unit-stride load +
/// vadd.vv + store, on the RVA23 profile (VLEN=128). And confirmation that a
/// V-less core treats OP-V as illegal (vector is optional). See project_rva23.
void main() {
  HarborMmuConfig mmu(RiscVMxlen x) => HarborMmuConfig(
    mxlen: x,
    pagingModes: const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  );
  const clk = HarborClockConfig(
    name: 'test',
    rate: HarborFixedClockRate(10000),
  );

  group('RVA23 vector', () {
    late Sram sram;
    late RiverCore core;
    final config = RiverCoreConfig(
      mxlen: RiscVMxlen.rv64,
      extensions: kRva23S64Extensions,
      type: RiverCoreType.general,
      mmu: mmu(RiscVMxlen.rv64),
      interrupts: [],
      clock: clk,
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
      core.reset();
    });

    test('VLEN is config-driven (128)', () {
      expect(config.vlen, 128);
      expect(core.hasVector, isTrue);
    });

    test('vsetvli + vle32.v + vadd.vv + vse32.v', () async {
      // A = [1,2,3,4] @ 0x100 ; B = [10,20,30,40] @ 0x110 ; C @ 0x120.
      const a = [1, 2, 3, 4];
      const b = [10, 20, 30, 40];
      for (var i = 0; i < 4; i++) {
        await core.mmu.write(0x100 + i * 4, a[i], 4);
        await core.mmu.write(0x110 + i * 4, b[i], 4);
      }
      core.xregs[Register.x10] = 0x100;
      core.xregs[Register.x11] = 0x110;
      core.xregs[Register.x12] = 0x120;
      core.xregs[Register.x6] = 4; // AVL

      // vsetvli t0,t1,e32,m1,ta,ma  -> vl = min(4, VLMAX=128/32=4) = 4
      await core.cycle(0x1000, 0x0d0372d7);
      expect(core.vl, 4);
      expect(core.xregs[Register.x5], 4); // rd = vl

      await core.cycle(0x1004, 0x02056087); // vle32.v v1,(a0)
      await core.cycle(0x1008, 0x0205e107); // vle32.v v2,(a1)
      await core.cycle(0x100c, 0x021101d7); // vadd.vv v3,v1,v2
      await core.cycle(0x1010, 0x020661a7); // vse32.v v3,(a2)

      for (var i = 0; i < 4; i++) {
        expect(await core.mmu.read(0x120 + i * 4, 4), a[i] + b[i]);
      }
    });

    test('vl/vtype/vlenb/vstart/vcsr readable via csrr', () async {
      // csrrs rd, csr, x0  (a.k.a. csrr rd, csr)
      int csrr(int rd, int csr) => (csr << 20) | (2 << 12) | (rd << 7) | 0x73;
      // csrrw rd, csr, rs1
      int csrw(int rd, int csr, int rs1) =>
          (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73;

      core.xregs[Register.x6] = 4; // AVL
      // vsetvli t0,t1,e32,m1,ta,ma -> vl=4, vtype=0xD0.
      await core.cycle(0x1000, 0x0d0372d7);
      expect(core.vl, 4);

      await core.cycle(0x1004, csrr(5, 0xC20)); // csrr t0, vl
      expect(core.xregs[Register.x5], 4);
      await core.cycle(0x1008, csrr(6, 0xC21)); // csrr t1, vtype
      expect(core.xregs[Register.x6], 0xD0);
      await core.cycle(0x100c, csrr(7, 0xC22)); // csrr t2, vlenb
      expect(core.xregs[Register.x7], 128 ~/ 8); // VLEN/8 = 16

      // vstart is writable then read-back; vcsr packs {vxrm[1:0], vxsat}.
      core.xregs[Register.x8] = 3;
      await core.cycle(0x1010, csrw(0, 0x008, 8)); // csrw vstart, s0
      expect(core.vstart, 3);
      core.xregs[Register.x9] = 0x5; // vxrm=2, vxsat=1
      await core.cycle(0x1014, csrw(0, 0x00F, 9)); // csrw vcsr, s1
      expect(core.vxsat, 1);
      expect(core.vxrm, 2);
      await core.cycle(0x1018, csrr(10, 0x00F)); // csrr a0, vcsr
      expect(core.xregs[Register.x10], 0x5);
    });
  });

  group('RVA23 vector ops (e32, m1, vl=4)', () {
    late Sram sram;
    late RiverCore core;
    final config = RiverCoreConfig(
      mxlen: RiscVMxlen.rv64,
      extensions: kRva23S64Extensions,
      type: RiverCoreType.general,
      mmu: mmu(RiscVMxlen.rv64),
      interrupts: [],
      clock: clk,
    );

    // OP-V arithmetic encoding. funct3: 0=OPIVV 3=OPIVI 4=OPIVX 2=OPMVV 6=OPMVX.
    int vop(int funct6, int vm, int vs2, int f1, int funct3, int vd) =>
        (funct6 << 26) |
        (vm << 25) |
        (vs2 << 20) |
        (f1 << 15) |
        (funct3 << 12) |
        (vd << 7) |
        0x57;
    void setVreg(int v, List<int> elems) {
      for (var i = 0; i < elems.length; i++) {
        core.vwriteElem(v, i, 32, elems[i]);
      }
    }

    List<int> getVreg(int v, int n) => [
      for (var i = 0; i < n; i++) core.vreadElem(v, i, 32),
    ];

    setUp(() async {
      sram = Sram(
        RiverDevice(
          name: 'sram',
          compatible: 'river,sram',
          range: BusAddressRange(0, 0xFFFF),
          clockFrequency: 10000,
        ),
      );
      core = RiverCore(config, memDevices: Map.fromEntries([sram.mem!]));
      core.reset();
      core.xregs[Register.x6] = 4;
      await core.cycle(0x1000, 0x0d0372d7); // vsetvli -> e32,m1,vl=4
      setVreg(1, [1, 2, 3, 4]);
      setVreg(2, [10, 20, 30, 40]);
    });

    test('vmul.vv', () async {
      await core.cycle(0x1004, vop(0x25, 1, 2, 1, 2, 3)); // v3 = v2 * v1
      expect(getVreg(3, 4), [10, 40, 90, 160]);
    });

    test('vfadd.vv / vfsub.vv / vfmul.vv / vfdiv.vv (float, SEW=32)', () async {
      int fb(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      // funct3=1 is OPFVV; my impl reads a=vs2 elem, b=vs1 elem.
      setVreg(1, [fb(1.0), fb(2.0), fb(3.0), fb(4.0)]); // vs2
      setVreg(2, [fb(2.0), fb(4.0), fb(6.0), fb(8.0)]); // vs1
      await core.cycle(0x1004, vop(0x00, 1, 1, 2, 1, 3)); // vfadd.vv v3,v1,v2
      expect(getVreg(3, 4), [fb(3.0), fb(6.0), fb(9.0), fb(12.0)]);
      await core.cycle(0x1008, vop(0x02, 1, 1, 2, 1, 4)); // vfsub.vv v4 = v1-v2
      expect(getVreg(4, 4), [fb(-1.0), fb(-2.0), fb(-3.0), fb(-4.0)]);
      await core.cycle(0x100c, vop(0x24, 1, 1, 2, 1, 5)); // vfmul.vv v5 = v1*v2
      expect(getVreg(5, 4), [fb(2.0), fb(8.0), fb(18.0), fb(32.0)]);
      await core.cycle(0x1010, vop(0x20, 1, 2, 1, 1, 6)); // vfdiv.vv v6 = v2/v1
      expect(getVreg(6, 4), [fb(2.0), fb(2.0), fb(2.0), fb(2.0)]);
    });

    test('vfmin/vfmax/vfsgnj/vfsqrt (float, SEW=32)', () async {
      int fb(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      setVreg(1, [fb(1.0), fb(-2.0), fb(3.0), fb(4.0)]); // vs2
      setVreg(2, [fb(2.0), fb(2.0), fb(2.0), fb(2.0)]); // vs1
      await core.cycle(0x1004, vop(0x04, 1, 1, 2, 1, 3)); // vfmin v3=min(v1,v2)
      expect(getVreg(3, 4), [fb(1.0), fb(-2.0), fb(2.0), fb(2.0)]);
      await core.cycle(0x1008, vop(0x06, 1, 1, 2, 1, 4)); // vfmax v4=max(v1,v2)
      expect(getVreg(4, 4), [fb(2.0), fb(2.0), fb(3.0), fb(4.0)]);
      // vfsgnj v5 = magnitude(v1) with sign(v2) (all +) -> abs(v1)
      await core.cycle(0x100c, vop(0x08, 1, 1, 2, 1, 5));
      expect(getVreg(5, 4), [fb(1.0), fb(2.0), fb(3.0), fb(4.0)]);
      // vfsqrt v6 = sqrt(v2) = sqrt(2) ; funct6=0x13, vs1=0 (unary)
      setVreg(2, [fb(4.0), fb(9.0), fb(16.0), fb(25.0)]);
      await core.cycle(0x1010, vop(0x13, 1, 2, 0, 1, 6));
      expect(getVreg(6, 4), [fb(2.0), fb(3.0), fb(4.0), fb(5.0)]);
    });

    test('vmfeq/vmflt/vmfle/vmfne (float -> mask register)', () async {
      int fb(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      setVreg(1, [fb(1.0), fb(2.0), fb(3.0), fb(4.0)]); // vs2 (a)
      setVreg(2, [fb(2.0), fb(2.0), fb(2.0), fb(2.0)]); // vs1 (b)
      await core.cycle(0x1004, vop(0x1B, 1, 1, 2, 1, 3)); // vmflt v3 = a<b
      expect(core.vregs[3][0] & 0xF, 0x1); // [T,F,F,F]
      await core.cycle(0x1008, vop(0x18, 1, 1, 2, 1, 4)); // vmfeq
      expect(core.vregs[4][0] & 0xF, 0x2); // [F,T,F,F]
      await core.cycle(0x100c, vop(0x19, 1, 1, 2, 1, 5)); // vmfle
      expect(core.vregs[5][0] & 0xF, 0x3); // [T,T,F,F]
      await core.cycle(0x1010, vop(0x1C, 1, 1, 2, 1, 6)); // vmfne
      expect(core.vregs[6][0] & 0xF, 0xD); // [T,F,T,T]
    });

    test('vfmacc.vv (fused multiply-add: vd = vs1*vs2 + vd)', () async {
      int fb(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      setVreg(1, [fb(2.0), fb(2.0), fb(2.0), fb(2.0)]); // vs1
      setVreg(2, [fb(3.0), fb(3.0), fb(3.0), fb(3.0)]); // vs2
      setVreg(3, [fb(1.0), fb(1.0), fb(1.0), fb(1.0)]); // vd accumulator
      await core.cycle(0x1004, vop(0x2C, 1, 2, 1, 1, 3)); // v3 = v1*v2 + v3
      expect(getVreg(3, 4), [fb(7.0), fb(7.0), fb(7.0), fb(7.0)]);
    });

    test('vfadd.vf / vfmul.vf (scalar from x[rs1])', () async {
      int fb(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      setVreg(1, [fb(1.0), fb(2.0), fb(3.0), fb(4.0)]); // vs2
      core.xregs[Register.x5] = fb(10.0); // FP scalar (unified regfile)
      await core.cycle(0x1004, vop(0x00, 1, 1, 5, 5, 3)); // vfadd.vf v3,v1,x5
      expect(getVreg(3, 4), [fb(11.0), fb(12.0), fb(13.0), fb(14.0)]);
      await core.cycle(0x1008, vop(0x24, 1, 1, 5, 5, 4)); // vfmul.vf v4,v1,x5
      expect(getVreg(4, 4), [fb(10.0), fb(20.0), fb(30.0), fb(40.0)]);
    });

    test('vfcvt int<->float + vfclass (SEW=32)', () async {
      int fb(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      // vfcvt.f.x.v (signed int -> float): vs1=0x03
      setVreg(1, [1, 2, 3, 4]);
      await core.cycle(0x1004, vop(0x12, 1, 1, 0x03, 1, 3));
      expect(getVreg(3, 4), [fb(1.0), fb(2.0), fb(3.0), fb(4.0)]);
      // vfcvt.x.f.v (float -> signed int, truncating): vs1=0x01
      setVreg(2, [fb(1.5), fb(2.7), fb(3.9), fb(4.0)]);
      await core.cycle(0x1008, vop(0x12, 1, 2, 0x01, 1, 4));
      expect(getVreg(4, 4), [1, 2, 3, 4]);
      // vfclass.v: vs1=0x10  (+normal, -normal, +0, +inf)
      setVreg(5, [fb(1.0), fb(-1.0), fb(0.0), fb(double.infinity)]);
      await core.cycle(0x100c, vop(0x13, 1, 5, 0x10, 1, 6));
      expect(getVreg(6, 4), [0x40, 0x02, 0x10, 0x80]);
    });

    test('vfredusum/vfredmax/vfredmin (reductions -> vd[0])', () async {
      int fb(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      setVreg(2, [fb(1.0), fb(2.0), fb(3.0), fb(4.0)]); // vs2 (data)
      setVreg(1, [fb(0.0), fb(0.0), fb(0.0), fb(0.0)]); // vs1[0] = init = 0
      await core.cycle(0x1004, vop(0x01, 1, 2, 1, 1, 3)); // vfredusum -> 10
      expect(core.vreadElem(3, 0, 32), fb(10.0));
      await core.cycle(0x1008, vop(0x07, 1, 2, 1, 1, 4)); // vfredmax -> 4
      expect(core.vreadElem(4, 0, 32), fb(4.0));
      await core.cycle(0x100c, vop(0x05, 1, 2, 1, 1, 5)); // vfredmin -> 0
      expect(core.vreadElem(5, 0, 32), fb(0.0));
    });

    test('vfadd.vv / vfmul.vv half-precision (Zvfh, SEW=16)', () async {
      // half bits: 1.0=0x3C00, 2.0=0x4000, 3.0=0x4200, 4.0=0x4400.
      core.vtype = 0xC8; // e16, m1, ta, ma
      core.vl = 4;
      for (var i = 0; i < 4; i++) {
        core.vwriteElem(1, i, 16, 0x3C00); // 1.0h
        core.vwriteElem(2, i, 16, 0x4000); // 2.0h
      }
      await core.cycle(0x1004, vop(0x00, 1, 1, 2, 1, 3)); // vfadd v3 = 1+2
      await core.cycle(0x1008, vop(0x24, 1, 1, 2, 1, 4)); // vfmul v4 = 1*2
      for (var i = 0; i < 4; i++) {
        expect(core.vreadElem(3, i, 16), 0x4200); // 3.0h
        expect(core.vreadElem(4, i, 16), 0x4000); // 2.0h
      }
    });

    test('vmand/vmor/vmxor.mm (mask logical)', () async {
      core.vregs[1][0] = 0x0C; // mask 0b1100
      core.vregs[2][0] = 0x0A; // mask 0b1010
      await core.cycle(0x1004, vop(0x19, 1, 1, 2, 2, 3)); // vmand -> 0b1000
      expect(core.vregs[3][0] & 0xF, 0x08);
      await core.cycle(0x1008, vop(0x1A, 1, 1, 2, 2, 4)); // vmor  -> 0b1110
      expect(core.vregs[4][0] & 0xF, 0x0E);
      await core.cycle(0x100c, vop(0x1B, 1, 1, 2, 2, 5)); // vmxor -> 0b0110
      expect(core.vregs[5][0] & 0xF, 0x06);
    });

    test('vmv.x.s / vmv.s.x / vcpop.m / vfirst.m', () async {
      setVreg(1, [42, 0, 0, 0]);
      await core.cycle(0x1004, vop(0x10, 1, 1, 0x00, 2, 5)); // vmv.x.s x5, v1
      expect(core.xregs[Register.x5], 42);
      core.xregs[Register.x6] = 99;
      await core.cycle(0x1008, vop(0x10, 1, 0, 6, 6, 2)); // vmv.s.x v2, x6
      expect(core.vreadElem(2, 0, 32), 99);
      core.vregs[3][0] = 0x0B; // mask 0b1011 -> 3 set bits
      await core.cycle(0x100c, vop(0x10, 1, 3, 0x10, 2, 7)); // vcpop.m x7, v3
      expect(core.xregs[Register.x7], 3);
      core.vregs[4][0] = 0x08; // mask 0b1000 -> first set at index 3
      await core.cycle(0x1010, vop(0x10, 1, 4, 0x11, 2, 8)); // vfirst.m x8, v4
      expect(core.xregs[Register.x8], 3);
    });

    test('vslideup.vx / vslidedown.vx', () async {
      setVreg(1, [1, 2, 3, 4]);
      core.xregs[Register.x5] = 1; // offset
      setVreg(3, [99, 0, 0, 0]); // vd[0] must stay undisturbed by slideup
      await core.cycle(0x1004, vop(0x0E, 1, 1, 5, 4, 3)); // vslideup v3,v1,1
      expect(getVreg(3, 4), [99, 1, 2, 3]);
      await core.cycle(0x1008, vop(0x0F, 1, 1, 5, 4, 4)); // vslidedown v4,v1,1
      expect(getVreg(4, 4), [2, 3, 4, 0]); // past VLMAX -> 0
    });

    test('vrgather / vcompress / vslide1up / vslide1down', () async {
      setVreg(2, [10, 20, 30, 40]); // data
      setVreg(1, [3, 2, 1, 0]); // gather indices
      await core.cycle(0x1004, vop(0x0C, 1, 2, 1, 0, 3)); // vrgather.vv
      expect(getVreg(3, 4), [40, 30, 20, 10]);
      core.vregs[5][0] = 0x0A; // mask 0b1010 -> elements 1,3
      await core.cycle(0x1008, vop(0x17, 1, 2, 5, 2, 4)); // vcompress.vm
      expect(getVreg(4, 2), [20, 40]); // packed
      core.xregs[Register.x5] = 99;
      await core.cycle(0x100c, vop(0x0E, 1, 2, 5, 6, 6)); // vslide1up.vx
      expect(getVreg(6, 4), [99, 10, 20, 30]);
      await core.cycle(0x1010, vop(0x0F, 1, 2, 5, 6, 7)); // vslide1down.vx
      expect(getVreg(7, 4), [20, 30, 40, 99]);
    });

    test('LMUL=2 register grouping (vadd.vv over 8 elements)', () async {
      core.vtype = 0xD1; // e32, m2, ta, ma
      core.vl = 8; // VLMAX = 128*2/32
      setVreg(2, [1, 2, 3, 4, 5, 6, 7, 8]); // group v2:v3
      setVreg(4, [10, 20, 30, 40, 50, 60, 70, 80]); // group v4:v5
      await core.cycle(0x1004, vop(0x00, 1, 2, 4, 0, 6)); // vadd.vv v6,v2,v4
      expect(getVreg(6, 8), [11, 22, 33, 44, 55, 66, 77, 88]); // spans v6:v7
    });

    test('vlse32 / vsse32 (strided load/store)', () async {
      int vmemS(int op, int rs2, int rs1, int f3, int vd) =>
          (2 << 26) |
          (1 << 25) |
          (rs2 << 20) |
          (rs1 << 15) |
          (f3 << 12) |
          (vd << 7) |
          op;
      for (var i = 0; i < 4; i++) {
        await core.mmu.write(0x100 + i * 8, 11 + i * 11, 4); // stride 8
      }
      core.xregs[Register.x10] = 0x100;
      core.xregs[Register.x11] = 8; // byte stride
      await core.cycle(0x1004, vmemS(0x07, 11, 10, 6, 1)); // vlse32.v v1
      expect(getVreg(1, 4), [11, 22, 33, 44]);
      core.xregs[Register.x12] = 0x200;
      await core.cycle(0x1008, vmemS(0x27, 11, 12, 6, 1)); // vsse32.v v1
      for (var i = 0; i < 4; i++) {
        expect(await core.mmu.read(0x200 + i * 8, 4), 11 + i * 11);
      }
    });

    test('vwadd.vv / vwmul.vv (widening SEW=32 -> 64-bit results)', () async {
      setVreg(2, [1000, 2000, 3000, 4000]);
      setVreg(1, [100, 200, 300, 400]);
      await core.cycle(0x1004, vop(0x31, 1, 2, 1, 2, 4)); // vwadd.vv v4
      const sums = [1100, 2200, 3300, 4400];
      for (var i = 0; i < 4; i++) {
        expect(core.vreadElem(4, i, 64), sums[i]); // 64-bit results span v4:v5
      }
      await core.cycle(0x1008, vop(0x3B, 1, 2, 1, 2, 6)); // vwmul.vv v6
      const prods = [100000, 400000, 900000, 1600000];
      for (var i = 0; i < 4; i++) {
        expect(core.vreadElem(6, i, 64), prods[i]);
      }
    });

    test('vzext.vf2 / vsext.vf2 (16-bit source -> SEW=32)', () async {
      for (var i = 0; i < 4; i++) {
        core.vwriteElem(2, i, 16, [1, 0xFFFE, 3, 0xFFFC][i]); // 1,-2,3,-4
      }
      await core.cycle(0x1004, vop(0x12, 1, 2, 0x06, 2, 3)); // vzext.vf2
      expect(getVreg(3, 4), [1, 0xFFFE, 3, 0xFFFC]); // zero-extended
      await core.cycle(0x1008, vop(0x12, 1, 2, 0x07, 2, 4)); // vsext.vf2
      expect(getVreg(4, 4), [1, 0xFFFFFFFE, 3, 0xFFFFFFFC]); // sign-extended
    });

    test('vnsrl.wi (narrowing 64-bit -> SEW=32 shift right)', () async {
      for (var i = 0; i < 4; i++) {
        core.vwriteElem(2, i, 64, (i + 1) << 16); // spans v2:v3
      }
      // vd=8 must not overlap the 2*SEW source group v2:v3 (narrowing rule).
      await core.cycle(0x1004, vop(0x2C, 1, 2, 16, 3, 8)); // vnsrl.wi v8,v2,16
      expect(getVreg(8, 4), [1, 2, 3, 4]);
    });

    test('vfwadd.vv / vfwmul.vv (FP widening f32 -> f64)', () async {
      int f32(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      int f64(double v) {
        final bd = ByteData(8)..setFloat64(0, v, Endian.little);
        return bd.getUint64(0, Endian.little);
      }

      setVreg(2, [f32(1.0), f32(2.0), f32(3.0), f32(4.0)]);
      setVreg(1, [f32(10.0), f32(20.0), f32(30.0), f32(40.0)]);
      // dest must not overlap the 2*SEW result group's sources.
      await core.cycle(0x1004, vop(0x30, 1, 2, 1, 1, 8)); // vfwadd.vv v8
      const sums = [11.0, 22.0, 33.0, 44.0];
      for (var i = 0; i < 4; i++) {
        expect(core.vreadElem(8, i, 64), f64(sums[i]));
      }
      await core.cycle(0x1008, vop(0x38, 1, 2, 1, 1, 10)); // vfwmul.vv v10
      const prods = [10.0, 40.0, 90.0, 160.0];
      for (var i = 0; i < 4; i++) {
        expect(core.vreadElem(10, i, 64), f64(prods[i]));
      }
    });

    test('vfwcvt.f.f.v / vfncvt.f.f.w (FP precision convert)', () async {
      int f32(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      int f64(double v) {
        final bd = ByteData(8)..setFloat64(0, v, Endian.little);
        return bd.getUint64(0, Endian.little);
      }

      setVreg(2, [f32(1.5), f32(2.5), f32(3.5), f32(4.5)]);
      await core.cycle(0x1004, vop(0x12, 1, 2, 0x0C, 1, 8)); // vfwcvt.f.f.v v8
      const vals = [1.5, 2.5, 3.5, 4.5];
      for (var i = 0; i < 4; i++) {
        expect(
          core.vreadElem(8, i, 64),
          f64(vals[i]),
        ); // f32 -> f64, spans v8:v9
      }
      // narrow back; dest v12 must not overlap the f64 source group v8:v9.
      await core.cycle(
        0x1008,
        vop(0x12, 1, 8, 0x14, 1, 12),
      ); // vfncvt.f.f.w v12
      for (var i = 0; i < 4; i++) {
        expect(core.vreadElem(12, i, 32), f32(vals[i])); // f64 -> f32
      }
    });

    test('vfwcvt/vfncvt int<->float (widen + narrow)', () async {
      int f32(double v) {
        final bd = ByteData(4)..setFloat32(0, v, Endian.little);
        return bd.getUint32(0, Endian.little);
      }

      int f64(double v) {
        final bd = ByteData(8)..setFloat64(0, v, Endian.little);
        return bd.getUint64(0, Endian.little);
      }

      // vfwcvt.f.x.v (vs1=0x0B): signed int32 -> f64 (sign-extends; -3 included).
      setVreg(2, [1, 2, (-3) & 0xFFFFFFFF, 4]);
      await core.cycle(0x1004, vop(0x12, 1, 2, 0x0B, 1, 8));
      const wvals = [1.0, 2.0, -3.0, 4.0];
      for (var i = 0; i < 4; i++) {
        expect(core.vreadElem(8, i, 64), f64(wvals[i])); // int32 -> f64
      }
      // vfwcvt.x.f.v (vs1=0x09): f32 -> signed int64 (truncate toward zero).
      setVreg(3, [f32(1.5), f32(2.7), f32(3.9), f32(4.2)]);
      await core.cycle(0x1008, vop(0x12, 1, 3, 0x09, 1, 10));
      for (var i = 0; i < 4; i++) {
        expect(core.vreadElem(10, i, 64), i + 1); // f32 -> int64
      }
      // vfncvt.x.f.w (vs1=0x11): f64 (v8) -> signed int32 (truncate).
      await core.cycle(0x100c, vop(0x12, 1, 8, 0x11, 1, 12));
      expect(getVreg(12, 4), [1, 2, (-3) & 0xFFFFFFFF, 4]); // f64 -> int32
      // vfncvt.f.x.w (vs1=0x13): signed int64 (v10) -> f32.
      await core.cycle(0x1010, vop(0x12, 1, 10, 0x13, 1, 14));
      expect(getVreg(14, 4), [
        f32(1.0),
        f32(2.0),
        f32(3.0),
        f32(4.0),
      ]); // i64->f32
    });

    test('vmin.vv / vmax.vv (signed)', () async {
      setVreg(2, [10, 20, 30, 40]);
      setVreg(1, [1, 2, 3, 4]);
      await core.cycle(0x1004, vop(0x05, 1, 2, 1, 0, 3)); // vmin
      expect(getVreg(3, 4), [1, 2, 3, 4]);
      await core.cycle(0x1008, vop(0x07, 1, 2, 1, 0, 4)); // vmax
      expect(getVreg(4, 4), [10, 20, 30, 40]);
    });

    test('vsll.vi / vsrl.vi / vsra.vi', () async {
      await core.cycle(0x1004, vop(0x25, 1, 2, 1, 3, 3)); // vsll v2<<1
      expect(getVreg(3, 4), [20, 40, 60, 80]);
      await core.cycle(0x1008, vop(0x28, 1, 2, 1, 3, 4)); // vsrl v2>>1
      expect(getVreg(4, 4), [5, 10, 15, 20]);
      await core.cycle(0x100c, vop(0x29, 1, 2, 1, 3, 5)); // vsra v2>>1
      expect(getVreg(5, 4), [5, 10, 15, 20]);
    });

    test('vid.v', () async {
      await core.cycle(0x1004, vop(0x14, 1, 0, 0x11, 2, 3)); // v3[i] = i
      expect(getVreg(3, 4), [0, 1, 2, 3]);
    });

    test('vmerge.vvm (mask selects source)', () async {
      core.vregs[0][0] = 0x05; // v0 mask = 0b0101 -> elements 0 and 2 active
      await core.cycle(0x1004, vop(0x17, 0, 2, 1, 0, 3)); // vmerge v2/v1 by v0
      expect(getVreg(3, 4), [1, 20, 3, 40]);
    });

    test('masked vadd.vv leaves inactive elements undisturbed', () async {
      core.vregs[0][0] = 0x05; // active: elements 0, 2
      setVreg(3, [100, 101, 102, 103]); // pre-existing destination
      await core.cycle(0x1004, vop(0x00, 0, 2, 1, 0, 3)); // vadd v3,v2,v1,v0.t
      expect(getVreg(3, 4), [11, 101, 33, 103]);
    });
  });

  test('V-less core treats OP-V as illegal (vector disabled)', () async {
    final sram = Sram(
      RiverDevice(
        name: 'sram',
        compatible: 'river,sram',
        range: BusAddressRange(0, 0xFFFF),
        clockFrequency: 10000,
      ),
    );
    // RC1.n is RV32IC with no V extension.
    final core = RiverCore(
      RiverCoreConfigV1.nano(
        mmu: mmu(RiscVMxlen.rv32),
        interrupts: [],
        clock: clk,
      ),
      memDevices: Map.fromEntries([sram.mem!]),
    );
    core.reset();
    expect(core.hasVector, isFalse);
    expect(
      () => core.cycle(0x1000, 0x021101d7), // vadd.vv -> illegal here
      throwsA(anything),
    );
  });
}
