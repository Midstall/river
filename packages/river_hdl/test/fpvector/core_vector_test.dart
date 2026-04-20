import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';

/// Vector (V extension) datapath bring-up. The HDL had no vector support; this
/// builds it incrementally against Harbor's rv_v op set, mirroring the
/// emulator's vector engine. See project_vector / project_parity in memory.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  RiverCoreConfig vecConfig() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvV],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    vlen: 128,
  );

  // Same as vecConfig but with Zvfh (SEW=16 half-precision vector FP). Only the
  // FP16 test uses this so the rest of the suite skips the extra FP16 lane units.
  RiverCoreConfig vecConfigZvfh() => RiverCoreConfig(
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: RiscVMxlen.rv64,
    extensions: [rv64i, rv32i, rvZicsr, rvZifencei, rvV, rvZvfh],
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    vlen: 128,
  );

  int iimm(int imm, int rs1, int f3, int rd) =>
      (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13;
  // vsetvli rd, rs1, vtypei (opcode 0x57, funct3=7 OPCFG; vtypei in bits[30:20])
  int vsetvli(int vtypei, int rs1, int rd) =>
      (vtypei << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x57;
  // vle32.v vd, (rs1): opcode 0x07, width(funct3)=6, vm=1, lumop=0.
  int vle32(int rs1, int vd) =>
      (1 << 25) | (rs1 << 15) | (0x6 << 12) | (vd << 7) | 0x07;
  // vse32.v vs3, (rs1): opcode 0x27, width=6, vm=1.
  int vse32(int rs1, int vs3) =>
      (1 << 25) | (rs1 << 15) | (0x6 << 12) | (vs3 << 7) | 0x27;
  // OPIVV integer op vd, vs2, vs1: opcode 0x57, funct3=0, vm=1, given funct6.
  int vopivv(int funct6, int vs2, int vs1, int vd) =>
      (funct6 << 26) | (1 << 25) | (vs2 << 20) | (vs1 << 15) | (vd << 7) | 0x57;
  // OPFVV FP op vd, vs2, vs1: funct3=1, vm=1, given funct6 (add=0, mul=0x24).
  int vopfvv(int funct6, int vs2, int vs1, int vd) =>
      (funct6 << 26) |
      (1 << 25) |
      (vs2 << 20) |
      (vs1 << 15) |
      (0x1 << 12) |
      (vd << 7) |
      0x57;
  int vaddvv(int vs2, int vs1, int vd) => vopivv(0x00, vs2, vs1, vd);
  // vadd.vx vd, vs2, rs1: funct3=4 (OPIVX), funct6=0, vm=1.
  int vaddvx(int vs2, int rs1, int vd) =>
      (1 << 25) | (vs2 << 20) | (rs1 << 15) | (0x4 << 12) | (vd << 7) | 0x57;
  // vadd.vi vd, vs2, imm5: funct3=3 (OPIVI), funct6=0, vm=1.
  int vaddvi(int vs2, int imm5, int vd) =>
      (1 << 25) |
      (vs2 << 20) |
      ((imm5 & 0x1F) << 15) |
      (0x3 << 12) |
      (vd << 7) |
      0x57;
  String prog(List<int> words) {
    final sb = StringBuffer('@0\n');
    for (final w in words) {
      for (var b = 0; b < 4; b++) {
        sb.write(((w >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
      }
    }
    return '$sb\n';
  }

  // Milestone 1: vsetvli sets vl = min(AVL, VLMAX) and writes it to rd.
  // e32,m1 with VLEN=128 -> VLMAX = 128/32 = 4. AVL=8 -> vl=4.
  // Milestone 1: vsetvli computes vl = min(AVL, VLMAX) into rd.
  test(
    'vsetvli computes vl into rd (e32,m1, VLEN=128 -> vl=4)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      prog([
        iimm(8, 0, 0x0, 2), // addi x2, x0, 8   (AVL = 8)
        vsetvli(0x10, 2, 1), // vsetvli x1, x2, e32,m1  -> x1 = vl = 4
        0x00000013, // nop (halt target)
      ]),
      {Register.x1: 4, Register.x2: 8},
      vecConfig(),
      nextPc: 0x0C,
    ),
  );

  // vsetvli with rs1=x0 (and rd!=x0) sets vl = VLMAX (not 0). The old code read
  // AVL from x0 = 0 and produced vl=0; the spec says rs1=x0 means "give me VLMAX".
  test(
    'vsetvli rs1=x0 sets vl=VLMAX (e32,m1 -> 4)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      prog([
        vsetvli(0x10, 0, 1), // vsetvli x1, x0, e32,m1 -> vl = VLMAX = 4
        0x00000013, // nop (halt target)
      ]),
      {Register.x1: 4},
      vecConfig(),
      nextPc: 0x08,
    ),
  );

  // Fractional LMUL: e32,mf2 (VLEN=128) -> VLMAX = (128/32)/2 = 2. The old code
  // shifted left by vlmul=7 giving a bogus huge VLMAX; now it shifts right.
  test(
    'vsetvli fractional LMUL mf2 (e32,mf2 -> vl=2)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      prog([
        iimm(8, 0, 0x0, 2), // addi x2, x0, 8   (AVL = 8)
        vsetvli(0x17, 2, 1), // vsetvli x1, x2, e32,mf2 -> vl = min(8, 2) = 2
        0x00000013, // nop (halt target)
      ]),
      {Register.x1: 2, Register.x2: 8},
      vecConfig(),
      nextPc: 0x0C,
    ),
  );

  // Milestone 2a: vle32.v / vse32.v round-trip through the vector register file
  // (loads the low mxlen-wide chunk of a vreg). Proves the vreg file + vector
  // load/store path without needing element arithmetic.
  test(
    'vle32.v + vse32.v round-trip through a vreg',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100  (src)
        iimm(0x200, 0, 0x0, 11), // addi x11, x0, 0x200  (dst)
        vle32(10, 1), // vle32.v v1, (x10)   v1 = mem[0x100]
        vse32(11, 1), // vse32.v v1, (x11)   mem[0x200] = v1
        0x00000013, // nop (halt target)
      ])}@100\nbe ba fe ca ef be ad de\n',
      {Register.x10: 0x100, Register.x11: 0x200},
      vecConfig(),
      nextPc: 0x14,
      memStates: {0x200: 0xDEADBEEFCAFEBABE},
    ),
  );

  // Milestone 2b: vadd.vv element-wise add (SEW=32). Load two vregs, add, store.
  // v1=[10,20], v2=[100,200] -> v3=[110,220]; stored low 64 = 220<<32 | 110.
  test(
    'vadd.vv element-wise add (e32: [10,20]+[100,200]=[110,220])',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // x10 = 0x100 (v1 src)
        iimm(0x110, 0, 0x0, 11), // x11 = 0x110 (v2 src)
        iimm(0x200, 0, 0x0, 12), // x12 = 0x200 (dst)
        vle32(10, 1), // v1 = [10, 20]
        vle32(11, 2), // v2 = [100, 200]
        vaddvv(1, 2, 3), // v3 = v1 + v2 = [110, 220]
        vse32(12, 3), // mem[0x200] = v3
        0x00000013, // nop (halt target)
      ])}@100\n0a 00 00 00 14 00 00 00\n@110\n64 00 00 00 c8 00 00 00\n',
      const <Register, int>{},
      vecConfig(),
      nextPc: 0x20,
      memStates: {0x200: 0x000000DC0000006E}, // [110, 220]
    ),
  );

  // Milestone 2c: the rest of OPIVV integer arithmetic, vsub (per-lane borrow)
  // and vxor (full-width bitwise). v1=[100,200], v2=[10,20].
  test(
    'vsub.vv / vxor.vv (e32)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // v1 src
        iimm(0x110, 0, 0x0, 11), // v2 src
        iimm(0x200, 0, 0x0, 12), // vsub dst
        iimm(0x210, 0, 0x0, 13), // vxor dst
        vle32(10, 1), // v1 = [100, 200]
        vle32(11, 2), // v2 = [10, 20]
        vopivv(0x02, 1, 2, 3), // vsub.vv v3, v1, v2 -> [90, 180]
        vopivv(0x0B, 1, 2, 4), // vxor.vv v4, v1, v2 -> [110, 220]
        vse32(12, 3),
        vse32(13, 4),
        0x00000013, // nop (halt target)
      ])}@100\n64 00 00 00 c8 00 00 00\n@110\n0a 00 00 00 14 00 00 00\n',
      const <Register, int>{},
      vecConfig(),
      nextPc: 0x2C,
      memStates: {
        0x200: 0x000000B40000005A, // vsub: [90, 180]
        0x210: 0x000000DC0000006E, // vxor: [110, 220]
      },
    ),
  );

  // Milestone 2e: LMUL=2 grouping. vsetvli e32,m2 (VLEN=128) -> VLMAX=8, AVL=8
  // -> vl=8. vadd.vv with LMUL=2 spans two consecutive vregs: v6=v2+v4 and
  // v7=v3+v5. The harness vle/vse only touch the low 64 bits (2 e32 lanes) per
  // reg, so observing v7's store proves the register-index loop ran the second
  // register (without grouping v7 would keep its loaded [5,6]).
  test(
    'vadd.vv LMUL=2 spans two vregs (v6=v2+v4, v7=v3+v5)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // v2 src low [1,2]
        iimm(0x108, 0, 0x0, 11), // v3 src low [5,6]
        iimm(0x110, 0, 0x0, 12), // v4 src low [10,20]
        iimm(0x118, 0, 0x0, 13), // v5 src low [50,60]
        iimm(8, 0, 0x0, 14), // x14 = AVL = 8
        iimm(0x200, 0, 0x0, 15), // v6 dst
        iimm(0x208, 0, 0x0, 16), // v7 dst
        vle32(10, 2), // v2 = [1, 2]
        vle32(11, 3), // v3 = [5, 6]
        vle32(12, 4), // v4 = [10, 20]
        vle32(13, 5), // v5 = [50, 60]
        vsetvli(0x11, 14, 1), // vsetvli x1, x14, e32,m2 -> x1 = vl = 8
        vaddvv(2, 4, 6), // vadd.vv v6, v2, v4 (LMUL=2)
        vse32(15, 6), // mem[0x200] = v6 = [11, 22]
        vse32(16, 7), // mem[0x208] = v7 = [55, 66]
        0x00000013, // nop (halt target)
      ])}@100\n01 00 00 00 02 00 00 00 05 00 00 00 06 00 00 00 0a 00 00 00 14 00 00 00 32 00 00 00 3c 00 00 00\n',
      const <Register, int>{Register.x1: 8},
      vecConfig(),
      nextPc: 0x3C,
      memStates: {
        0x200: 0x000000160000000B, // v6 = [11, 22]
        0x208: 0x0000004200000037, // v7 = [55, 66]
      },
    ),
  );

  // Milestone 2g: LMUL=2 group load/store. One vle32.v (m2) fills v2,v3 from
  // 32 contiguous bytes; one vse32.v (m2) writes both back. Round-trips all 8
  // e32 elements across the two-register group in single instructions.
  test(
    'vle32.v + vse32.v LMUL=2 group round-trip (v2,v3)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // src
        iimm(0x200, 0, 0x0, 11), // dst
        iimm(8, 0, 0x0, 12), // AVL = 8
        vsetvli(0x11, 12, 1), // e32, m2 -> vl = 8
        vle32(10, 2), // v2,v3 = mem[0x100..0x11F]
        vse32(11, 2), // mem[0x200..0x21F] = v2,v3
        0x00000013, // nop
      ])}@100\n11 00 00 00 22 00 00 00 33 00 00 00 44 00 00 00 55 00 00 00 66 00 00 00 77 00 00 00 88 00 00 00\n',
      const <Register, int>{Register.x1: 8},
      vecConfig(),
      nextPc: 0x18,
      memStates: {
        0x200: 0x0000002200000011, // v2 low
        0x208: 0x0000004400000033, // v2 high
        0x210: 0x0000006600000055, // v3 low
        0x218: 0x0000008800000077, // v3 high
      },
    ),
  );

  // Milestone 2f: LMUL=2 grouping for FP. vfadd.vv at e32,m2 spans v6=v2+v4 and
  // v7=v3+v5. Floats: v2=[1.0,2.0], v3=[5.0,6.0], v4=[10.0,20.0], v5=[50.0,60.0]
  // -> v6=[11.0,22.0], v7=[55.0,66.0]. IEEE-754 single bit patterns.
  int f32(double d) {
    final bd = ByteData(4)..setFloat32(0, d);
    return bd.getUint32(0);
  }

  test(
    'vfadd.vv LMUL=2 spans two vregs (v6=v2+v4, v7=v3+v5)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // v2 src [1.0, 2.0]
        iimm(0x108, 0, 0x0, 11), // v3 src [5.0, 6.0]
        iimm(0x110, 0, 0x0, 12), // v4 src [10.0, 20.0]
        iimm(0x118, 0, 0x0, 13), // v5 src [50.0, 60.0]
        iimm(8, 0, 0x0, 14), // x14 = AVL = 8
        iimm(0x200, 0, 0x0, 15), // v6 dst
        iimm(0x208, 0, 0x0, 16), // v7 dst
        vle32(10, 2),
        vle32(11, 3),
        vle32(12, 4),
        vle32(13, 5),
        vsetvli(0x11, 14, 1), // e32, m2 -> vl = 8
        vopfvv(0x00, 2, 4, 6), // vfadd.vv v6, v2, v4 (LMUL=2)
        vse32(15, 6), // mem[0x200] = v6 = [11.0, 22.0]
        vse32(16, 7), // mem[0x208] = v7 = [55.0, 66.0]
        0x00000013, // nop
      ])}@100\n'
      '${[1.0, 2.0, 5.0, 6.0, 10.0, 20.0, 50.0, 60.0].map((d) {
        final v = f32(d);
        return List.generate(4, (b) => ((v >> (b * 8)) & 0xFF).toRadixString(16).padLeft(2, '0')).join(' ');
      }).join(' ')}\n',
      const <Register, int>{Register.x1: 8},
      vecConfig(),
      nextPc: 0x3C,
      memStates: {
        0x200: (f32(22.0) << 32) | f32(11.0), // v6 = [11.0, 22.0]
        0x208: (f32(66.0) << 32) | f32(55.0), // v7 = [55.0, 66.0]
      },
    ),
  );

  // Milestone 2d: vadd.vx (scalar broadcast) and vadd.vi (immediate broadcast).
  // v1=[100,200]; +x5(=5) -> [105,205]; +imm(3) -> [103,203].
  test(
    'vadd.vx / vadd.vi (scalar + immediate operands)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // v1 src
        iimm(5, 0, 0x0, 5), // x5 = 5 (scalar)
        iimm(0x200, 0, 0x0, 12), // .vx dst
        iimm(0x210, 0, 0x0, 13), // .vi dst
        vle32(10, 1), // v1 = [100, 200]
        vaddvx(1, 5, 2), // vadd.vx v2, v1, x5 -> [105, 205]
        vaddvi(1, 3, 3), // vadd.vi v3, v1, 3  -> [103, 203]
        vse32(12, 2),
        vse32(13, 3),
        0x00000013, // nop (halt target)
      ])}@100\n64 00 00 00 c8 00 00 00\n',
      const <Register, int>{},
      vecConfig(),
      nextPc: 0x28,
      memStates: {
        0x200: 0x000000CD00000069, // [105, 205]
        0x210: 0x000000CB00000067, // [103, 203]
      },
    ),
  );

  // Milestone 3: vfadd.vv / vfmul.vv, per-32-bit-lane FP via the ROHD-HCL units.
  // v1=[1.0,2.0], v2=[3.0,4.0]; add -> [4.0,6.0]; mul -> [3.0,8.0].
  test(
    'vfadd.vv / vfmul.vv (e32 float lanes)',
    timeout: Timeout(Duration(seconds: 180)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // v1 src
        iimm(0x110, 0, 0x0, 11), // v2 src
        iimm(0x200, 0, 0x0, 12), // vfadd dst
        iimm(0x210, 0, 0x0, 13), // vfmul dst
        vle32(10, 1), // v1 = [1.0, 2.0]
        vle32(11, 2), // v2 = [3.0, 4.0]
        vopfvv(0x00, 1, 2, 3), // vfadd.vv v3, v1, v2 -> [4.0, 6.0]
        vopfvv(0x24, 1, 2, 4), // vfmul.vv v4, v1, v2 -> [3.0, 8.0]
        vse32(12, 3),
        vse32(13, 4),
        0x00000013, // nop (halt target)
      ])}@100\n00 00 80 3f 00 00 00 40\n@110\n00 00 40 40 00 00 80 40\n',
      const <Register, int>{},
      vecConfig(),
      nextPc: 0x2C,
      memStates: {
        0x200: 0x40C0000040800000, // [4.0, 6.0]
        0x210: 0x4100000040400000, // [3.0, 8.0]
      },
    ),
  );

  // Milestone 4 (polish): SEW-generic arithmetic driven by vsetvli's vtype.
  // vsetvli e32, then vadd with byte-overflowing values: [200,100]+[100,200]=
  // [300,300]. At SEW=8 (wrong) the low bytes would wrap to [44,44]; at SEW=32
  // (set by vsetvli) the 32-bit lanes give [300,300], proving vtype drives SEW.
  test(
    'SEW-generic: vsetvli e32 makes vadd use 32-bit lanes (300, not 44)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // v1 src
        iimm(0x110, 0, 0x0, 11), // v2 src
        iimm(0x200, 0, 0x0, 12), // dst
        iimm(4, 0, 0x0, 1), // x1 = AVL
        vsetvli(0x10, 1, 0), // vsetvli x0, x1, e32  -> _vtype = e32
        vle32(10, 1), // v1 = [200, 100]
        vle32(11, 2), // v2 = [100, 200]
        vaddvv(1, 2, 3), // v3 = v1 + v2 = [300, 300] (32-bit lanes)
        vse32(12, 3),
        0x00000013, // nop (halt target)
      ])}@100\nc8 00 00 00 64 00 00 00\n@110\n64 00 00 00 c8 00 00 00\n',
      const <Register, int>{},
      vecConfig(),
      nextPc: 0x28,
      memStates: {0x200: 0x0000012C0000012C}, // [300, 300]
    ),
  );

  // Milestone 4b (polish): full-VLEN load/store, the whole 128-bit vreg (both
  // 64-bit chunks), not just the low chunk. Round-trip 4 e32 elements.
  test(
    'vle32.v + vse32.v full-VLEN round-trip (4 elements / 128 bits)',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // src
        iimm(0x200, 0, 0x0, 11), // dst
        vle32(10, 1), // v1 = mem[0x100..0x10F] (128 bits)
        vse32(11, 1), // mem[0x200..0x20F] = v1
        0x00000013, // nop (halt target)
      ])}@100\n11 11 11 11 22 22 22 22 33 33 33 33 44 44 44 44\n',
      {Register.x10: 0x100, Register.x11: 0x200},
      vecConfig(),
      nextPc: 0x14,
      memStates: {
        0x200: 0x2222222211111111, // chunk0: elements 0,1
        0x208: 0x4444444433333333, // chunk1: elements 2,3
      },
    ),
  );

  // Milestone 4c (polish): vl/tail. vsetvli e32 with AVL=2 -> vl=2, so vadd
  // writes only lanes 0,1 (=v1+v2) and leaves lanes 2,3 (the tail) undisturbed
  //, i.e. the preloaded v3 values survive.
  test(
    'vl/tail: vadd with vl=2 leaves the tail (lanes 2,3) undisturbed',
    timeout: Timeout(Duration(seconds: 120)),
    () => coreTest(
      '${prog([
        iimm(0x120, 0, 0x0, 9), // x9 = v3 preload src
        iimm(0x100, 0, 0x0, 10), // x10 = v1 src
        iimm(0x110, 0, 0x0, 11), // x11 = v2 src
        iimm(0x200, 0, 0x0, 12), // x12 = dst
        iimm(2, 0, 0x0, 1), // x1 = AVL = 2
        vle32(9, 3), // v3 = [AAAA0001..AAAA0004] (preload)
        vsetvli(0x10, 1, 0), // vsetvli x0, x1, e32 -> vl=2
        vle32(10, 1), // v1 = [10,20,30,40]
        vle32(11, 2), // v2 = [1,2,3,4]
        vaddvv(1, 2, 3), // v3: lanes 0,1 = v1+v2; lanes 2,3 undisturbed
        vse32(12, 3), // store full v3
        0x00000013, // nop (halt target)
      ])}@100\n0a 00 00 00 14 00 00 00 1e 00 00 00 28 00 00 00\n'
      '@110\n01 00 00 00 02 00 00 00 03 00 00 00 04 00 00 00\n'
      '@120\n01 00 aa aa 02 00 aa aa 03 00 aa aa 04 00 aa aa\n',
      const <Register, int>{},
      vecConfig(),
      nextPc: 0x2C,
      memStates: {
        0x200: 0x000000160000000B, // [11, 22]  (active lanes)
        0x208: 0xAAAA0004AAAA0003, // [AAAA0003, AAAA0004] (tail kept)
      },
    ),
  );

  // Milestone 4d (polish): FP ops respect vl/tail too. vsetvli e32 AVL=2;
  // vfadd lanes 0,1 = v1+v2 (1+10=11, 2+20=22), lanes 2,3 keep preloaded v3.
  test(
    'vl/tail: vfadd with vl=2 leaves the FP tail undisturbed',
    timeout: Timeout(Duration(seconds: 180)),
    () => coreTest(
      '${prog([
        iimm(0x120, 0, 0x0, 9), // x9 = v3 preload
        iimm(0x100, 0, 0x0, 10), // x10 = v1
        iimm(0x110, 0, 0x0, 11), // x11 = v2
        iimm(0x200, 0, 0x0, 12), // x12 = dst
        iimm(2, 0, 0x0, 1), // x1 = AVL = 2
        vle32(9, 3), // v3 = [100,200,300,400]
        vsetvli(0x10, 1, 0), // vl=2
        vle32(10, 1), // v1 = [1,2,3,4]
        vle32(11, 2), // v2 = [10,20,30,40]
        vopfvv(0x00, 1, 2, 3), // vfadd.vv v3, v1, v2 (vl=2)
        vse32(12, 3),
        0x00000013, // nop (halt target)
      ])}@100\n00 00 80 3f 00 00 00 40 00 00 40 40 00 00 80 40\n'
      '@110\n00 00 20 41 00 00 a0 41 00 00 f0 41 00 00 20 42\n'
      '@120\n00 00 c8 42 00 00 48 43 00 00 96 43 00 00 c8 43\n',
      const <Register, int>{},
      vecConfig(),
      nextPc: 0x2C,
      memStates: {
        0x200: 0x41B0000041300000, // [11.0, 22.0]  (active)
        0x208: 0x43C8000043960000, // [300.0, 400.0] (tail kept)
      },
    ),
  );

  // Milestone 4e: vector FP at SEW=64 (FP64 lanes). vsetvli e64 makes vfadd.vv
  // operate on 2x 64-bit lanes. v1=[1.0d,2.0d], v2=[3.0d,4.0d] -> [4.0d,6.0d].
  test(
    'vfadd.vv at SEW=64 (FP64 lanes)',
    timeout: Timeout(Duration(seconds: 180)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10),
        iimm(0x110, 0, 0x0, 11),
        iimm(0x200, 0, 0x0, 12),
        iimm(2, 0, 0x0, 1), // x1 = AVL = 2
        vsetvli(0x18, 1, 0), // e64 -> vl = min(2, VLMAX=2) = 2
        vle32(10, 1), // v1 = [1.0d, 2.0d] (full 128b)
        vle32(11, 2), // v2 = [3.0d, 4.0d]
        vopfvv(0x00, 1, 2, 3), // vfadd.vv v3, v1, v2 -> [4.0d, 6.0d]
        vse32(12, 3),
        0x00000013, // nop (halt target)
      ])}@100\n00 00 00 00 00 00 f0 3f 00 00 00 00 00 00 00 40\n'
      '@110\n00 00 00 00 00 00 08 40 00 00 00 00 00 00 10 40\n',
      const <Register, int>{},
      vecConfig(),
      nextPc: 0x24,
      memStates: {
        0x200: 0x4010000000000000, // 4.0d (lane 0)
        0x208: 0x4018000000000000, // 6.0d (lane 1)
      },
    ),
  );

  // Milestone 4f: Zvfh vector FP at SEW=16 (FP16 half-precision lanes). vsetvli
  // e16 makes vfadd.vv operate on 8x 16-bit lanes. Half bit patterns: 1.0=0x3C00,
  // 2.0=0x4000, 3.0=0x4200, 4.0=0x4400, 6.0=0x4600. v1=[1,2,1,2], v2=[3,4,3,4]
  // -> v3=[4,6,4,6]. Uses vecConfigZvfh (the only core that builds FP16 units).
  test(
    'vfadd.vv at SEW=16 (FP16 lanes, Zvfh)',
    timeout: Timeout(Duration(seconds: 180)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10),
        iimm(0x110, 0, 0x0, 11),
        iimm(0x200, 0, 0x0, 12),
        iimm(8, 0, 0x0, 1), // x1 = AVL = 8 (VLMAX = 128/16 = 8)
        vsetvli(0x08, 1, 0), // e16, m1 -> vl = 8
        vle32(10, 1), // v1 (low 4 lanes = [1.0,2.0,1.0,2.0])
        vle32(11, 2), // v2 (low 4 lanes = [3.0,4.0,3.0,4.0])
        vopfvv(0x00, 1, 2, 3), // vfadd.vv v3, v1, v2 -> [4.0,6.0,4.0,6.0]
        vse32(12, 3),
        0x00000013, // nop (halt target)
      ])}@100\n00 3c 00 40 00 3c 00 40 00 00 00 00 00 00 00 00\n'
      '@110\n00 42 00 44 00 42 00 44 00 00 00 00 00 00 00 00\n',
      const <Register, int>{Register.x1: 8}, // AVL; vsetvli rd=x0 discards vl
      vecConfigZvfh(),
      nextPc: 0x24,
      memStates: {
        // lanes [4.0, 6.0, 4.0, 6.0] = 0x4400,0x4600,0x4400,0x4600 packed LE.
        0x200: 0x4600440046004400,
      },
    ),
  );
}
