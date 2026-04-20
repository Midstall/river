import 'package:harbor/harbor.dart';

class BitRange {
  final int start;
  final int end;

  const BitRange(this.start, this.end);
  const BitRange.single(this.start) : end = start;

  int get width => end - start + 1;
  int get mask => (1 << width) - 1;

  BigInt get bigMask => (BigInt.one << width) - BigInt.one;

  int encode(int value) => (value & mask) << start;
  int decode(int value) => (value >> start) & mask;

  BigInt bigEncode(BigInt value) => (value & bigMask) << start;
  BigInt bigDecode(BigInt value) => (value >> start) & bigMask;
}

class BitStruct {
  final Map<String, BitRange> mapping;

  const BitStruct(this.mapping);

  Map<String, int> decode(int value) {
    final result = <String, int>{};
    mapping.forEach((name, range) {
      result[name] = range.decode(value);
    });
    return result;
  }

  int encode(Map<String, int> fields) {
    int result = 0;
    fields.forEach((name, val) {
      final range = mapping[name]!;
      result |= range.encode(val);
    });
    return result;
  }

  Map<String, int> bigDecode(BigInt value) {
    final result = <String, int>{};
    mapping.forEach((name, range) {
      result[name] = range.bigDecode(value).toInt();
    });
    return result;
  }

  BigInt bigEncode(Map<String, int> fields) {
    BigInt result = BigInt.zero;
    fields.forEach((name, val) {
      final range = mapping[name]!;
      result |= range.bigEncode(BigInt.from(val));
    });
    return result;
  }

  int get mask {
    var map = <String, int>{};
    for (final field in mapping.entries) {
      map[field.key] = field.value.mask;
    }
    return encode(map);
  }

  int get width {
    var i = 0;
    mapping.forEach((name, val) {
      i = (val.end + 1) > i ? (val.end + 1) : i;
    });
    return i;
  }
}

int signExtend(int value, int bits) {
  final mask = (1 << bits) - 1;
  value &= mask;
  final signBit = 1 << (bits - 1);
  if ((value & signBit) != 0) {
    return value | ~mask;
  } else {
    return value;
  }
}

/// Encoding entry for a single micro-op type in the ROM.
class MicroOpEncoding {
  final String name;
  final int funct;
  final BitStruct Function(RiscVMxlen) struct;
  final Map<String, int> Function(RiscVMicroOp) toMap;

  const MicroOpEncoding({
    required this.name,
    required this.funct,
    required this.struct,
    required this.toMap,
  });

  BigInt encodeMop(RiscVMicroOp op, RiscVMxlen mxlen) =>
      struct(mxlen).bigEncode(toMap(op));
}

/// Decode pattern for matching instructions in hardware.
class OperationDecodePattern {
  final int mask;
  final int value;
  final int opIndex;
  final int type;
  final int nzfMask;
  final int zfMask;

  const OperationDecodePattern(
    this.mask,
    this.value,
    this.opIndex,
    this.type,
    this.nzfMask,
    this.zfMask,
  );

  OperationDecodePattern copyWith({int? opIndex, int? type}) =>
      OperationDecodePattern(
        mask,
        value,
        opIndex ?? this.opIndex,
        type ?? this.type,
        nzfMask,
        zfMask,
      );

  Map<String, int> toMap() => {
    'mask': mask,
    'value': value,
    'opIndex': opIndex,
    'type': type,
    'nzfMask': nzfMask,
    'zfMask': zfMask,
  };

  BigInt encode(int opIndexWidth, int typeWidth) =>
      struct(opIndexWidth, typeWidth).bigEncode(toMap());

  static BitStruct struct(int opIndexWidth, int typeWidth) {
    final mapping = <String, BitRange>{};
    mapping['mask'] = BitRange(0, 31);
    mapping['value'] = BitRange(32, 63);
    mapping['opIndex'] = BitRange(64, 64 + opIndexWidth - 1);
    mapping['type'] = BitRange(
      64 + opIndexWidth,
      64 + opIndexWidth + typeWidth - 1,
    );
    mapping['nzfMask'] = BitRange(
      64 + opIndexWidth + typeWidth,
      64 + opIndexWidth + typeWidth + 31,
    );
    mapping['zfMask'] = BitRange(
      64 + opIndexWidth + typeWidth + 32,
      64 + opIndexWidth + typeWidth + 32 + 31,
    );
    return BitStruct(mapping);
  }
}

/// Microcode ROM builder that works with Harbor's RiscVIsaConfig.
///
/// Takes an ISA configuration and compiles all operations and their
/// microcode sequences into hardware-friendly ROM representations.
class MicrocodeRom {
  final RiscVIsaConfig isa;
  final List<RiscVOperation> operations;
  final Map<OperationDecodePattern, RiscVOperation> map;

  MicrocodeRom(this.isa, {List<MicroOpEncoding> encodings = const []})
    : operations = isa.allOperations,
      map = _buildDecodeMap(isa.allOperations) {
    if (encodings.isNotEmpty) mopEncodings = encodings;
  }

  int get patternWidth {
    final opIdxBits = opIndexWidth;
    final typeBits = _formatNames.length.bitLength;
    return OperationDecodePattern.struct(opIdxBits, typeBits).width;
  }

  int get opIndexWidth =>
      decodeLookup.keys.fold(0, (a, b) => a > b ? a : b).bitLength;

  int mopWidth(RiscVMxlen mxlen) => operations
      .map((op) => _maxMopWidth(op, mxlen))
      .fold(0, (a, b) => a > b ? a : b);

  int mopIndexWidth(RiscVMxlen mxlen) => encodedMops(mxlen).length.bitLength;

  List<BigInt> encodedMops(RiscVMxlen mxlen) => operations
      .map((op) => _encodeMops(op, mxlen))
      .fold([], (a, b) => [...a, ...b]);

  Map<int, OperationDecodePattern> get decodeLookup {
    final result = <int, OperationDecodePattern>{};
    var i = 0;
    for (final e in map.entries) {
      result[i] = e.key.copyWith(opIndex: i);
      i += e.value.microcode.length + 1;
    }
    return result;
  }

  Set<String> get _formatNames {
    final result = <String>{};
    for (final op in operations) {
      result.add(instrType(op));
    }
    return result;
  }

  List<BigInt> get encodedPatterns {
    final opIdxBits = opIndexWidth;
    final typeBits = _formatNames.length.bitLength;
    return decodeLookup.values
        .map((p) => p.encode(opIdxBits, typeBits))
        .toList();
  }

  RiscVOperation? lookup(int instr) {
    for (final entry in map.entries) {
      final nzfMatch =
          entry.key.nzfMask == 0 || (instr & entry.key.nzfMask) != 0;
      final zfMatch = entry.key.zfMask == 0 || (instr & entry.key.zfMask) == 0;
      if ((instr & entry.key.mask) == entry.key.value && nzfMatch && zfMatch) {
        return entry.value;
      }
    }
    return null;
  }

  static Map<OperationDecodePattern, RiscVOperation> _buildDecodeMap(
    List<RiscVOperation> operations,
  ) {
    // Build format name → index mapping
    final formatNames = <String>[];
    for (final op in operations) {
      final name = instrType(op);
      if (!formatNames.contains(name)) formatNames.add(name);
    }

    final result = <OperationDecodePattern, RiscVOperation>{};
    var i = 0;
    for (final op in operations) {
      final typeIndex = formatNames.indexOf(instrType(op));
      final pattern = _buildDecodePattern(op, i, typeIndex);
      result[pattern] = op;
      i += op.microcode.length + 1;
    }
    return result;
  }

  static OperationDecodePattern _buildDecodePattern(
    RiscVOperation op,
    int index,
    int typeIndex,
  ) {
    // Compressed ops live in quadrants 0/1/2 (bits[1:0] != 0b11): opcode is in
    // bits[1:0] and funct3 in bits[15:13]. 32-bit ops have opcode in bits[6:0]
    // and funct3 in bits[14:12]. The two pattern spaces are disjoint because a
    // 32-bit instruction always has bits[1:0] == 0b11.
    final isCompressed = (op.opcode & 0x3) != 0x3;
    int mask;
    int value;
    if (isCompressed) {
      mask = 0x3;
      value = op.opcode & 0x3;
      if (op.funct3 != null) {
        mask |= 0x7 << 13;
        value |= op.funct3! << 13;
      }
    } else {
      mask = 0x7F; // opcode always 7 bits
      value = op.opcode & 0x7F;
      if (op.funct3 != null) {
        mask |= (0x7 << 12);
        value |= (op.funct3! << 12);
      }
      if (op.funct7 != null) {
        // RV64 shift-immediates (slli/srli/srai = OP-IMM, funct3 1/5) encode a
        // 6-bit shamt where bit 25 is shamt[5]; match only funct6 (bits 31:26)
        // so shamt>=32 still decodes. Word variants (slliw/… = OP-IMM-32) keep
        // the 5-bit shamt + full funct7 match.
        final isShiftImm =
            (op.opcode & 0x7F) == 0x13 &&
            (op.funct3 == 0x1 || op.funct3 == 0x5);
        if (isShiftImm) {
          mask |= (0x3F << 26);
          value |= ((op.funct7! >> 1) << 26);
        } else {
          mask |= (0x7F << 25);
          value |= (op.funct7! << 25);
        }
      }
    }

    // Raw-bit discriminators (e.g. c.mv vs c.add differ in bit 12).
    if (op.matchMask != null) {
      mask |= op.matchMask!;
      value |= op.matchValue ?? 0;
    }

    return OperationDecodePattern(
      mask,
      value,
      index,
      typeIndex,
      op.nonZeroMask ?? 0,
      op.zeroMask ?? 0,
    );
  }

  static int _maxMopWidth(RiscVOperation op, RiscVMxlen mxlen) {
    if (op.microcode.isEmpty) return 0;
    return op.microcode
        .map((mop) {
          final enc = _findEncoding(mop);
          if (enc != null) return enc.struct(mxlen).width;
          return _mopFunct(mop).bitLength + 5;
        })
        .fold(0, (a, b) => a > b ? a : b);
  }

  static List<BigInt> _encodeMops(RiscVOperation op, RiscVMxlen mxlen) => [
    BigInt.from(op.microcode.length),
    ...op.microcode.map((mop) {
      final enc = _findEncoding(mop);
      if (enc != null) return enc.encodeMop(mop, mxlen);
      return BigInt.from(_mopFunct(mop));
    }),
  ];

  static MicroOpEncoding? _findEncoding(RiscVMicroOp mop) {
    final funct = _mopFunct(mop);
    try {
      return mopEncodings.firstWhere((e) => e.funct == funct);
    } catch (_) {
      return null;
    }
  }

  /// Register the micro-op encoding table. Must be set before
  /// calling [encodedMops] or [mopWidth].
  static List<MicroOpEncoding> mopEncodings = const [];

  /// Builds a map from format name to the HarborBitStruct for that format.
  Map<String, HarborBitStruct> get typeStructs {
    final result = <String, HarborBitStruct>{};
    for (final op in operations) {
      final name = instrType(op);
      result.putIfAbsent(name, () => op.format);
    }
    return result;
  }

  /// Builds a map of field name -> (format name -> BitRange).
  ///
  /// Extracts all field names from all formats and maps them
  /// to their bit ranges per format type.
  Map<String, Map<String, BitRange>> get fields {
    final result = <String, Map<String, BitRange>>{};
    for (final op in operations) {
      final formatName = instrType(op);
      for (final field in op.format.fields.entries) {
        result.putIfAbsent(field.key, () => {});
        result[field.key]!.putIfAbsent(
          formatName,
          () => BitRange(field.value.start, field.value.end),
        );
      }
    }
    return result;
  }

  /// Map from operation index to the RiscVOperation.
  Map<int, RiscVOperation> get execLookup {
    final result = <int, RiscVOperation>{};
    var i = 0;
    for (final op in map.values) {
      result[i] = op;
      i += op.microcode.length + 1;
    }
    return result;
  }

  /// All operation indices used in the decode map.
  List<int> get opIndices => decodeLookup.keys.toList();

  /// Micro-op sequences for each operation, keyed by opIndex.
  Map<int, ({List<RiscVMicroOp> ops})> get microOpSequences {
    final result = <int, ({List<RiscVMicroOp> ops})>{};
    var i = 0;
    for (final op in map.values) {
      result[i] = (ops: op.microcode);
      i += op.microcode.length + 1;
    }
    return result;
  }

  static String instrType(RiscVOperation op) {
    final fmt = op.format;
    // Use the format name if available (avoids const canonicalization issues)
    if (fmt.name != null) return fmt.name!;
    // Fallback: check for CSR/system I-type variants by field names
    if (fmt.fields.containsKey('csr')) return 'SystemIType';
    return 'Unknown_${fmt.fields.keys.join('_')}';
  }

  static String mopType(MicroOpEncoding enc) => enc.name;

  /// The set of micro-op funct codes this ROM actually emits. Any funct-Case
  /// arm in the dynamic execution unit whose funct is not in this set is dead
  /// logic for this config and can be dropped (it can never be reached).
  Set<int> get emittedFuncts {
    final result = <int>{};
    for (final op in map.values) {
      for (final mop in op.microcode) {
        result.add(_mopFunct(mop));
      }
    }
    return result;
  }

  static int _mopFunct(RiscVMicroOp mop) => switch (mop) {
    RiscVWriteCsr() => 1,
    RiscVReadRegister() => 2,
    RiscVWriteRegister() => 3,
    RiscVAlu() => 5,
    RiscVBranch() => 6,
    RiscVUpdatePc() => 7,
    RiscVMemLoad() => 8,
    RiscVMemStore() => 9,
    RiscVTrapOp() => 10,
    RiscVTlbFenceOp() => 11,
    RiscVTlbInvalidateOp() => 12,
    RiscVFenceOp() => 13,
    RiscVReturnOp() => 14,
    RiscVWriteLinkRegister() => 15,
    RiscVInterruptHold() => 16,
    RiscVLoadReserved() => 17,
    RiscVStoreConditional() => 18,
    RiscVAtomicMemory() => 19,
    RiscVReadCsr() => 22,
    RiscVCopyField() => 23,
    RiscVSetField() => 24,
    RiscVFpuOp() => 25,
    // wfi's wait micro-op. Needs a real funct (not the 0 catch-all, which is the
    // dynamic interpreter's empty padding case) so cycleMicrocode can dispatch it
    // and advance; otherwise wfi stalls the creek path forever.
    RiscVWaitForInterrupt() => 20,
    _ => 0,
  };
}
