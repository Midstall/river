import 'package:river/river.dart';
import 'instr.dart';
import 'module.dart';

enum DataType {
  i8(8, false),
  i16(16, false),
  i32(32, false),
  i64(64, false),
  u8(8),
  u16(16),
  u32(32),
  u64(64);

  const DataType(this.width, [this.unsigned = true]);

  final int width;
  final bool unsigned;

  int get bytes => width ~/ 8;
}

enum DataLocation { register, memory, immediate }

class DataField {
  final String? name;
  final DataType type;
  final DataLocation? source;
  final Module? module;
  Instruction? producer;
  Register? assignedRegister;
  int? ssaId;
  int? vreg;
  int? memAddress;

  DataField(
    this.type, {
    this.name,
    Module? module,
    this.source,
    this.producer,
    this.ssaId,
    this.vreg,
    this.memAddress,
  }) : module = module ?? Module.current;

  DataField.register(
    Register reg, {
    this.name,
    Module? module,
    this.ssaId,
    this.vreg,
  }) : type = DataType.i32,
       source = DataLocation.register,
       assignedRegister = reg,
       memAddress = null,
       module = module ?? Module.current;

  DataField.zero({this.name, Module? module, this.ssaId, this.vreg})
    : type = DataType.i32,
      source = DataLocation.register,
      assignedRegister = Register.x0,
      module = module ?? Module.current;

  DataField copyWith({
    String? name,
    DataType? type,
    DataLocation? source,
    Module? module,
    Instruction? producer,
    Register? assignedRegister,
    int? ssaId,
    int? vreg,
  }) {
    final f = DataField(
      type ?? this.type,
      ssaId: ssaId ?? this.ssaId,
      name: name ?? this.name,
      source: source ?? this.source,
      module: module ?? this.module,
      producer: producer ?? this.producer,
      vreg: vreg ?? this.vreg,
    );
    f.assignedRegister = assignedRegister ?? this.assignedRegister;
    return f;
  }

  void bind(DataField value) {
    final oldInstr = value.producer!;
    final newInstr = oldInstr.assignOutput(this);
    producer = newInstr;

    if (module != null) {
      final instrs = module!.instructions;
      final idx = instrs.indexOf(oldInstr);
      if (idx >= 0) {
        instrs[idx] = newInstr;
      }
    }
  }

  DataField operator +(DataField other) =>
      (module ?? other.module)!.add(this, other);
  DataField operator -(DataField other) =>
      (module ?? other.module)!.sub(this, other);
  DataField operator |(DataField other) =>
      (module ?? other.module)!.or(this, other);
  DataField operator &(DataField other) =>
      (module ?? other.module)!.and(this, other);
  DataField operator ^(DataField other) =>
      (module ?? other.module)!.xor(this, other);

  static DataField from(int value, {String? name, Module? module}) {
    final m = module ?? Module.current;
    if (m != null) return m.li(value);

    final field = DataField(
      DataType.i32,
      name: name,
      source: DataLocation.immediate,
    );
    field.pendingImm = value;
    return field;
  }

  int? pendingImm;

  @override
  String toString() => 'DataField(name: $name, type: $type, source: $source)';
}
