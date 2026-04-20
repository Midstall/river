import 'package:harbor/harbor.dart';
import 'package:river/river.dart' show Register;

import 'data.dart';
import 'instr.dart';
import 'instruction_set.dart';
import 'package:bintools/bintools.dart';

class _LiveInterval {
  int vreg;
  int start;
  int end;

  _LiveInterval(this.vreg, this.start, this.end);
}

class _RegisterAllocator {
  int nextRegIndex = 4;
  final Map<int, int> _vregToIndex = {};
  final List<int> _free = [];
  final Set<int> _reserved = {0};

  void run(
    List<Instruction> instructions,
    Map<int, _LiveInterval> intervals,
    Iterable<DataField> outputFields,
  ) {
    for (final inst in instructions) {
      for (final input in inst.inputs) {
        _recordPinned(input);
      }
      if (inst.output != null) {
        _recordPinned(inst.output!);
      }
    }

    int allocIndexSkippingReserved() {
      while (_reserved.contains(nextRegIndex)) {
        nextRegIndex++;
      }
      return nextRegIndex++;
    }

    int allocIndex() {
      if (_free.isNotEmpty) return _free.removeLast();
      return allocIndexSkippingReserved();
    }

    for (final out in outputFields) {
      final v = out.vreg;
      if (v == null) continue;

      final assigned = out.assignedRegister;
      if (assigned != null) {
        final idx = assigned.value;
        _reserved.add(idx);
        _vregToIndex[v] = idx;
        continue;
      }

      final idx = allocIndexSkippingReserved();
      _vregToIndex[v] = idx;
      _reserved.add(idx);
    }

    while (_reserved.contains(nextRegIndex)) {
      nextRegIndex++;
    }

    final intervalList = intervals.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    final active = <_LiveInterval>[];

    void expireOld(int position) {
      active.removeWhere((iv) {
        if (iv.end < position) {
          final idx = _vregToIndex[iv.vreg];
          if (idx != null && !_reserved.contains(idx)) {
            _free.add(idx);
          }
          return true;
        }
        return false;
      });
    }

    for (final iv in intervalList) {
      expireOld(iv.start);

      if (_vregToIndex.containsKey(iv.vreg)) {
        active.add(iv);
        continue;
      }

      final idx = allocIndex();
      _vregToIndex[iv.vreg] = idx;
      active.add(iv);
    }

    for (final inst in instructions) {
      for (final input in inst.inputs) {
        _assignField(input);
      }
      if (inst.output != null) {
        _assignField(inst.output!);
      }
    }
  }

  void _recordPinned(DataField f) {
    if (f.vreg == null || f.assignedRegister == null) return;
    final idx = f.assignedRegister!.value;
    _reserved.add(idx);
    _vregToIndex[f.vreg!] = idx;
  }

  void _assignField(DataField f) {
    if (f.assignedRegister != null) return;
    final vreg = f.vreg;
    if (vreg == null) return;
    var idx = _vregToIndex[vreg];
    if (idx == null) {
      // Vreg not mapped yet -- allocate on the fly
      while (_reserved.contains(nextRegIndex)) {
        nextRegIndex++;
      }
      idx = nextRegIndex++;
      _vregToIndex[vreg] = idx;
    }
    if (idx >= Register.values.length) return;
    f.assignedRegister = Register.values[idx];
  }
}

abstract class Module with InstructionSet {
  static Module? current;

  @override
  Module get currentModule => this;

  final Map<String, DataField> inputs = {};
  final Map<String, DataField> outputs = {};
  final List<Instruction> instructions = [];
  List<Instruction> _built = [];
  int _nextSSA = 0;
  int _memOffset = 0;

  Module() {
    current = this;
  }

  int nextSsaId() => _nextSSA++;

  DataField field(DataType type, {String? name}) =>
      DataField(type, ssaId: _nextSSA++, name: name, module: this);

  DataField input(String name) => inputs[name]!;
  DataField output(String name) => outputs[name]!;

  DataField addInput(String name, DataField field) {
    if (field.pendingImm != null) {
      final resolved = li(field.pendingImm!);
      inputs[name] = resolved;
      return resolved;
    }

    final inp = field.copyWith(ssaId: _nextSSA++, name: name, module: this);

    if (inp.producer != null) {
      final inst = inp.producer!.assignOutput(inp);
      instructions.add(inst);
      inp.producer = inst;
    }

    inputs[name] = inp;
    return inp;
  }

  DataField addOutput(
    String name, {
    required DataType type,
    DataLocation? source,
  }) {
    final out = DataField(
      type,
      ssaId: _nextSSA++,
      name: name,
      source: source,
      module: this,
    );

    if (source == DataLocation.memory) {
      out.memAddress = _memOffset;
      _memOffset += type.bytes;
    }

    outputs[name] = out;
    return out;
  }

  DataField register(Register reg) {
    if (!outputs.containsKey(reg.abi)) {
      outputs[reg.abi] = DataField.register(
        reg,
        ssaId: _nextSSA++,
        name: reg.abi,
        module: this,
      );
    }

    return outputs[reg.abi]!;
  }

  void addInstruction(Instruction i) => instructions.add(i);

  String generateAssembly() {
    final asm = StringBuffer();
    for (final inst in _built) {
      asm.writeln(inst.toAsm());
    }
    return asm.toString();
  }

  List<int> generateBinary({int baseAddress = 0}) {
    final bytes = <int>[];
    var offset = 0;
    for (final inst in _built) {
      if (inst is LabelInstruction) continue;
      bytes.addAll(inst.toBinary(pc: offset));
      offset += 4;
    }
    return bytes;
  }

  Section emitToSection({String name = '.text', int baseAddress = 0}) {
    final section = Section(name, type: SectionType.text);
    var offset = 0;

    for (final inst in _built) {
      if (inst is LabelInstruction) {
        section.addSymbol(inst.label!.name);
        continue;
      }

      if (inst.label != null && !inst.label!.isResolved) {
        section.addRelocation(
          Relocation(
            offset: section.size,
            symbol: inst.label!.name,
            type: inst.op.format == bType
                ? RelocationType.branch
                : RelocationType.jal,
          ),
        );
      }

      section.emitBytes(inst.toBinary(pc: offset));
      offset += 4;
    }

    return section;
  }

  void _resolveLabels() {
    var offset = 0;
    for (final inst in _built) {
      if (inst is LabelInstruction) {
        inst.label!.resolve(offset);
      } else {
        offset += 4;
      }
    }
  }

  void _clearState(List<Instruction> instrs) {
    _nextSSA = 0;
    for (final instr in instrs) {
      if (instr.output != null) {
        final output = instr.output!;
        if (output.module == this) {
          output.ssaId = null;
          output.vreg = null;
        }
      }
      for (final input in instr.inputs) {
        if (input.module == this) {
          input.ssaId = null;
          input.vreg = null;
        }
      }
    }
  }

  void _computeState(List<Instruction> instrs) {
    int nextVreg = 0;
    for (final instr in instrs) {
      for (final input in instr.inputs) {
        if (input.module == this) {
          input.ssaId ??= _nextSSA++;
          input.vreg ??= nextVreg++;
        }
      }
      if (instr.output != null && instr.output!.module == this) {
        instr.output!.ssaId ??= _nextSSA++;
        instr.output!.vreg ??= nextVreg++;
      }
    }
  }

  List<Instruction> _topoSort(List<Instruction> instrs) {
    final sorted = <Instruction>[];

    // Split at labels, topo-sort each segment independently
    final segments = <List<Instruction>>[];
    var current = <Instruction>[];
    for (final inst in instrs) {
      if (inst is LabelInstruction) {
        segments.add(current);
        segments.add([inst]);
        current = [];
      } else {
        current.add(inst);
      }
    }
    segments.add(current);

    final visited = <Instruction>{};

    for (final segment in segments) {
      void visit(Instruction inst) {
        if (visited.contains(inst)) return;
        visited.add(inst);
        for (final input in inst.inputs) {
          if (input.producer != null) visit(input.producer!);
        }
        sorted.add(inst);
      }

      for (final inst in segment) {
        visit(inst);
      }
    }

    return sorted;
  }

  List<Instruction> _removeDeadCode(List<Instruction> instrs) {
    final live = <Instruction>{};
    final worklist = <DataField>[];

    for (final out in outputs.values) {
      if (out.producer != null) worklist.add(out);
    }

    // Side-effect instructions are always live; seed their inputs too. A write to
    // an explicitly pinned register (set via register(xN).bind(...)) is also
    // seeded: pinning is intent to hold state across control flow the SSA
    // dataflow does not model (loop back-edges, branch merges). Without it a
    // pointer incremented at a loop bottom and consumed at the top (across the
    // back-edge) has no forward producer-use and is wrongly eliminated.
    for (final inst in instrs) {
      final pinnedWrite =
          inst.output?.assignedRegister != null &&
          inst.output?.assignedRegister != Register.x0;
      if ((inst.hasSideEffects || pinnedWrite) && live.add(inst)) {
        for (final input in inst.inputs) {
          if (input.producer != null) worklist.add(input);
        }
      }
    }

    while (worklist.isNotEmpty) {
      final field = worklist.removeLast();
      final instr = field.producer;
      if (instr == null) continue;
      if (live.add(instr)) {
        for (final input in instr.inputs) {
          if (input.producer != null) worklist.add(input);
        }
      }
    }

    return instrs.where((i) => live.contains(i)).toList();
  }

  Map<int, _LiveInterval> _computeLiveIntervals(List<Instruction> instrs) {
    final intervals = <int, _LiveInterval>{};

    for (int i = 0; i < instrs.length; i++) {
      final inst = instrs[i];
      for (final input in inst.inputs) {
        if (input.vreg == null) continue;
        final v = input.vreg!;
        intervals.putIfAbsent(v, () => _LiveInterval(v, i, i)).end = i;
      }
      if (inst.output != null && inst.output!.vreg != null) {
        final v = inst.output!.vreg!;
        intervals.putIfAbsent(v, () => _LiveInterval(v, i, i)).start = i;
      }
    }

    final lastIdx = instrs.isEmpty ? 0 : instrs.length - 1;
    for (final out in outputs.values) {
      if (out.vreg == null) continue;
      final v = out.vreg!;
      final iv = intervals.putIfAbsent(
        v,
        () => _LiveInterval(v, lastIdx, lastIdx),
      );
      if (iv.end < lastIdx) iv.end = lastIdx;
    }

    return intervals;
  }

  Future<void> build() async {
    _built = _topoSort(instructions);
    _built = _removeDeadCode(_built);
    _clearState(_built);
    _computeState(_built);
    _resolveLabels();

    final intervals = _computeLiveIntervals(_built);
    final regAlloc = _RegisterAllocator();
    regAlloc.run(_built, intervals, outputs.values);
  }
}
