import 'package:harbor/harbor.dart';

import '../data.dart';
import '../label.dart';

List<int> encodeAsBytes(int word) => [
  word & 0xFF,
  (word >> 8) & 0xFF,
  (word >> 16) & 0xFF,
  (word >> 24) & 0xFF,
];

class Instruction {
  final RiscVOperation op;
  final DataField? rd;
  final DataField? rs1;
  final DataField? rs2;
  final int? imm;
  final Label? label;
  final bool _hasSideEffects;

  const Instruction(
    this.op, {
    this.rd,
    this.rs1,
    this.rs2,
    this.imm,
    this.label,
    bool hasSideEffects = false,
  }) : _hasSideEffects = hasSideEffects;

  DataField? get output => rd;

  List<DataField> get inputs => [if (rs1 != null) rs1!, if (rs2 != null) rs2!];

  bool get hasSideEffects =>
      _hasSideEffects || op.format == sType || op.format == bType;

  Instruction copyWith({
    DataField? rd,
    DataField? rs1,
    DataField? rs2,
    int? imm,
    Label? label,
  }) => Instruction(
    op,
    rd: rd ?? this.rd,
    rs1: rs1 ?? this.rs1,
    rs2: rs2 ?? this.rs2,
    imm: imm ?? this.imm,
    label: label ?? this.label,
    hasSideEffects: _hasSideEffects,
  );

  Instruction assignOutput(DataField output) => copyWith(rd: output);

  Instruction assignInputs(List<DataField> inputs) {
    switch (inputs.length) {
      case 0:
        return this;
      case 1:
        return copyWith(rs1: inputs[0]);
      default:
        return copyWith(rs1: inputs[0], rs2: inputs[1]);
    }
  }

  int encode({int pc = 0}) {
    final fmt = op.format;
    final rdVal = rd?.assignedRegister?.value ?? 0;
    final rs1Val = rs1?.assignedRegister?.value ?? 0;
    final rs2Val = rs2?.assignedRegister?.value ?? 0;
    final immVal = imm ?? 0;

    if (fmt == rType) {
      final f7 = op.funct7 ?? 0;
      final f3 = op.funct3 ?? 0;
      // System instructions (mret, sret, ecall, etc.) encode funct7+rs2
      // as a fixed value passed via imm
      final rs2Enc = (rd == null && rs1 == null && rs2 == null && imm != null)
          ? (immVal & 0x1F)
          : rs2Val;
      return (f7 << 25) |
          (rs2Enc << 20) |
          (rs1Val << 15) |
          (f3 << 12) |
          (rdVal << 7) |
          op.opcode;
    } else if (fmt == iType) {
      return ((immVal & 0xFFF) << 20) |
          (rs1Val << 15) |
          (op.funct3! << 12) |
          (rdVal << 7) |
          op.opcode;
    } else if (fmt == sType) {
      final immLo = immVal & 0x1F;
      final immHi = (immVal >> 5) & 0x7F;
      return (immHi << 25) |
          (rs2Val << 20) |
          (rs1Val << 15) |
          (op.funct3! << 12) |
          (immLo << 7) |
          op.opcode;
    } else if (fmt == bType) {
      final raw = label != null ? (label!.offset - pc) : immVal;
      final target = raw & 0x1FFF;
      final b12 = (target >> 12) & 1;
      final b11 = (target >> 11) & 1;
      final b10_5 = (target >> 5) & 0x3F;
      final b4_1 = (target >> 1) & 0xF;
      return (b12 << 31) |
          (b10_5 << 25) |
          (rs2Val << 20) |
          (rs1Val << 15) |
          (op.funct3! << 12) |
          (b4_1 << 8) |
          (b11 << 7) |
          op.opcode;
    } else if (fmt == uType) {
      return (immVal & 0xFFFFF000) | (rdVal << 7) | op.opcode;
    } else if (fmt == jType) {
      final raw = label != null ? (label!.offset - pc) : immVal;
      final target = raw & 0x1FFFFF;
      final b20 = (target >> 20) & 1;
      final b19_12 = (target >> 12) & 0xFF;
      final b11 = (target >> 11) & 1;
      final b10_1 = (target >> 1) & 0x3FF;
      return (b20 << 31) |
          (b10_1 << 21) |
          (b11 << 20) |
          (b19_12 << 12) |
          (rdVal << 7) |
          op.opcode;
    }

    throw UnsupportedError('Unknown format for ${op.mnemonic}');
  }

  List<int> toBinary({int pc = 0}) => encodeAsBytes(encode(pc: pc));

  String toAsm() {
    final fmt = op.format;
    final m = op.mnemonic;

    String reg(DataField? f) => f?.assignedRegister?.name ?? 'x0';

    if (fmt == rType) {
      if (rd == null && rs1 == null && rs2 == null) return m;
      return '$m ${reg(rd)}, ${reg(rs1)}, ${reg(rs2)}';
    } else if (fmt == iType) {
      return '$m ${reg(rd)}, ${reg(rs1)}, $imm';
    } else if (fmt == sType) {
      return '$m ${reg(rs2)}, ${imm ?? 0}(${reg(rs1)})';
    } else if (fmt == bType) {
      return '$m ${reg(rs1)}, ${reg(rs2)}, ${label?.name ?? imm}';
    } else if (fmt == uType) {
      return '$m ${reg(rd)}, ${(imm ?? 0) >> 12}';
    } else if (fmt == jType) {
      return '$m ${reg(rd)}, ${label?.name ?? imm}';
    }

    return m;
  }

  @override
  String toString() => toAsm();
}

class LabelInstruction extends Instruction {
  LabelInstruction(Label label)
    : super(_nop, label: label, hasSideEffects: true);

  @override
  int encode({int pc = 0}) => 0;

  @override
  List<int> toBinary({int pc = 0}) => [];

  @override
  String toAsm() => '${label!.name}:';

  static final _nop = RiscVOperation(
    mnemonic: '.label',
    opcode: 0,
    format: rType,
    microcode: [],
  );
}
