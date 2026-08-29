import 'package:river/river.dart';

import 'matrix_encoders.dart';
import 'matrix_harness.dart';

/// The instruction table: per-category lists of [MatrixCell]s, parameterized by
/// mxlen for width-applicability. The emulator computes the expected result, so
/// a cell only declares the encoding + operands + which reg to observe.
///
/// Standard 2-operand cell: seed x1=a, x2=b, run [instr] (rs1=1, rs2=2, rd=3),
/// then compare x3 to the emulator golden.
MatrixCell _op(String name, int instr, {int a = -5, int b = 3}) => MatrixCell(
  name,
  [iimm(a, 0, 0x0, 1), iimm(b, 0, 0x0, 2), instr, nop],
  checkRegs: [Register.x3],
  nextPc: 0x0C,
);

/// Single-operand cell (e.g. clz/sext.b): seed x1=a via an addi, run [instr]
/// (rs1=x1, rd=x3), check x3. An 8-nop tail lets the result retire before the
/// halt and keeps the dual fetcher from running off the end.
MatrixCell _unary(String name, int instr, {required int a}) => MatrixCell(
  name,
  [iimm(a, 0, 0x0, 1), instr, ...List.filled(8, nop)],
  checkRegs: [Register.x3],
  nextPc: 0x28,
);

/// Program-built 2-operand cell: [setup] instructions construct x1/x2 (used for
/// values out of a 12-bit immediate's range, e.g. INT_MIN via addi+slli), then
/// [instr] runs (rs1=1, rs2=2, rd=3) and x3 is checked. Operands are built with
/// real instructions rather than the backdoor seed map so there is no seeding
/// race with the running pipeline. The 8-nop tail mirrors [_unary] so the OoO
/// dual fetcher does not run off the end before the result retires.
MatrixCell _opProg(String name, List<int> setup, int instr) {
  final program = [...setup, instr, ...List.filled(8, nop)];
  return MatrixCell(
    name,
    program,
    checkRegs: [Register.x3],
    nextPc: 4 * program.length,
  );
}

/// addi rd, x0, imm (load a small signed immediate).
int _li(int imm, int rd) => iimm(imm, 0, 0x0, rd);

/// slli rd, rs, shamt.
int _slli(int shamt, int rs, int rd) => iimm(shamt, rs, 0x1, rd);

/// Build `1 << bit` into x1 with addi + chained slli. Each shift amount is
/// kept <= 31 so bit 25 (shamt[5]) is never set: a strict RV32-style decoder
/// reads bits[31:25] as funct7 and rejects slli with a non-zero funct7, so a
/// single `slli 63` would decode illegal. Chained shifts of <= 31 stay legal
/// under both the rv32 and rv64 shift encodings.
List<int> _oneShl(int bit) {
  final out = [_li(1, 1)];
  var remaining = bit;
  while (remaining > 0) {
    final step = remaining > 31 ? 31 : remaining;
    out.add(_slli(step, 1, 1));
    remaining -= step;
  }
  return out;
}

/// Look up a category's instruction cells for an mxlen.
List<MatrixCell> instructionsFor(String category, RiscVMxlen mxlen) =>
    switch (category) {
      'base' => baseAlu(mxlen),
      'm' => mExtension(mxlen),
      'bitmanip' => bitmanip(mxlen),
      'zicond' => zicond(mxlen),
      'a' => atomics(mxlen),
      'zacas' => zacas(mxlen),
      'loadstore' => loadStore(mxlen),
      'branch' => controlFlow(mxlen),
      'csr' => csrOps(mxlen),
      'fd' => fdOps(mxlen),
      'd' => dOps(mxlen),
      'v' => vOps(mxlen),
      _ => throw ArgumentError('no instruction table for category "$category"'),
    };

/// V vector (in-order; uses vector loads/stores - OoO mem FU incomplete). Each
/// cell sets e32/m1 (VLEN=128 -> vl=4 elements), loads two vectors from dataMem
/// via vle32, runs the op, stores the result via vse32, and checks the two
/// 64-bit result words (4x32-bit elements). The emulator computes the golden.
List<MatrixCell> vOps(RiscVMxlen mxlen) {
  const v1 = [10, 20, 30, 40];
  const v2 = [3, 5, 7, 9];
  // vsetvli x1,x0,e32m1 (vl=VLMAX=4); x10/x11 = src bases, x12 = dst base.
  List<int> prologue() => [
    vsetvli(0x10, 0, 1),
    iimm(0x100, 0, 0x0, 10),
    iimm(0x120, 0, 0x0, 11),
    iimm(0x200, 0, 0x0, 12),
    vle32(10, 1), // v1 = mem[0x100..]
    vle32(11, 2), // v2 = mem[0x120..]
  ];
  // vector-vector op v3 = v1 OP v2, stored to mem[0x200].
  MatrixCell vv(String name, int funct6) => MatrixCell(
    name,
    [
      ...prologue(),
      vopivv(funct6, 2, 1, 3),
      vse32(12, 3),
      ...List.filled(8, nop),
    ],
    dataMem: {0x100: v1, 0x120: v2},
    checkMem: [0x200, 0x208],
    nextPc: 0x40,
  );
  return [
    vv('vadd.vv', 0x00),
    vv('vsub.vv', 0x02),
    vv('vand.vv', 0x09),
    vv('vor.vv', 0x0A),
    vv('vxor.vv', 0x0B),
    vv('vminu.vv', 0x04),
    vv('vmin.vv', 0x05),
    vv('vmaxu.vv', 0x06),
    vv('vmax.vv', 0x07),
    vv('vsll.vv', 0x25),
    vv('vsrl.vv', 0x28),
    // vadd.vx: v3 = v1 + x13 (scalar broadcast).
    MatrixCell(
      'vadd.vx',
      [
        vsetvli(0x10, 0, 1),
        iimm(0x100, 0, 0x0, 10),
        iimm(0x200, 0, 0x0, 12),
        iimm(7, 0, 0x0, 13), // scalar 7
        vle32(10, 1),
        vopivx(0x00, 1, 13, 3), // vadd.vx v3, v1, x13
        vse32(12, 3),
        ...List.filled(8, nop),
      ],
      dataMem: {0x100: v1},
      checkMem: [0x200, 0x208],
      nextPc: 0x3C,
    ),
    // vadd.vi: v3 = v1 + imm5 (5).
    MatrixCell(
      'vadd.vi',
      [
        vsetvli(0x10, 0, 1),
        iimm(0x100, 0, 0x0, 10),
        iimm(0x200, 0, 0x0, 12),
        vle32(10, 1),
        vopivi(0x00, 1, 5, 3), // vadd.vi v3, v1, 5
        vse32(12, 3),
        ...List.filled(8, nop),
      ],
      dataMem: {0x100: v1},
      checkMem: [0x200, 0x208],
      nextPc: 0x38,
    ),
  ];
}

/// D double-precision (rv64 only - 64-bit doubles + fmv.x.d need 64-bit GPRs;
/// rv32 FP doesn't elaborate, task #71). Same shape as [fdOps]: FS-enable
/// prologue, load 64-bit doubles via fld (little-endian word pairs in dataMem),
/// run the op, move bits to a GPR via fmv.x.d (funct7 0x71) to check.
List<MatrixCell> dOps(RiscVMxlen mxlen) {
  // 2.0d = 0x4000000000000000, 4.0d = 0x4010000000000000 (low word, high word).
  const mem = [0x00000000, 0x40000000, 0x00000000, 0x40100000];
  final fsOn = [lui(0x6, 5), csr(0x300, 5, 0x2, 0)];
  MatrixCell arith(String name, int funct7, {int f3sel = 0x0}) => MatrixCell(
    name,
    [
      ...fsOn,
      iimm(0x200, 0, 0x0, 2),
      fld(0, 2, 1), // f1 = 2.0d
      fld(8, 2, 2), // f2 = 4.0d
      fpOp(funct7, 2, 1, f3sel, 3),
      fpOp(0x71, 0, 3, 0x0, 3), // fmv.x.d x3, f3
      ...List.filled(8, nop),
    ],
    dataMem: {0x200: mem},
    checkRegs: [Register.x3],
    nextPc: 0x3C,
  );
  MatrixCell cmp(String name, int f3) => MatrixCell(
    name,
    [
      ...fsOn,
      iimm(0x200, 0, 0x0, 2),
      fld(0, 2, 1),
      fld(8, 2, 2),
      fpOp(0x51, 2, 1, f3, 3), // feq/flt/fle.d x3, f1, f2
      ...List.filled(8, nop),
    ],
    dataMem: {0x200: mem},
    checkRegs: [Register.x3],
    nextPc: 0x38,
  );
  return [
    arith('fadd.d', 0x01),
    arith('fsub.d', 0x05),
    arith('fmul.d', 0x09),
    arith('fdiv.d', 0x0D),
    arith('fmin.d', 0x15, f3sel: 0x0),
    arith('fmax.d', 0x15, f3sel: 0x1),
    cmp('feq.d', 0x2),
    cmp('flt.d', 0x1),
    cmp('fle.d', 0x0),
    // fcvt.w.d x3, f1 : double -> signed int (2.0 -> 2).
    MatrixCell(
      'fcvt.w.d',
      [
        ...fsOn,
        iimm(0x200, 0, 0x0, 2),
        fld(0, 2, 1),
        fpOp(0x61, 0, 1, 0x0, 3), // fcvt.w.d x3, f1
        ...List.filled(8, nop),
      ],
      dataMem: {0x200: mem},
      checkRegs: [Register.x3],
      nextPc: 0x34,
    ),
    // fcvt.d.w f3, x1 : int -> double (5 -> 5.0d), then bits to x3.
    MatrixCell(
      'fcvt.d.w',
      [
        ...fsOn,
        iimm(5, 0, 0x0, 1),
        fpOp(0x69, 0, 1, 0x0, 3), // fcvt.d.w f3, x1
        fpOp(0x71, 0, 3, 0x0, 3), // fmv.x.d x3, f3
        ...List.filled(8, nop),
      ],
      checkRegs: [Register.x3],
      nextPc: 0x34,
    ),
    // fcvt.s.d f3, f1 : double -> single (rs2=1 selects .d source), bits to x3.
    MatrixCell(
      'fcvt.s.d',
      [
        ...fsOn,
        iimm(0x200, 0, 0x0, 2),
        fld(0, 2, 1),
        fpOp(0x20, 1, 1, 0x0, 3), // fcvt.s.d f3, f1
        fpOp(0x70, 0, 3, 0x0, 3), // fmv.x.w x3, f3
        ...List.filled(8, nop),
      ],
      dataMem: {0x200: mem},
      checkRegs: [Register.x3],
      nextPc: 0x38,
    ),
  ];
}

/// F/D single-precision. FP needs mstatus.FS enabled or FP ops trap, so every
/// cell starts with `lui x5,0x6 ; csrrs mstatus,x5` (FS=Dirty). Operands are FP
/// bit patterns loaded from dataMem; results are moved to a GPR via fmv.x.w (the
/// raw bits) and checked there, with the emulator computing the golden.
List<MatrixCell> fdOps(RiscVMxlen mxlen) {
  const a = 0x40000000; // 2.0f
  const b = 0x40800000; // 4.0f
  // Prologue: enable FP (mstatus.FS = 0b11). x5 = 0x6000, csrrs mstatus, x5.
  final fsOn = [lui(0x6, 5), csr(0x300, 5, 0x2, 0)];
  // f1 = mem[0x200], f2 = mem[0x204], f3 = f1 OP f2, x3 = bits(f3). [f3sel] is
  // the rounding mode for true arithmetic (RNE=0) or the min/max selector.
  MatrixCell arith(String name, int funct7, {int f3sel = 0x0}) => MatrixCell(
    name,
    [
      ...fsOn,
      iimm(0x200, 0, 0x0, 2),
      flw(0, 2, 1),
      flw(4, 2, 2),
      fpOp(funct7, 2, 1, f3sel, 3), // OP.s f3, f1, f2
      fpOp(0x70, 0, 3, 0x0, 3), // fmv.x.w x3, f3
      ...List.filled(8, nop),
    ],
    dataMem: {
      0x200: [a, b],
    },
    checkRegs: [Register.x3],
    nextPc: 0x3C,
  );
  // Comparisons write a GPR (0/1) directly.
  MatrixCell cmp(String name, int f3) => MatrixCell(
    name,
    [
      ...fsOn,
      iimm(0x200, 0, 0x0, 2),
      flw(0, 2, 1),
      flw(4, 2, 2),
      fpOp(0x50, 2, 1, f3, 3), // feq/flt/fle.s x3, f1, f2
      ...List.filled(8, nop),
    ],
    dataMem: {
      0x200: [a, b],
    },
    checkRegs: [Register.x3],
    nextPc: 0x38,
  );
  return [
    arith('fadd.s', 0x00),
    arith('fsub.s', 0x04),
    arith('fmul.s', 0x08),
    arith('fdiv.s', 0x0C),
    arith('fmin.s', 0x14, f3sel: 0x0), // funct7 0x14, funct3 0 = fmin
    arith('fmax.s', 0x14, f3sel: 0x1), // funct3 1 = fmax
    cmp('feq.s', 0x2),
    cmp('flt.s', 0x1),
    cmp('fle.s', 0x0),
    // fcvt.w.s x3, f1 : float -> signed int (2.0 -> 2).
    MatrixCell(
      'fcvt.w.s',
      [
        ...fsOn,
        iimm(0x200, 0, 0x0, 2),
        flw(0, 2, 1),
        fpOp(0x60, 0, 1, 0x0, 3), // fcvt.w.s x3, f1 (rs2=0 selects .w)
        ...List.filled(8, nop),
      ],
      dataMem: {
        0x200: [a],
      },
      checkRegs: [Register.x3],
      nextPc: 0x34,
    ),
    // fcvt.s.w f3, x1 : int -> float (5 -> 5.0), then bits to x3.
    MatrixCell(
      'fcvt.s.w',
      [
        ...fsOn,
        iimm(5, 0, 0x0, 1),
        fpOp(0x68, 0, 1, 0x0, 3), // fcvt.s.w f3, x1
        fpOp(0x70, 0, 3, 0x0, 3), // fmv.x.w x3, f3
        ...List.filled(8, nop),
      ],
      checkRegs: [Register.x3],
      nextPc: 0x34,
    ),
  ];
}

/// Zicsr round-trips through mscratch (a plain read/write CSR, no side effects).
/// CSR ops are multi-cycle + serialized on OoO, so each cell ends with a read
/// into a check reg and carries an 8-nop tail.
List<MatrixCell> csrOps(RiscVMxlen mxlen) {
  const mscratch = 0x340;
  const rpipelinectl = 0x7C3;
  const rpipelinecap = 0xFC0;
  return [
    // csrrw: write x1=0x42 to mscratch (discard old into x0), read back -> x3.
    MatrixCell(
      'csrrw',
      [
        iimm(0x42, 0, 0x0, 1),
        csr(mscratch, 1, 0x1, 0), // csrrw x0, mscratch, x1
        csr(mscratch, 0, 0x2, 3), // csrrs x3, mscratch, x0 (read)
        ...List.filled(8, nop),
      ],
      checkRegs: [Register.x3],
      nextPc: 0x2C,
    ),
    // csrrs: set bit 0; x3 = old (0x42), x4 = new (0x43).
    MatrixCell(
      'csrrs',
      [
        iimm(0x42, 0, 0x0, 1),
        csr(mscratch, 1, 0x1, 0),
        iimm(0x1, 0, 0x0, 2),
        csr(mscratch, 2, 0x2, 3), // csrrs x3, mscratch, x2
        csr(mscratch, 0, 0x2, 4), // read -> x4
        ...List.filled(8, nop),
      ],
      checkRegs: [Register.x3, Register.x4],
      nextPc: 0x34,
    ),
    // csrrc: clear low nibble; x3 = old (0xFF), x4 = new (0xF0).
    MatrixCell(
      'csrrc',
      [
        iimm(0xFF, 0, 0x0, 1),
        csr(mscratch, 1, 0x1, 0),
        iimm(0x0F, 0, 0x0, 2),
        csr(mscratch, 2, 0x3, 3), // csrrc x3, mscratch, x2
        csr(mscratch, 0, 0x2, 4),
        ...List.filled(8, nop),
      ],
      checkRegs: [Register.x3, Register.x4],
      nextPc: 0x34,
    ),
    // csrrwi: write immediate 5, read back -> x3.
    MatrixCell(
      'csrrwi',
      [
        csri(mscratch, 5, 0x5, 0),
        csr(mscratch, 0, 0x2, 3),
        ...List.filled(8, nop),
      ],
      checkRegs: [Register.x3],
      nextPc: 0x28,
    ),
    // rpipelinectl is WARL: write 0xFF, only bits [3:0] stick -> read back 0xF.
    // Verifies the vendor pipeline-control CSR masks identically in emu + HDL.
    MatrixCell(
      'rpipelinectl-warl',
      [
        iimm(0xFF, 0, 0x0, 1), // x1 = 0xFF
        csr(rpipelinectl, 1, 0x1, 0), // csrrw x0, rpipelinectl, x1
        csr(
          rpipelinectl,
          0,
          0x2,
          3,
        ), // csrrs x3, rpipelinectl, x0 (read) -> 0xF
        ...List.filled(8, nop),
      ],
      checkRegs: [Register.x3],
      nextPc: 0x2C,
    ),
    // rpipelinecap is the read-only feature bitmap; emu + HDL both derive it
    // from the same config, so the read must match. (csrrs rs1=x0 reads a RO CSR
    // without trapping now that the HDL suppresses the no-op write, task #76.)
    MatrixCell(
      'rpipelinecap-read',
      [
        csr(rpipelinecap, 0, 0x2, 3), // csrrs x3, rpipelinecap, x0 (read)
        ...List.filled(8, nop),
      ],
      checkRegs: [Register.x3],
      nextPc: 0x24,
    ),
  ];
}

/// An AMO cell: x10=addr, x11=operand, mem[addr]=memInit; run [instr] (rd=x12
/// gets the old value), check x12 + mem. [seed] lets amocas pre-set x12.
MatrixCell _amo(
  String name,
  int instr, {
  required int memInit,
  Map<Register, int> seed = const {},
  int operand = 5,
}) => MatrixCell(
  name,
  [iimm(0x100, 0, 0x0, 10), iimm(operand, 0, 0x0, 11), instr, nop],
  seed: seed,
  dataMem: {
    0x100: [memInit],
  },
  checkRegs: [Register.x12],
  checkMem: [0x100],
  nextPc: 0x10,
);

/// Base integer ALU: OP + OP-IMM (+ OP-32 / OP-IMM-32 on rv64).
List<MatrixCell> baseAlu(RiscVMxlen mxlen) => [
  _op('add', rtype(0x00, 2, 1, 0x0, 3)),
  _op('sub', rtype(0x20, 2, 1, 0x0, 3)),
  _op('sll', rtype(0x00, 2, 1, 0x1, 3)),
  _op('slt', rtype(0x00, 2, 1, 0x2, 3)),
  _op('sltu', rtype(0x00, 2, 1, 0x3, 3)),
  _op('xor', rtype(0x00, 2, 1, 0x4, 3)),
  _op('srl', rtype(0x00, 2, 1, 0x5, 3)),
  _op('sra', rtype(0x20, 2, 1, 0x5, 3)),
  _op('or', rtype(0x00, 2, 1, 0x6, 3)),
  _op('and', rtype(0x00, 2, 1, 0x7, 3)),
  _op('addi', iimm(7, 1, 0x0, 3)),
  _op('andi', iimm(0x0F, 1, 0x7, 3)),
  _op('ori', iimm(0x0F, 1, 0x6, 3)),
  _op('xori', iimm(0x0F, 1, 0x4, 3)),
  _op('slti', iimm(0, 1, 0x2, 3)),
  _op('sltiu', iimm(0, 1, 0x3, 3)),
  _op('slli', iimm(3, 1, 0x1, 3)),
  _op('srli', iimm(3, 1, 0x5, 3)),
  _op('srai', iimm(0x403, 1, 0x5, 3)), // shamt=3, funct6=0x10
  // Sign-extended (negative) OP-IMM immediates: the 12-bit imm sign-extends
  // to xlen before the op (folded from core_parity_test's OP-IMM subtest).
  _op('addi neg imm', iimm(-100, 1, 0x0, 3)),
  _op('ori neg imm', iimm(-1, 1, 0x6, 3)), // ori with all-ones imm
  _op('andi neg imm', iimm(-16, 1, 0x7, 3)),
  // lui/auipc are single-result ops: an 8-nop tail lets the result retire
  // and keeps the (dual) fetcher from running off the end into zero memory.
  MatrixCell(
    'lui',
    [lui(0x12345, 3), ...List.filled(8, nop)],
    checkRegs: [Register.x3],
    nextPc: 0x24,
  ),
  MatrixCell(
    'auipc',
    [auipc(0x1, 3), ...List.filled(8, nop)],
    checkRegs: [Register.x3],
    nextPc: 0x24,
  ),
  if (mxlen == RiscVMxlen.rv64) ...[
    _op('addw', rtypeW(0x00, 2, 1, 0x0, 3)),
    _op('subw', rtypeW(0x20, 2, 1, 0x0, 3)),
    _op('sllw', rtypeW(0x00, 2, 1, 0x1, 3)),
    _op('srlw', rtypeW(0x00, 2, 1, 0x5, 3)),
    _op('sraw', rtypeW(0x20, 2, 1, 0x5, 3)),
    _op('addiw', iimmW(7, 1, 0x0, 3)),
  ],
];

/// M extension: mul/div family + signed div/rem edge cases.
List<MatrixCell> mExtension(RiscVMxlen mxlen) => [
  _op('mul', rtype(0x01, 2, 1, 0x0, 3)),
  _op('mulh', rtype(0x01, 2, 1, 0x1, 3)),
  _op('mulhsu', rtype(0x01, 2, 1, 0x2, 3)),
  _op('mulhu', rtype(0x01, 2, 1, 0x3, 3)),
  _op('div', rtype(0x01, 2, 1, 0x4, 3)),
  _op('divu', rtype(0x01, 2, 1, 0x5, 3)),
  _op('rem', rtype(0x01, 2, 1, 0x6, 3)),
  _op('remu', rtype(0x01, 2, 1, 0x7, 3)),
  _op('div by zero', rtype(0x01, 0, 1, 0x4, 3)), // x1 / x0
  _op('rem by zero', rtype(0x01, 0, 1, 0x6, 3)),
  if (mxlen == RiscVMxlen.rv64) ...[
    _op('mulw', rtypeW(0x01, 2, 1, 0x0, 3)),
    _op('divw', rtypeW(0x01, 2, 1, 0x4, 3)),
    _op('divuw', rtypeW(0x01, 2, 1, 0x5, 3)),
    _op('remw', rtypeW(0x01, 2, 1, 0x6, 3)),
    _op('remuw', rtypeW(0x01, 2, 1, 0x7, 3)),
  ],
  // Signed-overflow corner: INT_MIN / -1. div must return INT_MIN and rem 0
  // (no trap). INT_MIN is built with addi+slli since it is out of a 12-bit
  // immediate's range. The emulator computes the golden; the divider only has
  // to match it. x1 = INT_MIN, x2 = -1 (or 7 for the wide-unsigned probes).
  ...() {
    final signBit = mxlen == RiscVMxlen.rv64 ? 63 : 31;
    return [
      _opProg('div overflow', [
        ..._oneShl(signBit),
        _li(-1, 2),
      ], rtype(0x01, 2, 1, 0x4, 3)),
      _opProg('rem overflow', [
        ..._oneShl(signBit),
        _li(-1, 2),
      ], rtype(0x01, 2, 1, 0x6, 3)),
      // Full-width unsigned: large dividend / small divisor exercises the top
      // quotient bits the small-operand cells never set.
      _opProg('divu wide', [
        ..._oneShl(signBit),
        _li(7, 2),
      ], rtype(0x01, 2, 1, 0x5, 3)),
      _opProg('remu wide', [
        ..._oneShl(signBit),
        _li(7, 2),
      ], rtype(0x01, 2, 1, 0x7, 3)),
      if (mxlen == RiscVMxlen.rv64) ...[
        // 32-bit overflow: INT32_MIN / -1 through the W ops.
        _opProg('divw overflow', [
          ..._oneShl(31),
          _li(-1, 2),
        ], rtypeW(0x01, 2, 1, 0x4, 3)),
        _opProg('remw overflow', [
          ..._oneShl(31),
          _li(-1, 2),
        ], rtypeW(0x01, 2, 1, 0x6, 3)),
      ],
      // Multiply edge cases that stress the FULL 2*XLEN product and the
      // signed-high sign corrections (mulh/mulhsu) beyond the default -5*3 cell,
      // which only sign-extends. INT_MIN and all-ones operands set the high word
      // and flip the correction terms. The emulator computes the golden; the
      // iterative multiplier only has to match. (x1=INT_MIN, x2=-1.)
      ...() {
        final signBit = mxlen == RiscVMxlen.rv64 ? 63 : 31;
        final intMin = [..._oneShl(signBit), _li(-1, 2)]; // x1=INT_MIN, x2=-1
        return [
          _opProg('mulh int_min*-1', intMin, rtype(0x01, 2, 1, 0x1, 3)),
          _opProg('mulhu int_min*-1', intMin, rtype(0x01, 2, 1, 0x3, 3)),
          _opProg('mulhsu int_min*-1', intMin, rtype(0x01, 2, 1, 0x2, 3)),
          _opProg('mul int_min*-1', intMin, rtype(0x01, 2, 1, 0x0, 3)),
        ];
      }(),
    ];
  }(),
];

/// Zba/Zbb/Zbs R-type bit-manipulation ops.
List<MatrixCell> bitmanip(RiscVMxlen mxlen) => [
  _op('andn', rtype(0x20, 2, 1, 0x7, 3)),
  _op('orn', rtype(0x20, 2, 1, 0x6, 3)),
  _op('xnor', rtype(0x20, 2, 1, 0x4, 3)),
  _op('min', rtype(0x05, 2, 1, 0x4, 3)),
  _op('max', rtype(0x05, 2, 1, 0x6, 3)),
  _op('minu', rtype(0x05, 2, 1, 0x5, 3)),
  _op('maxu', rtype(0x05, 2, 1, 0x7, 3)),
  _op('sh1add', rtype(0x10, 2, 1, 0x2, 3)),
  _op('sh2add', rtype(0x10, 2, 1, 0x4, 3)),
  _op('sh3add', rtype(0x10, 2, 1, 0x6, 3)),
  _op('bset', rtype(0x14, 2, 1, 0x1, 3), a: 1, b: 5),
  _op('bclr', rtype(0x24, 2, 1, 0x1, 3), a: 0xFF, b: 3),
  _op('binv', rtype(0x34, 2, 1, 0x1, 3), a: 0xFF, b: 3),
  _op('bext', rtype(0x24, 2, 1, 0x5, 3), a: 0xFF, b: 3),
  _op('rol', rtype(0x30, 2, 1, 0x1, 3)),
  _op('ror', rtype(0x30, 2, 1, 0x5, 3)),
  // Unary Zbb (rs2 field is a function selector, not a register; rs1=x1).
  _unary('clz', rtype(0x30, 0x0, 1, 0x1, 3), a: 1), // count leading zeros
  _unary('ctz', rtype(0x30, 0x1, 1, 0x1, 3), a: 8), // count trailing zeros
  _unary('cpop', rtype(0x30, 0x2, 1, 0x1, 3), a: 0xFF), // popcount
  _unary('sext.b', rtype(0x30, 0x4, 1, 0x1, 3), a: 0x80),
  _unary('sext.h', rtype(0x30, 0x5, 1, 0x1, 3), a: 0x8000),
  if (mxlen == RiscVMxlen.rv64) ...[
    _unary('clzw', rtypeW(0x30, 0x0, 1, 0x1, 3), a: 1),
    _unary('ctzw', rtypeW(0x30, 0x1, 1, 0x1, 3), a: 8),
    _unary('cpopw', rtypeW(0x30, 0x2, 1, 0x1, 3), a: 0xFF),
  ],
];

/// Zicond: conditional-zero (czero.eqz / czero.nez), funct7 0x07, opcode OP.
/// Both the take and skip directions of the condition are covered.
List<MatrixCell> zicond(RiscVMxlen mxlen) => [
  // czero.eqz: rd = (rs2 == 0) ? 0 : rs1
  _op('czero.eqz rs2!=0', rtype(0x07, 2, 1, 0x5, 3), a: 0x1234, b: 7),
  _op('czero.eqz rs2==0', rtype(0x07, 0, 1, 0x5, 3), a: 0x1234),
  // czero.nez: rd = (rs2 != 0) ? 0 : rs1
  _op('czero.nez rs2!=0', rtype(0x07, 2, 1, 0x7, 3), a: 0x1234, b: 7),
  _op('czero.nez rs2==0', rtype(0x07, 0, 1, 0x7, 3), a: 0x1234),
];

/// LR/SC cell: lr.X reserves (x12 = mem), sc.X stores 42 (x13 = 0 success);
/// check the loaded value, the success flag, and the written memory.
MatrixCell _lrsc(String name, int f3) => MatrixCell(
  name,
  [
    iimm(0x100, 0, 0x0, 10), // x10 = addr
    iimm(42, 0, 0x0, 11), // x11 = store value
    amo(0x02, 0, 10, f3, 12), // lr.X  x12 = mem[x10], reserve
    amo(0x03, 11, 10, f3, 13), // sc.X  mem[x10] = x11, x13 = 0 on success
    nop,
  ],
  dataMem: {
    0x100: [77],
  },
  checkRegs: [Register.x12, Register.x13],
  checkMem: [0x100],
  nextPc: 0x14,
);

/// A extension: AMO read-modify-write (.w on all widths, .d on rv64) + LR/SC.
List<MatrixCell> atomics(RiscVMxlen mxlen) => [
  _amo('amoadd.w', amo(0x00, 11, 10, 0x2, 12), memInit: 100),
  _amo('amoswap.w', amo(0x01, 11, 10, 0x2, 12), memInit: 100),
  _amo('amoxor.w', amo(0x04, 11, 10, 0x2, 12), memInit: 0xF0),
  _amo('amoand.w', amo(0x0C, 11, 10, 0x2, 12), memInit: 0xFF),
  _amo('amoor.w', amo(0x08, 11, 10, 0x2, 12), memInit: 0xF0),
  _amo(
    'amomin.w',
    amo(0x10, 11, 10, 0x2, 12),
    memInit: -100,
    operand: 5,
  ), // signed/unsigned-differing operands
  _amo(
    'amomax.w',
    amo(0x14, 11, 10, 0x2, 12),
    memInit: -100,
    operand: 5,
  ), // signed/unsigned-differing operands
  _amo(
    'amominu.w',
    amo(0x18, 11, 10, 0x2, 12),
    memInit: -100,
    operand: 5,
  ), // signed/unsigned-differing operands
  _amo(
    'amomaxu.w',
    amo(0x1C, 11, 10, 0x2, 12),
    memInit: -100,
    operand: 5,
  ), // signed/unsigned-differing operands
  _lrsc('lr/sc.w', 0x2),
  // Ordered lr.w.aq / sc.w.rl: the aq/rl bits (funct7[1:0]) are ordering hints,
  // decode-transparent, and run identically on the in-order core. Guards the
  // HW-found delta bug where sc.w.rl (funct7=0x0D) raised illegal because the
  // decoder matched the full funct7 instead of funct5. Same result as lr/sc.w.
  MatrixCell(
    'lr.w.aq/sc.w.rl',
    [
      iimm(0x100, 0, 0x0, 10), // x10 = addr
      iimm(42, 0, 0x0, 11), // x11 = store value
      amo(0x02, 0, 10, 0x2, 12) | (1 << 26), // lr.w.aq x12 = mem, reserve
      amo(0x03, 11, 10, 0x2, 13) | (1 << 25), // sc.w.rl x13 = 0 (ok), mem = 42
      nop,
    ],
    dataMem: {
      0x100: [77],
    },
    checkRegs: [Register.x12, Register.x13],
    checkMem: [0x100],
    nextPc: 0x14,
  ),
  // sc-fail edge: a 2nd sc.w must FAIL (x14=1) since the 1st cleared the
  // reservation (folded from core_parity_test's LR/SC subtest).
  MatrixCell(
    'lr/sc.w fail',
    [
      iimm(0x100, 0, 0x0, 10),
      iimm(42, 0, 0x0, 11),
      amo(0x02, 0, 10, 0x2, 12), // lr.w  x12 = mem, reserve
      amo(0x03, 11, 10, 0x2, 13), // sc.w x13 = 0 (ok), mem = 42
      amo(0x03, 11, 10, 0x2, 14), // sc.w x14 = 1 (fail)
      nop,
    ],
    dataMem: {
      0x100: [7],
    },
    checkRegs: [Register.x12, Register.x13, Register.x14],
    checkMem: [0x100],
    nextPc: 0x18,
  ),
  if (mxlen == RiscVMxlen.rv64) ...[
    _amo('amoadd.d', amo(0x00, 11, 10, 0x3, 12), memInit: 100),
    _amo('amoswap.d', amo(0x01, 11, 10, 0x3, 12), memInit: 100),
    _amo('amoxor.d', amo(0x04, 11, 10, 0x3, 12), memInit: 0xF0),
    _amo('amoand.d', amo(0x0C, 11, 10, 0x3, 12), memInit: 0xFF),
    _amo('amoor.d', amo(0x08, 11, 10, 0x3, 12), memInit: 0xF0),
    _amo(
      'amomin.d',
      amo(0x10, 11, 10, 0x3, 12),
      memInit: -100,
      operand: 5,
    ), // signed/unsigned-differing operands
    _amo(
      'amomax.d',
      amo(0x14, 11, 10, 0x3, 12),
      memInit: -100,
      operand: 5,
    ), // signed/unsigned-differing operands
    _amo(
      'amominu.d',
      amo(0x18, 11, 10, 0x3, 12),
      memInit: -100,
      operand: 5,
    ), // signed/unsigned-differing operands
    _amo(
      'amomaxu.d',
      amo(0x1C, 11, 10, 0x3, 12),
      memInit: -100,
      operand: 5,
    ), // signed/unsigned-differing operands
    _lrsc('lr/sc.d', 0x3),
  ],
];

/// amocas cell: x12 holds the compare value (and gets the old value back),
/// x11 is the swap value. Swap happens only when mem == compare.
MatrixCell _amocas(
  String name,
  int f3, {
  required int memInit,
  required int compare,
  int swap = 0x55,
}) => MatrixCell(
  name,
  [
    iimm(0x100, 0, 0x0, 10),
    iimm(swap, 0, 0x0, 11),
    amo(0x05, 11, 10, f3, 12),
    nop,
  ],
  seed: {Register.x12: compare},
  dataMem: {
    0x100: [memInit],
  },
  checkRegs: [Register.x12],
  checkMem: [0x100],
  nextPc: 0x10,
);

/// Zacas: amocas.w/.d compare-and-swap, both the match (swap) and no-match
/// (leave) outcomes.
List<MatrixCell> zacas(RiscVMxlen mxlen) => [
  _amocas('amocas.w match', 0x2, memInit: 77, compare: 77),
  _amocas('amocas.w nomatch', 0x2, memInit: 77, compare: 12),
  if (mxlen == RiscVMxlen.rv64) ...[
    _amocas('amocas.d match', 0x3, memInit: 77, compare: 77),
    _amocas('amocas.d nomatch', 0x3, memInit: 77, compare: 12),
  ],
];

/// Load cell: x2 = base 0x200, mem[0x200] = [lo, hi]; load x3 = mem[base+0],
/// check x3 (the emulator handles the sign/zero extension per width).
MatrixCell _load(String name, int f3, {required int lo, int hi = 0}) =>
    MatrixCell(
      name,
      [iimm(0x200, 0, 0x0, 2), load(0, 2, f3, 3), nop],
      dataMem: {
        0x200: [lo, hi],
      },
      checkRegs: [Register.x3],
      nextPc: 0x0C,
    );

/// Store cell: x1 = value (seeded), x2 = base 0x200; store x1 -> mem[base+0],
/// then check the written memory.
MatrixCell _store(String name, int f3, {required int value}) => MatrixCell(
  name,
  [iimm(0x200, 0, 0x0, 2), store(0, 1, 2, f3), nop],
  seed: {Register.x1: value},
  checkMem: [0x200],
  nextPc: 0x0C,
);

/// Loads + stores. Sign/zero extension is exercised with high-bit values;
/// width-only ops (ld/lwu/sd) are gated to rv64.
List<MatrixCell> loadStore(RiscVMxlen mxlen) => [
  _load('lb sign', 0x0, lo: 0x80),
  _load('lb pos', 0x0, lo: 0x7F),
  _load('lh sign', 0x1, lo: 0x8000),
  _load('lw', 0x2, lo: 0x12345678),
  _load('lbu', 0x4, lo: 0x80),
  _load('lhu', 0x5, lo: 0x8000),
  _store('sb', 0x0, value: 0x9A),
  _store('sh', 0x1, value: 0xBEEF),
  _store('sw', 0x2, value: 0x12345678),
  if (mxlen == RiscVMxlen.rv64) ...[
    _load('lw sign', 0x2, lo: 0x80000000),
    _load('lwu', 0x6, lo: 0x80000000),
    _load('ld', 0x3, lo: 0x89ABCDEF, hi: 0x01234567),
    _store('sd', 0x3, value: 0x0123456789ABCDEF),
  ],
];

/// Eight-nop tail so a taken redirect / misprediction-recovery fully drains
/// before the harness samples nextPc (mirrors core_bpred_test: never make the
/// branch target itself the halt PC, that races the redirect).
List<int> get _tail => List.filled(8, nop);

/// A conditional-branch cell, modeled on the proven bpred layout. x1=a, x2=b are
/// set by program instrs (NOT backdoor seed: the single write-port seed only
/// reliably lands one reg). The branch at 0x8 skips x3=99 (0xC) when taken and
/// lands on the x4=7 target (0x10); both paths converge through the nop tail to
/// nextPc=0x34. x3 (=0 taken / 99 fall-through) distinguishes the two paths.
MatrixCell _branch(String name, int f3, {required int a, required int b}) =>
    MatrixCell(
      name,
      [
        iimm(a, 0, 0x0, 1), // 0x0: x1 = a
        iimm(b, 0, 0x0, 2), // 0x4: x2 = b
        branch(8, 2, 1, f3), // 0x8: if cond, pc -> 0x10 (skip 0xC)
        iimm(99, 0, 0x0, 3), // 0xC: x3 = 99 (fall-through only)
        iimm(7, 0, 0x0, 4), // 0x10: x4 = 7 (branch target / converge)
        ..._tail, // 0x14..0x30
      ],
      checkRegs: [Register.x3],
      nextPc: 0x34,
    );

/// Branches (both directions) plus jal / jalr.
List<MatrixCell> controlFlow(RiscVMxlen mxlen) => [
  _branch('beq taken', 0x0, a: 5, b: 5),
  _branch('beq fall', 0x0, a: 5, b: 6),
  _branch('bne taken', 0x1, a: 5, b: 6),
  _branch('bne fall', 0x1, a: 5, b: 5),
  _branch('blt taken', 0x4, a: -1, b: 1),
  _branch('blt fall', 0x4, a: 1, b: -1),
  _branch('bge taken', 0x5, a: 1, b: -1),
  _branch('bge fall', 0x5, a: -1, b: 1),
  _branch('bltu taken', 0x6, a: 1, b: 2),
  _branch('bltu fall', 0x6, a: 2, b: 1),
  _branch('bgeu taken', 0x7, a: 2, b: 1),
  _branch('bgeu fall', 0x7, a: 1, b: 2),
  // Sign-differing operands: -1 is the largest UNSIGNED value, so unsigned
  // and signed ordering disagree. Distinguishes bltu/bgeu from blt/bge and
  // catches the "unsigned compare folded to signed" class of bug.
  _branch('bltu big', 0x6, a: -1, b: 1), // -1 >=u 1 -> not taken
  _branch('bltu small', 0x6, a: 1, b: -1), // 1 <u -1 -> taken
  _branch('bgeu big', 0x7, a: -1, b: 1), // -1 >=u 1 -> taken
  _branch('bgeu small', 0x7, a: 1, b: -1), // 1 <u -1 -> not taken
  // jal x3, +8: link x3 = 0x4, jump to 0x8 skipping the x4=99 filler.
  MatrixCell(
    'jal',
    [jal(8, 3), iimm(99, 0, 0x0, 4), iimm(7, 0, 0x0, 2), ..._tail],
    checkRegs: [Register.x3, Register.x4],
    nextPc: 0x2C,
  ),
  // jalr x3, 8(x0): jump to 0x8, link x3 = 0x4, skipping x4=99.
  MatrixCell(
    'jalr',
    [jalr(8, 0, 3), iimm(99, 0, 0x0, 4), iimm(7, 0, 0x0, 2), ..._tail],
    checkRegs: [Register.x3, Register.x4],
    nextPc: 0x2C,
  ),
];
