import 'package:river/river.dart';

import 'matrix_encoders.dart';
import 'matrix_harness.dart';

/// Curated golden vectors: small programs whose architectural results are
/// HAND-VERIFIED here (not emulator-computed). [runGolden] asserts both the
/// emulator and the HDL match these. See [GoldenCell] for why this complements
/// the parity matrix. Expected values are written for the value's signed Dart
/// form; the harness compares the low xlen bits, so rv32 sign-extension matches.

/// An 8-nop tail (result retires + dual fetcher stays in valid memory).
List<int> get _tail => List.filled(8, nop);

/// In-order golden vectors: arithmetic, shifts, M, memory round-trip, sub-word
/// sign-extending load, lui. No taken branches (in-order has no predictor).
/// Config should enable M (e.g. matrixConfig(mxlen, inOrder, 'm')).
List<GoldenCell> inOrderGolden(RiscVMxlen mxlen) => [
  // x1=10, x2=20, x3=x1+x2=30, x4=x2-x1=10.
  GoldenCell(
    'add/sub',
    [
      iimm(10, 0, 0x0, 1),
      iimm(20, 0, 0x0, 2),
      rtype(0x00, 2, 1, 0x0, 3), // add  x3 = x1 + x2
      rtype(0x20, 1, 2, 0x0, 4), // sub  x4 = x2 - x1
      ..._tail,
    ],
    expectedRegs: {Register.x3: 30, Register.x4: 10},
    nextPc: 0x24,
  ),
  // x1=1, x2 = x1 << 4 = 16; x3 = x2 >> 2 = 4.
  GoldenCell(
    'shift',
    [
      iimm(1, 0, 0x0, 1),
      iimm(4, 1, 0x1, 2), // slli x2 = x1 << 4 = 16
      iimm(2, 2, 0x5, 3), // srli x3 = x2 >> 2 = 4
      ..._tail,
    ],
    expectedRegs: {Register.x2: 16, Register.x3: 4},
    nextPc: 0x2C,
  ),
  // x1=7, x2=6, x3 = x1*x2 = 42 (M extension).
  GoldenCell(
    'mul',
    [
      iimm(7, 0, 0x0, 1),
      iimm(6, 0, 0x0, 2),
      rtype(0x01, 2, 1, 0x0, 3), // mul x3 = 42
      ..._tail,
    ],
    expectedRegs: {Register.x3: 42},
    nextPc: 0x28,
  ),
  // mem[0x200] low byte = 0x80; lb sign-extends to -128; lbu zero-ext = 128.
  GoldenCell(
    'load sign/zero extend',
    [
      iimm(0x200, 0, 0x0, 2), // x2 = 0x200
      load(0, 2, 0x0, 1), // lb  x1 = sext(mem[0x200]) = -128
      load(0, 2, 0x4, 3), // lbu x3 = zext(mem[0x200]) = 128
      ..._tail,
    ],
    dataMem: {
      0x200: [0x80],
    },
    expectedRegs: {Register.x1: -128, Register.x3: 128},
    nextPc: 0x2C,
  ),
  // store-then-load round trip: mem[0x200] = 0x55, x3 reads it back.
  GoldenCell(
    'store/load round trip',
    [
      iimm(0x55, 0, 0x0, 1), // x1 = 0x55
      iimm(0x200, 0, 0x0, 2), // x2 = 0x200
      store(0, 1, 2, 0x2), // sw x1 -> mem[0x200]
      load(0, 2, 0x2, 3), // lw x3 = mem[0x200]
      ..._tail,
    ],
    expectedRegs: {Register.x3: 0x55},
    expectedMem: {0x200: 0x55},
    nextPc: 0x30,
  ),
  // lui x1 = 0x12345 << 12 = 0x12345000.
  GoldenCell(
    'lui',
    [lui(0x12345, 1), ..._tail],
    expectedRegs: {Register.x1: 0x12345000},
    nextPc: 0x24,
  ),
];

/// A branch golden cell: x1=a, x2=b; branch (funct3 [f3]) at 0x8 either skips
/// x3=99 (taken -> x3 stays 0) or falls through (x3=99). [expectTaken] is the
/// hand-verified direction.
GoldenCell _bgolden(
  String name,
  int f3, {
  required int a,
  required int b,
  required bool expectTaken,
}) => GoldenCell(
  name,
  [
    iimm(a, 0, 0x0, 1),
    iimm(b, 0, 0x0, 2),
    branch(8, 2, 1, f3),
    iimm(99, 0, 0x0, 3),
    iimm(7, 0, 0x0, 4),
    ..._tail,
  ],
  expectedRegs: {Register.x3: expectTaken ? 0 : 99},
  nextPc: 0x34,
);

/// Branch golden vectors (need a predictor -> OoO config). The unsigned cases
/// use -1 (largest unsigned) vs 1, where signed and unsigned ordering DISAGREE,
/// so these independently pin both the HDL BLT/BGE and the emulator bltu/bgeu
/// comparisons against hand-verified truth.
List<GoldenCell> branchGolden(RiscVMxlen mxlen) => [
  _bgolden('beq equal', 0x0, a: 5, b: 5, expectTaken: true),
  _bgolden('bne equal', 0x1, a: 5, b: 5, expectTaken: false),
  // signed: -1 < 1 is true.
  _bgolden('blt signed', 0x4, a: -1, b: 1, expectTaken: true),
  _bgolden('bge signed', 0x5, a: -1, b: 1, expectTaken: false),
  // unsigned: -1 (=max unsigned) >=u 1, so bltu NOT taken, bgeu taken.
  _bgolden('bltu big-vs-1', 0x6, a: -1, b: 1, expectTaken: false),
  _bgolden('bgeu big-vs-1', 0x7, a: -1, b: 1, expectTaken: true),
  // unsigned: 1 <u -1 (=max), so bltu taken, bgeu NOT taken.
  _bgolden('bltu 1-vs-big', 0x6, a: 1, b: -1, expectTaken: true),
  _bgolden('bgeu 1-vs-big', 0x7, a: 1, b: -1, expectTaken: false),
];
