import 'helpers.dart';
import 'riscv_isa_base.dart';

/// Full table mapping micro-op funct -> encoder/decoder.
const kMicroOpTable = <MicroOpEncoding>[
  MicroOpEncoding<WriteCsrMicroOp>(
    funct: WriteCsrMicroOp.funct,
    struct: WriteCsrMicroOp.struct,
    constructor: WriteCsrMicroOp.map,
  ),
  MicroOpEncoding<ReadRegisterMicroOp>(
    funct: ReadRegisterMicroOp.funct,
    struct: ReadRegisterMicroOp.struct,
    constructor: ReadRegisterMicroOp.map,
  ),
  MicroOpEncoding<WriteRegisterMicroOp>(
    funct: WriteRegisterMicroOp.funct,
    struct: WriteRegisterMicroOp.struct,
    constructor: WriteRegisterMicroOp.map,
  ),
  MicroOpEncoding<ModifyLatchMicroOp>(
    funct: ModifyLatchMicroOp.funct,
    struct: ModifyLatchMicroOp.struct,
    constructor: ModifyLatchMicroOp.map,
  ),
  MicroOpEncoding<AluMicroOp>(
    funct: AluMicroOp.funct,
    struct: AluMicroOp.struct,
    constructor: AluMicroOp.map,
  ),
  MicroOpEncoding<BranchIfMicroOp>(
    funct: BranchIfMicroOp.funct,
    struct: BranchIfMicroOp.struct,
    constructor: BranchIfMicroOp.map,
  ),
  MicroOpEncoding<UpdatePCMicroOp>(
    funct: UpdatePCMicroOp.funct,
    struct: UpdatePCMicroOp.struct,
    constructor: UpdatePCMicroOp.map,
  ),
  MicroOpEncoding<MemLoadMicroOp>(
    funct: MemLoadMicroOp.funct,
    struct: MemLoadMicroOp.struct,
    constructor: MemLoadMicroOp.map,
  ),
  MicroOpEncoding<MemStoreMicroOp>(
    funct: MemStoreMicroOp.funct,
    struct: MemStoreMicroOp.struct,
    constructor: MemStoreMicroOp.map,
  ),
  MicroOpEncoding<TrapMicroOp>(
    funct: TrapMicroOp.funct,
    struct: TrapMicroOp.struct,
    constructor: TrapMicroOp.map,
  ),
  MicroOpEncoding<TlbFenceMicroOp>(
    funct: TlbFenceMicroOp.funct,
    struct: TlbFenceMicroOp.struct,
    constructor: TlbFenceMicroOp.map,
  ),
  MicroOpEncoding<TlbInvalidateMicroOp>(
    funct: TlbInvalidateMicroOp.funct,
    struct: TlbInvalidateMicroOp.struct,
    constructor: TlbInvalidateMicroOp.map,
  ),
  MicroOpEncoding<FenceMicroOp>(
    funct: FenceMicroOp.funct,
    struct: FenceMicroOp.struct,
    constructor: FenceMicroOp.map,
  ),
  MicroOpEncoding<ReturnMicroOp>(
    funct: ReturnMicroOp.funct,
    struct: ReturnMicroOp.struct,
    constructor: ReturnMicroOp.map,
  ),
  MicroOpEncoding<WriteLinkRegisterMicroOp>(
    funct: WriteLinkRegisterMicroOp.funct,
    struct: WriteLinkRegisterMicroOp.struct,
    constructor: WriteLinkRegisterMicroOp.map,
  ),
  MicroOpEncoding<InterruptHoldMicroOp>(
    funct: InterruptHoldMicroOp.funct,
    struct: InterruptHoldMicroOp.struct,
    constructor: InterruptHoldMicroOp.map,
  ),
  MicroOpEncoding<LoadReservedMicroOp>(
    funct: LoadReservedMicroOp.funct,
    struct: LoadReservedMicroOp.struct,
    constructor: LoadReservedMicroOp.map,
  ),
  MicroOpEncoding<StoreConditionalMicroOp>(
    funct: StoreConditionalMicroOp.funct,
    struct: StoreConditionalMicroOp.struct,
    constructor: StoreConditionalMicroOp.map,
  ),
  MicroOpEncoding<AtomicMemoryMicroOp>(
    funct: AtomicMemoryMicroOp.funct,
    struct: AtomicMemoryMicroOp.struct,
    constructor: AtomicMemoryMicroOp.map,
  ),
  MicroOpEncoding<ValidateFieldMicroOp>(
    funct: ValidateFieldMicroOp.funct,
    struct: ValidateFieldMicroOp.struct,
    constructor: ValidateFieldMicroOp.map,
  ),
  MicroOpEncoding<SetFieldMicroOp>(
    funct: SetFieldMicroOp.funct,
    struct: SetFieldMicroOp.struct,
    constructor: SetFieldMicroOp.map,
  ),
  MicroOpEncoding<ReadCsrMicroOp>(
    funct: ReadCsrMicroOp.funct,
    struct: ReadCsrMicroOp.struct,
    constructor: ReadCsrMicroOp.map,
  ),
];

/// {@category microcode}
class MicroOpEncoding<T extends MicroOp> {
  final int funct;
  final BitStruct Function(Mxlen) struct;
  final T Function(Map<String, int>) constructor;

  const MicroOpEncoding({
    required this.funct,
    required this.struct,
    required this.constructor,
  });

  BigInt encode(T op, Mxlen mxlen) => struct(mxlen).bigEncode(op.toMap());

  T decode(BigInt value, Mxlen mxlen) =>
      constructor(struct(mxlen).bigDecode(value));
}

/// {@category microcode}
sealed class MicroOp {
  const MicroOp();

  Map<String, int> toMap() => {};

  static const functRange = BitRange(0, 4);
}

/// {@category microcode}
enum MicroOpCondition {
  eq(0),
  ne(1),
  lt(2),
  gt(3),
  ge(4),
  le(5);

  const MicroOpCondition(this.value);

  final int value;

  static const int width = 3;
}

/// {@category microcode}
enum MicroOpAluFunct {
  add(0),
  sub(1),
  mul(2),
  and(3),
  or(4),
  xor(5),
  sll(6),
  srl(7),
  sra(8),
  slt(9),
  sltu(10),
  masked(11),
  mulh(12),
  mulhsu(13),
  mulhu(14),
  div(15),
  divu(16),
  rem(17),
  remu(18),
  mulw(19),
  divw(20),
  divuw(21),
  remw(22),
  remuw(23);

  const MicroOpAluFunct(this.value);

  final int value;

  static const int width = 5;
}

/// {@category microcode}
enum MicroOpAtomicFunct {
  add(0),
  swap(1),
  xor(2),
  and(3),
  or(4),
  min(5),
  max(6),
  minu(7),
  maxu(8);

  const MicroOpAtomicFunct(this.value);

  final int value;

  static const int width = 4;
}

/// {@category microcode}
enum MicroOpSource {
  alu(0),
  imm(1),
  rs1(2),
  rs2(3),
  sp(4),
  rd(5),
  pc(6);

  const MicroOpSource(this.value);

  final int value;

  static const int width = 3;
}

/// {@category microcode}
enum MicroOpField {
  rd(0),
  rs1(1),
  rs2(2),
  imm(3),
  pc(4),
  sp(5);

  const MicroOpField(this.value);

  final int value;

  static const int width = 3;
}

/// {@category microcode}
enum MicroOpLink {
  ra(0, Register.x1, null),
  rd(1, null, MicroOpSource.rd);

  const MicroOpLink(this.value, this.reg, this.source);

  final int value;
  final Register? reg;
  final MicroOpSource? source;

  static const int width = 1;
}

/// {@category microcode}
enum MicroOpMemSize {
  byte(0, 1),
  half(1, 2),
  word(2, 4),
  dword(3, 8);

  const MicroOpMemSize(this.value, this.bytes);

  final int value;
  final int bytes;

  int get bits => bytes * 8;

  static const int width = 2;
}

/// {@category microcode}
class WriteCsrMicroOp extends MicroOp {
  final MicroOpField field;
  final MicroOpSource source;
  final int offset;

  const WriteCsrMicroOp(this.field, this.source, {this.offset = 0});

  const WriteCsrMicroOp.map(Map<String, int> m)
    : field = MicroOpField.values[m['field']!],
      source = MicroOpSource.values[m['source']!],
      offset = m['offset'] ?? 0;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'field': field.value,
    'source': source.value,
    'offset': offset,
  };

  @override
  String toString() => 'WriteCsrMicroOp($field, $source, offset: $offset)';

  static const int funct = 1;

  static BitStruct struct(Mxlen mxlen) => BitStruct({
    'funct': MicroOp.functRange,
    'field': const BitRange(5, 7),
    'source': const BitRange(8, 10),
    'offset': BitRange(11, 11 + mxlen.size),
  });
}

/// {@category microcode}
class ReadRegisterMicroOp extends MicroOp {
  final MicroOpField source;
  final int offset;
  final int valueOffset;

  const ReadRegisterMicroOp(
    this.source, {
    this.offset = 0,
    this.valueOffset = 0,
  });

  const ReadRegisterMicroOp.map(Map<String, int> m)
    : source = MicroOpField.values[m['source']!],
      offset = m['offset'] ?? 0,
      valueOffset = m['valueOffset'] ?? 0;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'source': source.value,
    'offset': offset,
    'valueOffset': valueOffset,
  };

  @override
  String toString() =>
      'ReadRegisterMicroOp($source, offset: $offset, valueOffset: $valueOffset)';

  static const int funct = 2;

  static BitStruct struct(Mxlen mxlen) => BitStruct({
    'funct': MicroOp.functRange,
    'source': const BitRange(5, 7),
    'offset': BitRange(8, 8 + mxlen.size - 1),
    'valueOffset': BitRange(8 + mxlen.size, 8 + (mxlen.size * 2) - 1),
  });
}

/// {@category microcode}
class WriteRegisterMicroOp extends MicroOp {
  final MicroOpField field;
  final MicroOpSource source;
  final int offset;
  final int valueOffset;

  const WriteRegisterMicroOp(
    this.field,
    this.source, {
    this.offset = 0,
    this.valueOffset = 0,
  });

  const WriteRegisterMicroOp.map(Map<String, int> m)
    : field = MicroOpField.values[m['field']!],
      source = MicroOpSource.values[m['source']!],
      offset = m['offset'] ?? 0,
      valueOffset = m['valueOffset'] ?? 0;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'field': field.value,
    'source': source.value,
    'offset': offset,
    'valueOffset': valueOffset,
  };

  @override
  String toString() =>
      'WriteRegisterMicroOp($field, $source, offset: $offset, valueOffset: $valueOffset)';

  static const int funct = 3;

  static BitStruct struct(Mxlen mxlen) => BitStruct({
    'funct': MicroOp.functRange,
    'field': const BitRange(5, 7),
    'source': const BitRange(8, 10),
    'offset': BitRange(11, 11 + mxlen.size - 1),
    'valueOffset': BitRange(11 + mxlen.size, 11 + (mxlen.size * 2) - 1),
  });
}

/// {@category microcode}
class ModifyLatchMicroOp extends MicroOp {
  final MicroOpField field;
  final MicroOpSource source;
  final bool replace;

  const ModifyLatchMicroOp(this.field, this.source, this.replace);

  const ModifyLatchMicroOp.map(Map<String, int> m)
    : field = MicroOpField.values[m['field']!],
      source = MicroOpSource.values[m['source']!],
      replace = (m['replace'] ?? 0) != 0;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'field': field.value,
    'source': source.value,
    'replace': replace ? 1 : 0,
  };

  @override
  String toString() => 'ModifyLatchMicroOp($field, $source, $replace)';

  static const int funct = 4;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'field': const BitRange(5, 7),
    'source': const BitRange(8, 10),
    'replace': BitRange.single(11),
  });
}

/// {@category microcode}
class AluMicroOp extends MicroOp {
  final MicroOpAluFunct alu;
  final MicroOpField a;
  final MicroOpField b;

  const AluMicroOp(this.alu, this.a, this.b);

  const AluMicroOp.map(Map<String, int> m)
    : alu = MicroOpAluFunct.values[m['alu']!],
      a = MicroOpField.values[m['a']!],
      b = MicroOpField.values[m['b']!];

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'alu': alu.value,
    'a': a.value,
    'b': b.value,
  };

  @override
  String toString() => 'AluMicroOp($alu, $a, $b)';

  static const int funct = 5;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'alu': const BitRange(5, 9),
    'a': const BitRange(10, 12),
    'b': const BitRange(13, 15),
  });
}

/// {@category microcode}
class BranchIfMicroOp extends MicroOp {
  final MicroOpCondition condition;
  final MicroOpSource target;
  final int offset;
  final MicroOpField? offsetField;

  const BranchIfMicroOp(
    this.condition,
    this.target, {
    this.offset = 0,
    this.offsetField,
  });

  const BranchIfMicroOp.map(Map<String, int> m)
    : condition = MicroOpCondition.values[m['condition']!],
      target = MicroOpSource.values[m['target']!],
      offset = m['offset'] ?? 0,
      offsetField = (m['hasField'] ?? 0) != 0
          ? MicroOpField.values[m['offsetField']!]
          : null;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'condition': condition.value,
    'target': target.value,
    'hasField': offsetField != null ? 1 : 0,
    'offsetField': offsetField?.value ?? 0,
    'offset': offset,
  };

  @override
  String toString() =>
      'BranchIfMicroOp($condition, $target, $offset, $offsetField)';

  static const int funct = 6;

  static BitStruct struct(Mxlen mxlen) => BitStruct({
    'funct': MicroOp.functRange,
    'condition': const BitRange(5, 7),
    'target': const BitRange(8, 10),
    'hasField': const BitRange.single(11),
    'offsetField': const BitRange(12, 14),
    'offset': BitRange(15, 15 + mxlen.size - 1),
  });
}

/// {@category microcode}
class UpdatePCMicroOp extends MicroOp {
  final MicroOpField source;
  final int offset;
  final MicroOpSource? offsetSource;
  final MicroOpField? offsetField;
  final bool absolute;
  final bool align;

  const UpdatePCMicroOp(
    this.source, {
    this.offset = 0,
    this.offsetField,
    this.offsetSource,
    this.absolute = false,
    this.align = false,
  });

  const UpdatePCMicroOp.map(Map<String, int> m)
    : source = MicroOpField.values[m['source']!],
      offset = m['offset'] ?? 0,
      offsetSource = (m['hasSource'] ?? 0) != 0
          ? MicroOpSource.values[m['offsetSource']!]
          : null,
      offsetField = (m['hasField'] ?? 0) != 0
          ? MicroOpField.values[m['offsetField']!]
          : null,
      absolute = (m['absolute'] ?? 0) != 0,
      align = (m['align'] ?? 0) != 0;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'source': source.value,
    'hasSource': offsetSource != null ? 1 : 0,
    'hasField': offsetField != null ? 1 : 0,
    'offsetSource': offsetSource?.value ?? 0,
    'offsetField': offsetField?.value ?? 0,
    'absolute': absolute ? 1 : 0,
    'align': align ? 1 : 0,
    'offset': offset,
  };

  @override
  String toString() =>
      'UpdatePCMicroOp($source, $offset, $offsetField, $offsetSource, absolute: $absolute, align: $align)';

  static const int funct = 7;

  static BitStruct struct(Mxlen mxlen) => BitStruct({
    'funct': MicroOp.functRange,
    'source': const BitRange(5, 8),
    'hasSource': const BitRange.single(9),
    'hasField': const BitRange.single(10),
    'offsetField': const BitRange(11, 13),
    'offsetSource': const BitRange(14, 16),
    'absolute': const BitRange.single(17),
    'align': const BitRange.single(18),
    'offset': BitRange(19, 19 + mxlen.size - 1),
  });
}

/// {@category microcode}
class MemLoadMicroOp extends MicroOp {
  final MicroOpField base;
  final MicroOpMemSize size;
  final bool unsigned;
  final MicroOpField dest;

  const MemLoadMicroOp({
    required this.base,
    required this.size,
    this.unsigned = true,
    required this.dest,
  });

  const MemLoadMicroOp.map(Map<String, int> m)
    : base = MicroOpField.values[m['base']!],
      size = MicroOpMemSize.values[m['size']!],
      unsigned = (m['unsigned'] ?? 0) != 0,
      dest = MicroOpField.values[m['dest']!];

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'base': base.value,
    'dest': dest.value,
    'size': size.value,
    'unsigned': unsigned ? 1 : 0,
  };

  @override
  String toString() =>
      'MemLoadMicroOp($base, $size, ${unsigned ? 'unsigned' : 'signed'}, $dest)';

  static const int funct = 8;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'base': const BitRange(5, 7),
    'dest': const BitRange(8, 10),
    'size': const BitRange(11, 12),
    'unsigned': BitRange.single(13),
  });
}

/// {@category microcode}
class MemStoreMicroOp extends MicroOp {
  final MicroOpField base;
  final MicroOpField src;
  final MicroOpMemSize size;

  const MemStoreMicroOp({
    required this.base,
    required this.src,
    required this.size,
  });

  const MemStoreMicroOp.map(Map<String, int> m)
    : base = MicroOpField.values[m['base']!],
      src = MicroOpField.values[m['src']!],
      size = MicroOpMemSize.values[m['size']!];

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'base': base.value,
    'src': src.value,
    'size': size.value,
  };

  @override
  String toString() => 'MemStoreMicroOp($base, $src, $size)';

  static const int funct = 9;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'base': const BitRange(5, 7),
    'src': const BitRange(8, 10),
    'size': const BitRange(11, 12),
  });
}

/// {@category microcode}
class TrapMicroOp extends MicroOp {
  final Trap kindMachine;
  final Trap? kindSupervisor;
  final Trap? kindUser;

  const TrapMicroOp(this.kindMachine, this.kindSupervisor, this.kindUser);

  const TrapMicroOp.one(this.kindMachine)
    : kindSupervisor = null,
      kindUser = null;

  const TrapMicroOp.map(Map<String, int> m)
    : kindMachine = Trap.values[m['machine']!],
      kindSupervisor = (m['hasSupervisor'] ?? 0) != 0
          ? Trap.values[m['supervisor']!]
          : null,
      kindUser = (m['hasUser'] ?? 0) != 0 ? Trap.values[m['user']!] : null;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'machine': kindMachine.index,
    'supervisor': kindSupervisor?.index ?? kindMachine.index,
    'user': kindSupervisor?.index ?? kindMachine.index,
  };

  @override
  String toString() => 'TrapMicroOp($kindMachine, $kindSupervisor, $kindUser)';

  static const int funct = 10;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'machine': const BitRange(5, 9),
    'supervisor': const BitRange(10, 14),
    'user': const BitRange(15, 19),
  });
}

/// {@category microcode}
class TlbFenceMicroOp extends MicroOp {
  const TlbFenceMicroOp();

  const TlbFenceMicroOp.map(Map<String, int> _);

  @override
  Map<String, int> toMap() => {'funct': funct};

  @override
  String toString() => 'TlbFenceMicroOp()';

  static const int funct = 11;

  static BitStruct struct(Mxlen _) => BitStruct({'funct': MicroOp.functRange});
}

/// {@category microcode}
class TlbInvalidateMicroOp extends MicroOp {
  final MicroOpField addrField;
  final MicroOpField asidField;

  const TlbInvalidateMicroOp({
    required this.addrField,
    required this.asidField,
  });

  const TlbInvalidateMicroOp.map(Map<String, int> m)
    : addrField = MicroOpField.values[m['addrField']!],
      asidField = MicroOpField.values[m['asidField']!];

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'addrField': addrField.value,
    'asidField': asidField.value,
  };

  @override
  String toString() =>
      'TlbInvalidateMicroOp(addrField: $addrField, asidField: $asidField)';

  static const int funct = 12;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'addrField': const BitRange(5, 8),
    'asidField': const BitRange(9, 12),
  });
}

/// {@category microcode}
class FenceMicroOp extends MicroOp {
  const FenceMicroOp();

  const FenceMicroOp.map(Map<String, int> _);

  @override
  Map<String, int> toMap() => {'funct': funct};

  @override
  String toString() => 'FenceMicroOp()';

  static const int funct = 13;

  static BitStruct struct(Mxlen _) => BitStruct({'funct': MicroOp.functRange});
}

/// {@category microcode}
class ReturnMicroOp extends MicroOp {
  final PrivilegeMode mode;

  const ReturnMicroOp(this.mode);

  ReturnMicroOp.map(Map<String, int> m)
    : mode = PrivilegeMode.find(m['mode']!)!;

  @override
  Map<String, int> toMap() => {'funct': funct, 'mode': mode.id};

  @override
  String toString() => 'ReturnMicroOp($mode)';

  static const int funct = 14;

  static BitStruct struct(Mxlen _) =>
      BitStruct({'funct': MicroOp.functRange, 'mode': const BitRange(5, 7)});
}

/// {@category microcode}
class WriteLinkRegisterMicroOp extends MicroOp {
  final MicroOpLink link;
  final int pcOffset;

  const WriteLinkRegisterMicroOp({required this.link, required this.pcOffset});

  const WriteLinkRegisterMicroOp.map(Map<String, int> m)
    : link = MicroOpLink.values[m['link']!],
      pcOffset = m['pcOffset'] ?? 0;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'link': link.value,
    'pcOffset': pcOffset,
  };

  @override
  String toString() => 'WriteLinkRegisterMicroOp($link, $pcOffset)';

  static const int funct = 15;

  static BitStruct struct(Mxlen mxlen) => BitStruct({
    'funct': MicroOp.functRange,
    'link': const BitRange.single(5),
    'pcOffset': BitRange(6, 6 + mxlen.size - 1),
  });
}

/// {@category microcode}
class InterruptHoldMicroOp extends MicroOp {
  const InterruptHoldMicroOp();

  const InterruptHoldMicroOp.map(Map<String, int> _);

  @override
  Map<String, int> toMap() => {'funct': funct};

  @override
  String toString() => 'InterruptHoldMicroOp()';

  static const int funct = 16;

  static BitStruct struct(Mxlen _) => BitStruct({'funct': MicroOp.functRange});
}

/// {@category microcode}
class LoadReservedMicroOp extends MicroOp {
  final MicroOpField base;
  final MicroOpField dest;
  final MicroOpMemSize size;

  const LoadReservedMicroOp(this.base, this.dest, this.size);

  const LoadReservedMicroOp.map(Map<String, int> m)
    : base = MicroOpField.values[m['base']!],
      dest = MicroOpField.values[m['dest']!],
      size = MicroOpMemSize.values[m['size']!];

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'base': base.value,
    'dest': dest.value,
    'size': size.value,
  };

  @override
  String toString() => 'LoadReservedMicroOp($base, $dest, $size)';

  static const int funct = 17;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'base': const BitRange(5, 8),
    'dest': const BitRange(9, 12),
    'size': const BitRange(13, 14),
  });
}

/// {@category microcode}
class StoreConditionalMicroOp extends MicroOp {
  final MicroOpField base;
  final MicroOpField src;
  final MicroOpField dest;
  final MicroOpMemSize size;

  const StoreConditionalMicroOp({
    required this.base,
    required this.src,
    required this.dest,
    required this.size,
  });

  const StoreConditionalMicroOp.map(Map<String, int> m)
    : base = MicroOpField.values[m['base']!],
      src = MicroOpField.values[m['src']!],
      dest = MicroOpField.values[m['dest']!],
      size = MicroOpMemSize.values[m['size']!];

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'base': base.value,
    'src': src.value,
    'dest': dest.value,
    'size': size.value,
  };

  @override
  String toString() => 'StoreConditionalMicroOp($base, $src, $dest, $size)';

  static const int funct = 18;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'base': const BitRange(5, 8),
    'src': const BitRange(9, 12),
    'dest': const BitRange(13, 16),
    'size': const BitRange(17, 18),
  });
}

/// {@category microcode}
class AtomicMemoryMicroOp extends MicroOp {
  final MicroOpAtomicFunct afunct;
  final MicroOpField base;
  final MicroOpField src;
  final MicroOpField dest;
  final MicroOpMemSize size;

  const AtomicMemoryMicroOp({
    required MicroOpAtomicFunct funct,
    required this.base,
    required this.src,
    required this.dest,
    required this.size,
  }) : afunct = funct;

  const AtomicMemoryMicroOp.map(Map<String, int> m)
    : afunct = MicroOpAtomicFunct.values[m['afunct']!],
      base = MicroOpField.values[m['base']!],
      src = MicroOpField.values[m['src']!],
      dest = MicroOpField.values[m['dest']!],
      size = MicroOpMemSize.values[m['size']!];

  @override
  Map<String, int> toMap() => {
    'funct': AtomicMemoryMicroOp.funct,
    'afunct': afunct.value,
    'base': base.value,
    'src': src.value,
    'dest': dest.value,
    'size': size.value,
  };

  @override
  String toString() =>
      'AtomicMemoryMicroOp($afunct, $base, $src, $dest, $size)';

  static const int funct = 19;

  static BitStruct struct(Mxlen _) => BitStruct({
    'funct': MicroOp.functRange,
    'afunct': const BitRange(5, 8),
    'base': const BitRange(9, 12),
    'src': const BitRange(13, 16),
    'dest': const BitRange(17, 20),
    'size': const BitRange(21, 22),
  });
}

/// {@category microcode}
class ValidateFieldMicroOp extends MicroOp {
  final MicroOpCondition condition;
  final MicroOpField field;
  final int value;

  const ValidateFieldMicroOp(this.condition, this.field, this.value);

  const ValidateFieldMicroOp.map(Map<String, int> m)
    : condition = MicroOpCondition.values[m['condition']!],
      field = MicroOpField.values[m['field']!],
      value = m['value'] ?? 0;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'condition': condition.value,
    'field': field.value,
    'value': value,
  };

  @override
  String toString() => 'ValidateFieldMicroOp($condition, $field, $value)';

  static const int funct = 20;

  static BitStruct struct(Mxlen mxlen) => BitStruct({
    'funct': MicroOp.functRange,
    'condition': const BitRange(5, 7),
    'field': const BitRange(8, 10),
    'value': BitRange(10, 10 + mxlen.size - 1),
  });
}

/// {@category microcode}
class SetFieldMicroOp extends MicroOp {
  final MicroOpField field;
  final int value;

  const SetFieldMicroOp(this.field, this.value);

  const SetFieldMicroOp.map(Map<String, int> m)
    : field = MicroOpField.values[m['field']!],
      value = m['value'] ?? 0;

  @override
  Map<String, int> toMap() => {
    'funct': funct,
    'field': field.value,
    'value': value,
  };

  @override
  String toString() => 'SetFieldMicroOp($field, $value)';

  static const int funct = 21;

  static BitStruct struct(Mxlen mxlen) => BitStruct({
    'funct': MicroOp.functRange,
    'field': const BitRange(5, 7),
    'value': BitRange(8, 8 + mxlen.size - 1),
  });
}

/// {@category microcode}
class ReadCsrMicroOp extends MicroOp {
  final MicroOpField source;

  const ReadCsrMicroOp(this.source);

  const ReadCsrMicroOp.map(Map<String, int> m)
    : source = MicroOpField.values[m['source']!];

  @override
  Map<String, int> toMap() => {'funct': funct, 'source': source.value};

  @override
  String toString() => 'ReadCsrMicroOp($source)';

  static const int funct = 22;

  static BitStruct struct(Mxlen _) =>
      BitStruct({'funct': MicroOp.functRange, 'source': const BitRange(5, 7)});
}

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

  OperationDecodePattern.map(Map<String, int> m)
    : mask = m['mask']!,
      value = m['value']!,
      opIndex = m['opIndex']!,
      type = m['type']!,
      nzfMask = m['nzfMask']!,
      zfMask = m['zfMask']!;

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

  BigInt encode(int opIndexWidth, int typeWidth, Map<int, String> fields) =>
      struct(opIndexWidth, typeWidth, fields).bigEncode(toMap());

  @override
  String toString() =>
      'OperationDecodePattern($mask, $value, $opIndex, $type, $nzfMask, $zfMask)';

  static BitStruct struct(
    int opIndexWidth,
    int typeWidth,
    Map<int, String> fields,
  ) {
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

  static OperationDecodePattern decode(
    int opIndexWidth,
    int typeWidth,
    Map<int, String> indices,
    BigInt value,
  ) => OperationDecodePattern.map(
    struct(opIndexWidth, typeWidth, indices).bigDecode(value),
  );
}

/// {@category microcode}
class Operation<T extends InstructionType> {
  final String mnemonic;
  final int opcode;
  final int? funct2;
  final int? funct3;
  final int? funct4;
  final int? funct6;
  final int? funct7;
  final int? funct12;
  final BitStruct struct;
  final T Function(Map<String, int>) constructor;
  final List<String> nonZeroFields;
  final List<String> zeroFields;
  final List<PrivilegeMode> allowedLevels;
  final List<MicroOp> microcode;

  const Operation({
    required this.mnemonic,
    required this.opcode,
    this.funct2,
    this.funct3,
    this.funct4,
    this.funct6,
    this.funct7,
    this.funct12,
    this.nonZeroFields = const [],
    this.zeroFields = const [],
    required this.struct,
    required this.constructor,
    this.allowedLevels = PrivilegeMode.values,
    this.microcode = const [],
  });

  Map<int, MicroOp> get indexedMicrocode {
    final map = <int, MicroOp>{};
    var i = 0;
    for (final mop in microcode) {
      map[i++] = mop;
    }
    return map;
  }

  OperationDecodePattern decodePattern(int index, Map<String, int> typeMap) {
    var mask = 0;
    var value = 0;

    void bind(BitRange range, int? fieldValue, {bool nonZero = false}) {
      if (fieldValue == null && !nonZero) return;

      final shiftedMask = range.mask << range.start;
      mask |= shiftedMask;

      if (fieldValue != null) value |= (fieldValue << range.start);
    }

    bind(struct.mapping['opcode']!, opcode);

    if (funct2 != null) bind(struct.mapping['funct2']!, funct2);

    if (funct3 != null && struct.mapping['funct3'] != null) {
      bind(struct.mapping['funct3']!, funct3);
    }

    if (funct4 != null) bind(struct.mapping['funct4']!, funct4);

    if (funct6 != null) bind(struct.mapping['funct6']!, funct6);

    if (funct7 != null && struct.mapping['funct7'] != null) {
      bind(struct.mapping['funct7']!, funct7);
    }

    if (funct12 != null) bind(struct.mapping['funct12']!, funct12);

    int nzfMask = 0;

    for (final f in nonZeroFields) {
      if (!struct.mapping.containsKey(f)) {
        throw '$mnemonic instruction does not have field $f';
      }

      final r = struct.mapping[f]!;
      nzfMask |= (r.mask << r.start);
    }

    int zfMask = 0;

    for (final f in zeroFields) {
      if (!struct.mapping.containsKey(f)) {
        throw '$mnemonic instruction does not have field $f';
      }

      final r = struct.mapping[f]!;
      zfMask |= (r.mask << r.start);
    }

    mask |= zfMask;

    return OperationDecodePattern(
      mask,
      value,
      index,
      typeMap[Microcode.instrType(this)]!,
      nzfMask,
      zfMask,
    );
  }

  bool _mapMatch(Map<String, int> map) {
    if (map['opcode'] != opcode) return false;
    if (map['funct2'] != funct2) return false;
    if (map['funct3'] != funct3) return false;
    if (map['funct4'] != funct4) return false;
    if (map['funct6'] != funct6) return false;
    if (map['funct7'] != funct7) return false;
    if (map['funct12'] != funct12) return false;

    for (final field in nonZeroFields) {
      if (map[field] == 0) return false;
    }

    for (final field in zeroFields) {
      if (map[field] != 0) return false;
    }
    return true;
  }

  Map<String, int>? mapDecode(int instr) {
    final decoded = struct.decode(instr);
    if (!_mapMatch(decoded)) return null;
    return decoded;
  }

  T? decode(int instr) {
    final m = mapDecode(instr);
    if (m == null) return null;
    return constructor(m);
  }

  bool matches(InstructionType instr) => _mapMatch(instr.toMap());

  int mopWidth(Mxlen mxlen) => microcode
      .map((mop) {
        final m = mop.toMap();
        final funct = m['funct']!;
        final e = kMicroOpTable.firstWhere((e) => e.funct == funct);
        return e.struct(mxlen).width;
      })
      .fold(0, (a, b) => a > b ? a : b);

  List<BigInt> mopEncode(Mxlen mxlen) => [
    BigInt.from(microcode.length),
    ...microcode.map((mop) {
      final m = mop.toMap();
      final funct = m['funct']!;
      final e = kMicroOpTable.firstWhere((e) => e.funct == funct);
      return e.struct(mxlen).bigEncode(m);
    }),
  ];

  @override
  String toString() =>
      'Operation(mnemonic: $mnemonic, opcode: $opcode, funct2: $funct2,'
      ' funct3: $funct3, funct4: $funct4, funct6: $funct6, funct7: $funct7,'
      ' funct12: $funct12, decode: $decode, allowedLevels: $allowedLevels,'
      ' microcode: $microcode)';
}

/// {@category microcode}
class RiscVExtension {
  final List<Operation<InstructionType>> operations;
  final String? name;
  final String? key;
  final int mask;

  const RiscVExtension(this.operations, {this.name, this.key, this.mask = 0});

  Operation<InstructionType>? findOperation(
    int opcode,
    int funct3, [
    int? funct7,
  ]) {
    for (final op in operations) {
      if (op.opcode == opcode &&
          op.funct3 == funct3 &&
          (op.funct7 == null || op.funct7 == funct7)) {
        return op;
      }
    }
    return null;
  }

  Map<String, BitStruct> get typeStructs {
    Map<String, BitStruct> result = {};
    for (final op in operations) {
      final t = Microcode.instrType(op);
      if (result.containsKey(t)) continue;
      result[t] = op.struct;
    }
    return result;
  }

  Map<String, int> get typeMap => Map.fromEntries(
    typeStructs.entries.indexed.map((e) => MapEntry(e.$2.key, e.$1)),
  );

  List<OperationDecodePattern> get decodePattern {
    List<OperationDecodePattern> result = [];
    var i = 0;
    for (final op in operations) {
      result.add(op.decodePattern(i, typeMap));
      i += op.microcode.length + 1;
    }
    return result;
  }

  Map<OperationDecodePattern, Operation<InstructionType>> get decodeMap {
    // NOTE: we probably should loop through the operations and patterns to ensure coherency.
    return Map.fromIterables(decodePattern, operations);
  }

  @override
  String toString() => name ?? 'RiscVExtension($operations, mask: $mask)';
}

class MicroOpSeq {
  final List<int> ops;

  const MicroOpSeq(this.ops);

  @override
  bool operator ==(Object other) =>
      other is MicroOpSeq &&
      other.ops.length == ops.length &&
      _equalLists(other.ops, ops);

  @override
  int get hashCode => ops.fold(0, (h, e) => h * 31 + e.hashCode);

  static bool _equalLists(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => ops.toString();
}

/// {@category microcode}
class Microcode {
  final Map<OperationDecodePattern, Operation<InstructionType>> map;

  const Microcode(this.map);

  int get patternWidth => OperationDecodePattern.struct(
    opIndices.length.bitLength,
    typeStructs.length.bitLength,
    fieldIndices,
  ).width;

  int get opIndexWidth =>
      decodeLookup.keys.fold(0, (a, b) => a > b ? a : b).bitLength;

  int mopWidth(Mxlen mxlen) => map.values
      .map((op) => op.mopWidth(mxlen))
      .fold(0, (a, b) => a > b ? a : b);

  int mopIndexWidth(Mxlen mxlen) => encodedMops(mxlen).length.bitLength;

  List<BigInt> encodedMops(Mxlen mxlen) => map.values
      .map((m) => m.mopEncode(mxlen))
      .fold([], (a, b) => [...a, ...b]);

  Map<int, OperationDecodePattern> get decodeLookup {
    Map<int, OperationDecodePattern> result = {};
    var i = 0;
    for (final e in map.entries) {
      result[i] = e.key.copyWith(opIndex: i);
      i += e.value.microcode.length + 1;
    }
    return result;
  }

  Map<int, Operation<InstructionType>> get execLookup {
    Map<int, Operation<InstructionType>> result = {};
    var i = 0;
    for (final op in map.values) {
      result[i] = op;
      i += op.microcode.length + 1;
    }
    return result;
  }

  Map<String, BitStruct> get typeStructs {
    Map<String, BitStruct> result = {};
    for (final op in map.values) {
      final t = instrType(op);
      if (result.containsKey(t)) continue;
      result[t] = op.struct;
    }
    return result;
  }

  Map<String, int> get typeMap => Map.fromEntries(
    typeStructs.entries.indexed.map((e) => MapEntry(e.$2.key, e.$1)),
  );

  List<BigInt> get encodedPatterns {
    List<BigInt> result = [];
    for (final pattern in decodeLookup.values) {
      result.add(
        pattern.encode(
          opIndices.length.bitLength,
          typeMap.length.bitLength,
          fieldIndices,
        ),
      );
    }
    return result;
  }

  Map<int, String> get fieldIndices {
    final map = <String, int>{};
    int i = 0;
    for (final entry in this.map.entries) {
      final struct = entry.value.struct;
      for (final field in struct.mapping.entries) {
        map.putIfAbsent(field.key, () => i++);
      }
    }
    return map.map((k, v) => MapEntry(v, k));
  }

  Map<(int instrIdx, int step), MicroOp> get microOpAt {
    final table = <(int, int), MicroOp>{};

    for (final entry in microOpsByInstrIndex.entries) {
      final instrIdx = entry.key;
      final seq = entry.value;
      for (var i = 0; i < seq.length; i++) {
        table[(instrIdx, i)] = seq[i];
      }
    }

    return table;
  }

  Map<int, List<MicroOp>> get microOpsByTypeIndex {
    final result = <int, List<MicroOp>>{};
    for (final op in map.values) {
      for (final mop in op.microcode) {
        final idx = opIndices[mop.runtimeType.toString()]!;
        (result[idx] ??= []).add(mop);
      }
    }
    return result;
  }

  Map<int, List<MicroOp>> get microOpsByInstrIndex {
    final result = <int, List<MicroOp>>{};
    for (final entry in indices.entries) {
      final pattern = entry.key;
      final instrIdx = entry.value;
      result[instrIdx] = map[pattern]!.microcode;
    }
    return result;
  }

  Map<int, MicroOpSeq> get microOpSequences {
    final result = <int, MicroOpSeq>{};
    for (final entry in indices.entries) {
      final pattern = entry.key;
      final instrIdx = entry.value;

      final op = map[pattern]!;
      final seq = MicroOpSeq(
        op.microcode
            .map((mop) => opIndices[mop.runtimeType.toString()]!)
            .toList(),
      );

      result[instrIdx] = seq;
    }
    return result;
  }

  Map<MicroOpSeq, int> get microOpIndices {
    final result = <MicroOpSeq, int>{};
    var i = 0;
    for (final op in map.values) {
      final ilist = MicroOpSeq(
        op.microcode
            .map((mop) => opIndices[mop.runtimeType.toString()]!)
            .toList(),
      );
      if (result.containsKey(ilist)) continue;

      result[ilist] = i++;
    }
    return result;
  }

  Map<String, int> get opIndices {
    final result = <String, int>{};
    var i = 0;
    for (final op in map.values) {
      for (final mop in op.microcode) {
        final key = mop.runtimeType.toString();
        if (result.containsKey(key)) continue;
        result[key] = i++;
      }
    }
    return result;
  }

  Map<OperationDecodePattern, int> get indices {
    final result = <OperationDecodePattern, int>{};
    var i = 0;
    for (final key in map.keys) {
      result[key] = i++;
    }
    return result;
  }

  Map<String, Map<OperationDecodePattern, BitRange>> get fields {
    final result = <String, Map<OperationDecodePattern, BitRange>>{};
    for (final entry in map.entries) {
      final struct = entry.value.struct;
      for (final field in struct.mapping.entries) {
        result[field.key] ??= {};
        result[field.key]![entry.key] = field.value;
      }
    }
    return result;
  }

  Operation<InstructionType>? lookup(int instr) {
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

  InstructionType? decode(int instr) {
    final op = lookup(instr);
    if (op == null) return null;
    return op.decode(instr);
  }

  /// Builds the operations list
  ///
  /// This generates a list of all the operations.
  static List<Operation<InstructionType>> buildOperations(
    List<RiscVExtension> extensions,
  ) {
    final list = <Operation<InstructionType>>[];
    for (final ext in extensions) {
      list.addAll(ext.operations);
    }
    return list;
  }

  /// Builds a decode pattern list
  ///
  /// This generates a list of all the operations decode patterns.
  /// It is necessary for the microcode selection circuitry.
  static List<OperationDecodePattern> buildDecodePattern(
    List<RiscVExtension> extensions,
  ) {
    final list = <OperationDecodePattern>[];
    var i = 0;
    for (final ext in extensions) {
      final patterns = ext.decodePattern;

      for (final e in patterns.indexed) {
        list.add(e.$2.copyWith(opIndex: i));
        i += ext.operations[e.$1].microcode.length + 1;
      }
    }
    return list;
  }

  /// Builds the decode map
  ///
  /// This generates the decode map which resolves decode patterns to operations.
  static Map<OperationDecodePattern, Operation<InstructionType>> buildDecodeMap(
    List<RiscVExtension> extensions,
  ) {
    final patterns = buildDecodePattern(extensions);
    final operations = buildOperations(extensions);
    // NOTE: we probably should loop through the operations and patterns to ensure coherency.
    return Map.fromIterables(patterns, operations);
  }

  static String instrType<T extends InstructionType>(Operation<T> i) {
    final name = i.runtimeType.toString();
    return name.substring(10, name.length - 1);
  }

  static String mopType<T extends MicroOp>(MicroOpEncoding<T> i) {
    final name = i.runtimeType.toString();
    return name.substring(16, name.length - 8);
  }
}
