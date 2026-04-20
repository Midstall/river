import 'package:river/river.dart';

import 'data.dart';
import 'instr/base.dart';
import 'label.dart';
import 'module.dart';

mixin InstructionSet {
  RiscVIsaConfig get isa;
  Module get currentModule;

  final Map<String, RiscVOperation> _opCache = {};

  RiscVOperation _require(String mnemonic) =>
      _opCache.putIfAbsent(mnemonic, () {
        for (final op in isa.allOperations) {
          if (op.mnemonic == mnemonic) return op;
        }
        throw UnsupportedError(
          '"$mnemonic" not available in ISA ${isa.implementsString}',
        );
      });

  DataField get zero => DataField.zero(module: currentModule);

  DataField _snap(DataField f) {
    if (f.producer != null && f.assignedRegister != null) {
      return f.copyWith(ssaId: currentModule.nextSsaId());
    }
    return f;
  }

  DataField _emitR(String mnemonic, DataField rs1, DataField rs2) {
    final op = _require(mnemonic);
    final out = currentModule.field(rs1.type);
    final instr = Instruction(op, rd: out, rs1: _snap(rs1), rs2: _snap(rs2));
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  DataField _emitI(String mnemonic, DataField rs1, int imm) {
    final op = _require(mnemonic);
    final out = currentModule.field(rs1.type);
    final instr = Instruction(op, rd: out, rs1: _snap(rs1), imm: imm);
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  void _emitS(String mnemonic, DataField base, DataField src, int offset) {
    final op = _require(mnemonic);
    final instr = Instruction(
      op,
      rs1: _snap(base),
      rs2: _snap(src),
      imm: offset,
    );
    currentModule.addInstruction(instr);
  }

  void _emitB(String mnemonic, DataField rs1, DataField rs2, Label target) {
    final op = _require(mnemonic);
    final instr = Instruction(
      op,
      rs1: _snap(rs1),
      rs2: _snap(rs2),
      label: target,
    );
    currentModule.addInstruction(instr);
  }

  DataField _emitU(String mnemonic, int imm) {
    final op = _require(mnemonic);
    final out = currentModule.field(DataType.i32);
    final instr = Instruction(op, rd: out, imm: imm);
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  DataField _emitJ(String mnemonic, Label target) {
    final op = _require(mnemonic);
    final out = currentModule.field(DataType.i32);
    final instr = Instruction(op, rd: out, label: target, hasSideEffects: true);
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  // ── RV32I ALU (R-type) ──
  DataField add(DataField a, DataField b) => _emitR('add', a, b);
  DataField sub(DataField a, DataField b) => _emitR('sub', a, b);
  DataField sll(DataField a, DataField b) => _emitR('sll', a, b);
  DataField slt(DataField a, DataField b) => _emitR('slt', a, b);
  DataField sltu(DataField a, DataField b) => _emitR('sltu', a, b);
  DataField xor(DataField a, DataField b) => _emitR('xor', a, b);
  DataField srl(DataField a, DataField b) => _emitR('srl', a, b);
  DataField sra(DataField a, DataField b) => _emitR('sra', a, b);
  DataField or(DataField a, DataField b) => _emitR('or', a, b);
  DataField and(DataField a, DataField b) => _emitR('and', a, b);

  // ── RV32I ALU (I-type) ──
  DataField addi(DataField a, int imm) => _emitI('addi', a, imm);
  DataField slti(DataField a, int imm) => _emitI('slti', a, imm);
  DataField sltiu(DataField a, int imm) => _emitI('sltiu', a, imm);
  DataField xori(DataField a, int imm) => _emitI('xori', a, imm);
  DataField ori(DataField a, int imm) => _emitI('ori', a, imm);
  DataField andi(DataField a, int imm) => _emitI('andi', a, imm);
  DataField slli(DataField a, int imm) => _emitI('slli', a, imm);
  DataField srli(DataField a, int imm) => _emitI('srli', a, imm);
  DataField srai(DataField a, int imm) => _emitI('srai', a, imm);

  // ── Loads (I-type) ──
  DataField lb(DataField base, {int offset = 0}) => _emitI('lb', base, offset);
  DataField lh(DataField base, {int offset = 0}) => _emitI('lh', base, offset);
  DataField lw(DataField base, {int offset = 0}) => _emitI('lw', base, offset);
  DataField lbu(DataField base, {int offset = 0}) =>
      _emitI('lbu', base, offset);
  DataField lhu(DataField base, {int offset = 0}) =>
      _emitI('lhu', base, offset);

  // ── Stores (S-type) ──
  void sb(DataField base, DataField src, {int offset = 0}) =>
      _emitS('sb', base, src, offset);
  void sh(DataField base, DataField src, {int offset = 0}) =>
      _emitS('sh', base, src, offset);
  void sw(DataField base, DataField src, {int offset = 0}) =>
      _emitS('sw', base, src, offset);
  void sd(DataField base, DataField src, {int offset = 0}) =>
      _emitS('sd', base, src, offset);

  // ── Branches (B-type) ──
  void beq(DataField a, DataField b, Label target) =>
      _emitB('beq', a, b, target);
  void bne(DataField a, DataField b, Label target) =>
      _emitB('bne', a, b, target);
  void blt(DataField a, DataField b, Label target) =>
      _emitB('blt', a, b, target);
  void bge(DataField a, DataField b, Label target) =>
      _emitB('bge', a, b, target);
  void bltu(DataField a, DataField b, Label target) =>
      _emitB('bltu', a, b, target);
  void bgeu(DataField a, DataField b, Label target) =>
      _emitB('bgeu', a, b, target);

  // ── Upper immediate (U-type) ──
  DataField lui(int imm) => _emitU('lui', imm);
  DataField auipc(int imm) => _emitU('auipc', imm);

  // ── Jumps (J-type) ──
  DataField jal(Label target) => _emitJ('jal', target);
  DataField jalr(DataField base, {int offset = 0}) {
    final op = _require('jalr');
    final out = currentModule.field(base.type);
    final instr = Instruction(
      op,
      rd: out,
      rs1: _snap(base),
      imm: offset,
      hasSideEffects: true,
    );
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  // ── CSR (I-type with CSR address as immediate) ──
  DataField csrrw(int csr, DataField rs1) {
    final op = _require('csrrw');
    final out = currentModule.field(rs1.type);
    final instr = Instruction(
      op,
      rd: out,
      rs1: _snap(rs1),
      imm: csr,
      hasSideEffects: true,
    );
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  DataField csrrs(int csr, DataField rs1) {
    final op = _require('csrrs');
    final out = currentModule.field(rs1.type);
    final instr = Instruction(
      op,
      rd: out,
      rs1: _snap(rs1),
      imm: csr,
      hasSideEffects: true,
    );
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  DataField csrrc(int csr, DataField rs1) {
    final op = _require('csrrc');
    final out = currentModule.field(rs1.type);
    final instr = Instruction(
      op,
      rd: out,
      rs1: _snap(rs1),
      imm: csr,
      hasSideEffects: true,
    );
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  // ── M extension (R-type) ──
  DataField mul(DataField a, DataField b) => _emitR('mul', a, b);
  DataField mulh(DataField a, DataField b) => _emitR('mulh', a, b);
  DataField div(DataField a, DataField b) => _emitR('div', a, b);
  DataField divu(DataField a, DataField b) => _emitR('divu', a, b);
  DataField rem(DataField a, DataField b) => _emitR('rem', a, b);
  DataField remu(DataField a, DataField b) => _emitR('remu', a, b);

  // ── F extension (single-precision) ──
  DataField flw(DataField base, {int offset = 0}) =>
      _emitI('flw', base, offset);
  void fsw(DataField base, DataField src, {int offset = 0}) =>
      _emitS('fsw', base, src, offset);
  DataField fadds(DataField a, DataField b) => _emitR('fadd.s', a, b);
  DataField fsubs(DataField a, DataField b) => _emitR('fsub.s', a, b);
  DataField fmuls(DataField a, DataField b) => _emitR('fmul.s', a, b);
  DataField fdivs(DataField a, DataField b) => _emitR('fdiv.s', a, b);
  DataField fsqrts(DataField a) {
    final op = _require('fsqrt.s');
    final out = currentModule.field(DataType.i32);
    final instr = Instruction(op, rd: out, rs1: a);
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  DataField fcvtws(DataField a) {
    final op = _require('fcvt.w.s');
    final out = currentModule.field(DataType.i32);
    final instr = Instruction(op, rd: out, rs1: a);
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  DataField fcvtsw(DataField a) {
    final op = _require('fcvt.s.w');
    final out = currentModule.field(DataType.i32);
    final instr = Instruction(op, rd: out, rs1: a);
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  DataField feqs(DataField a, DataField b) => _emitR('feq.s', a, b);
  DataField flts(DataField a, DataField b) => _emitR('flt.s', a, b);
  DataField fles(DataField a, DataField b) => _emitR('fle.s', a, b);

  // ── D extension (double-precision) ──
  DataField fld(DataField base, {int offset = 0}) =>
      _emitI('fld', base, offset);
  void fsd(DataField base, DataField src, {int offset = 0}) =>
      _emitS('fsd', base, src, offset);
  DataField faddd(DataField a, DataField b) => _emitR('fadd.d', a, b);
  DataField fsubd(DataField a, DataField b) => _emitR('fsub.d', a, b);
  DataField fmuld(DataField a, DataField b) => _emitR('fmul.d', a, b);
  DataField fdivd(DataField a, DataField b) => _emitR('fdiv.d', a, b);
  DataField fsqrtd(DataField a) {
    final op = _require('fsqrt.d');
    final out = currentModule.field(DataType.i64);
    final instr = Instruction(op, rd: out, rs1: a);
    out.producer = instr;
    currentModule.addInstruction(instr);
    return out;
  }

  DataField feqd(DataField a, DataField b) => _emitR('feq.d', a, b);
  DataField fltd(DataField a, DataField b) => _emitR('flt.d', a, b);
  DataField fled(DataField a, DataField b) => _emitR('fle.d', a, b);

  // ── Fence ──
  void fence() {
    final op = _require('fence');
    currentModule.addInstruction(Instruction(op, hasSideEffects: true));
  }

  // ── Labels ──
  Label label(String name) {
    final l = Label(name);
    currentModule.addInstruction(LabelInstruction(l));
    return l;
  }

  void placeLabel(Label l) {
    currentModule.addInstruction(LabelInstruction(l));
  }

  // ── System ──
  void ecall() {
    final op = _require('ecall');
    currentModule.addInstruction(Instruction(op, imm: 0, hasSideEffects: true));
  }

  void ebreak() {
    final op = _require('ebreak');
    currentModule.addInstruction(Instruction(op, imm: 1, hasSideEffects: true));
  }

  void mret() {
    final op = _require('mret');
    currentModule.addInstruction(
      Instruction(op, imm: 0x302, hasSideEffects: true),
    );
  }

  void sret() {
    final op = _require('sret');
    currentModule.addInstruction(
      Instruction(op, imm: 0x102, hasSideEffects: true),
    );
  }

  void wfi() {
    final op = _require('wfi');
    currentModule.addInstruction(
      Instruction(op, imm: 0x105, hasSideEffects: true),
    );
  }

  // ── Pseudo-instructions ──
  DataField li(int imm) {
    if (imm >= -2048 && imm < 2048) return addi(zero, imm);
    // addi sign-extends its low 12 bits, so when bit 11 is set the lui half must
    // round up one page and addi subtracts back. Without the carry, immediates
    // with low-12 >= 0x800 land 0x1000 low.
    var lo = imm & 0xFFF;
    if (lo >= 0x800) lo -= 0x1000;
    final upper = lui((imm - lo) & 0xFFFFF000);
    final value = addi(upper, lo);
    // On RV64 `lui` sign-extends bit 31, so a 32-bit address >= 0x8000_0000
    // materializes as 0xFFFFFFFF_8.... Zero-extend the low 32 bits back; without
    // this a load/store to 0x8000_0000 RAM drives 0xFFFFFFFF_80000000, which the
    // decoder does not match (no ack, core wedges).
    if (isa.mxlen == RiscVMxlen.rv64 && imm > 0x7FFFFFFF && imm <= 0xFFFFFFFF) {
      return srli(slli(value, 32), 32);
    }
    return value;
  }

  DataField mv(DataField src) => addi(src, 0);
  void nop() {
    addi(zero, 0);
  }

  void ret() {
    jalr(currentModule.register(Register.x1));
  }
}
