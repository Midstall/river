import 'package:harbor/harbor.dart';

/// A decoded RISC-V instruction with extracted fields.
///
/// Provides rd, rs1, rs2, and immediate values extracted from
/// the raw instruction bits based on the operation's format.
class DecodedInstruction {
  final int raw;
  final int rd;
  final int rs1;
  final int rs2;
  // Third source register (R4-type fused multiply-add only); 0 otherwise.
  final int rs3;
  final int imm;

  const DecodedInstruction({
    required this.raw,
    this.rd = 0,
    this.rs1 = 0,
    this.rs2 = 0,
    this.rs3 = 0,
    this.imm = 0,
  });

  Map<String, int> toMap() => {
    'rd': rd,
    'rs1': rs1,
    'rs2': rs2,
    'rs3': rs3,
    'imm': imm,
  };

  /// Decode a 32-bit instruction using the operation's format.
  factory DecodedInstruction.from32(int raw, RiscVOperation op) {
    final fields = op.format.decode(raw);
    final rd = fields['rd'] ?? 0;
    final rs1 = fields['rs1'] ?? 0;
    final rs2 = fields['rs2'] ?? 0;
    final rs3 = fields['rs3'] ?? 0;
    final imm = _extractImm32(raw, fields);
    return DecodedInstruction(
      raw: raw,
      rd: rd,
      rs1: rs1,
      rs2: rs2,
      rs3: rs3,
      imm: imm,
    );
  }

  /// Decode a compressed (16-bit) instruction.
  factory DecodedInstruction.fromCompressed(int raw, RiscVOperation op) {
    final fields = op.format.decode(raw);

    // Compressed formats use different field names
    int rd = fields['rd'] ?? fields['rd_rs1'] ?? 0;
    int rs1 = fields['rs1'] ?? fields['rd_rs1'] ?? 0;
    int rs2 = fields['rs2'] ?? 0;

    // Handle prime registers (3-bit, maps to x8-x15)
    if (fields.containsKey('rd_prime')) rd = (fields['rd_prime']! & 0x7) + 8;
    if (fields.containsKey('rs1_prime')) rs1 = (fields['rs1_prime']! & 0x7) + 8;
    if (fields.containsKey('rs2_prime')) rs2 = (fields['rs2_prime']! & 0x7) + 8;
    if (fields.containsKey('rd_rs1_prime')) {
      rd = (fields['rd_rs1_prime']! & 0x7) + 8;
      rs1 = rd;
    }

    // Implicit registers (x1 link for c.jal/c.jalr; x2/sp base for the
    // stack-pointer-relative ops) override the encoded fields.
    if (op.fixedRd != null) rd = op.fixedRd!;
    if (op.fixedRs1 != null) rs1 = op.fixedRs1!;
    if (op.fixedRs2 != null) rs2 = op.fixedRs2!;

    // Compressed immediates are per-instruction bit-scrambles (op.immKind),
    // descrambled by the shared Harbor RVC engine. Register-only ops have no
    // immKind; a few legacy formats expose contiguous imm fields.
    final int imm;
    if (op.immKind != null) {
      imm = decodeRvcImm(op.immKind!, raw);
    } else if (fields.containsKey('imm_hi')) {
      imm = (fields['imm_hi']! << 5) | (fields['imm_lo'] ?? 0);
    } else {
      imm = fields['imm'] ?? fields['imm_lo'] ?? 0;
    }

    return DecodedInstruction(raw: raw, rd: rd, rs1: rs1, rs2: rs2, imm: imm);
  }

  /// Auto-detect instruction width and decode.
  factory DecodedInstruction.decode(int raw, RiscVOperation op) {
    if ((raw & 0x3) != 0x3) {
      return DecodedInstruction.fromCompressed(raw & 0xFFFF, op);
    }
    return DecodedInstruction.from32(raw, op);
  }

  static int _extractImm32(int raw, Map<String, int> fields) {
    final opcode = raw & 0x7F;
    return switch (opcode) {
      // U-type: LUI, AUIPC
      0x37 || 0x17 => (raw & 0xFFFFF000).toSigned(32),
      // J-type: JAL
      0x6F => _jImm(raw),
      // B-type: branches
      0x63 => _bImm(raw),
      // S-type: stores
      0x23 || 0x27 => _sImm(raw),
      // R-type: no immediate (OP, OP-32, AMO)
      0x33 || 0x3B || 0x2F => 0,
      // I-type: everything else with immediate
      _ => (raw >> 20).toSigned(12),
    };
  }

  static int _sImm(int raw) {
    final hi = (raw >> 25) & 0x7F;
    final lo = (raw >> 7) & 0x1F;
    return ((hi << 5) | lo).toSigned(12);
  }

  static int _bImm(int raw) {
    final b12 = (raw >> 31) & 1;
    final b11 = (raw >> 7) & 1;
    final b10_5 = (raw >> 25) & 0x3F;
    final b4_1 = (raw >> 8) & 0xF;
    return ((b12 << 12) | (b11 << 11) | (b10_5 << 5) | (b4_1 << 1)).toSigned(
      13,
    );
  }

  static int _jImm(int raw) {
    final b20 = (raw >> 31) & 1;
    final b19_12 = (raw >> 12) & 0xFF;
    final b11 = (raw >> 20) & 1;
    final b10_1 = (raw >> 21) & 0x3FF;
    return ((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1)).toSigned(
      21,
    );
  }

  @override
  String toString() =>
      'DecodedInstruction(0x${raw.toRadixString(16)}, rd: $rd, rs1: $rs1, rs2: $rs2, imm: $imm)';
}

/// Extension to add helper methods for paging mode lookup.
extension RiscVPagingModeExt on RiscVPagingMode {
  /// PPN field shift within PTE at the given level.
  int ppnShift(int level) => 10 + ppnBits.take(level).fold(0, (a, b) => a + b);

  /// PPN field shift within physical address at the given level.
  int ppnPhysShift(int level) =>
      12 + ppnBits.take(level).fold(0, (a, b) => a + b);
}

/// Find a paging mode by its satp MODE field value.
RiscVPagingMode? pagingModeFromId(int id) {
  for (final mode in RiscVPagingMode.values) {
    if (mode.id == id) return mode;
  }
  return null;
}
