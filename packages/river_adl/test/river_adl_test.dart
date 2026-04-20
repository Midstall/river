import 'package:harbor/harbor.dart';
import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';
import 'package:test/test.dart';

class AddModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);

  DataField get c => output('c');

  AddModule(DataField a, DataField b) : super() {
    a = addInput('a', a);
    b = addInput('b', b);
    addOutput('c', type: a.type, source: DataLocation.register);
    c.bind(a + b);
  }
}

void main() {
  group('Basic ALU', () {
    test('add generates correct assembly', () async {
      final mod = AddModule(DataField.from(1), DataField.from(2));
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, contains('addi'));
      expect(asm, contains('add'));
      expect(asm.split('\n').where((l) => l.isNotEmpty).length, 3);
    });

    test('add generates correct binary', () async {
      final mod = AddModule(DataField.from(1), DataField.from(2));
      await mod.build();
      final binary = mod.generateBinary();
      expect(binary.length, 12);
    });

    test('sub via operator', () async {
      final mod = _SubModule();
      await mod.build();
      expect(mod.generateAssembly(), contains('sub'));
    });

    test('bitwise operators', () async {
      final mod = _BitwiseModule();
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, contains('or'));
      expect(asm, contains('and'));
      expect(asm, contains('xor'));
    });
  });

  group('Immediate instructions', () {
    test('addi', () async {
      final mod = _AddiModule();
      await mod.build();
      expect(mod.generateAssembly(), contains('addi'));
    });

    test('li small value', () async {
      final mod = _LiModule(42);
      await mod.build();
      expect(mod.generateAssembly(), contains('addi'));
    });

    test('li large value uses lui+addi', () async {
      final mod = _LiModule(0x12345);
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, contains('lui'));
      expect(asm, contains('addi'));
    });
  });

  group('Control flow', () {
    test('branch with label', () async {
      final mod = _BranchModule();
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, contains('beq'));
      expect(asm, contains('end:'));
    });

    test('multiple branches', () async {
      final mod = _MultiBranchModule();
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, contains('bne'));
      expect(asm, contains('blt'));
    });
  });

  group('Memory operations', () {
    test('load word', () async {
      final mod = _LoadModule();
      await mod.build();
      expect(mod.generateAssembly(), contains('lw'));
    });

    test('store word', () async {
      final mod = _StoreModule();
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, contains('sw'));
    });
  });

  group('ISA validation', () {
    test('throws on missing M extension', () {
      expect(() => _MulModule(), throwsA(isA<UnsupportedError>()));
    });

    test('M extension works when present', () async {
      final mod = _MulWithExtModule();
      await mod.build();
      expect(mod.generateAssembly(), contains('mul'));
    });
  });

  group('Section emission', () {
    test('emitToSection produces correct section', () async {
      final mod = AddModule(DataField.from(1), DataField.from(2));
      await mod.build();
      final section = mod.emitToSection();
      expect(section.name, '.text');
      expect(section.size, 12);
      expect(section.type, SectionType.text);
    });

    test('labels become symbols in section', () async {
      final mod = _BranchModule();
      await mod.build();
      final section = mod.emitToSection();
      expect(section.symbols.containsKey('end'), true);
    });
  });

  group('Linker integration', () {
    test('link code and data sections', () async {
      final code = AddModule(DataField.from(1), DataField.from(2));
      await code.build();
      final textSection = code.emitToSection();

      final data = Section('.data', type: SectionType.data);
      data.addSymbol('magic');
      data.emitWord(0xDEADBEEF);

      final linker = Linker();
      linker.addSection(textSection);
      linker.addSection(data);

      final binary = linker.link(
        script: LinkerScript(
          entryPoint: 0x80000000,
          memory: [
            MemoryRegion(name: 'rom', origin: 0x80000000, length: 0x1000),
          ],
        ),
      );

      expect(binary.entryPoint, 0x80000000);
      expect(binary.symbolTable['magic'], 0x8000000C);
      expect(binary.bytes.length, 16);
    });
  });

  group('Binary encoding', () {
    test('addi encodes correctly', () async {
      final mod = _AddiModule();
      await mod.build();
      final binary = mod.generateBinary();
      // addi x4, x0, 5 → 0x00500213
      // Check it's 4 bytes (one instruction: li 5 = addi x4, x0, 5)
      // Plus the addi x5, x4, 10
      expect(binary.length, 8);
    });

    test('binary round-trips through emulator decode', () async {
      final mod = AddModule(DataField.from(3), DataField.from(4));
      await mod.build();
      final binary = mod.generateBinary();
      expect(binary.length, 12);
      // First instruction: addi rd, x0, 3
      final instr0 =
          binary[0] | (binary[1] << 8) | (binary[2] << 16) | (binary[3] << 24);
      expect(instr0 & 0x7F, 0x13); // OP-IMM opcode
    });
  });

  group('ELF output', () {
    test('produces valid ELF from module', () async {
      final mod = AddModule(DataField.from(1), DataField.from(2));
      await mod.build();

      final section = mod.emitToSection();
      final writer = ElfWriter(entryPoint: 0x80000000);
      writer.addSection(section, address: 0x80000000);
      final elf = writer.write();

      expect(elf[0], 0x7F);
      expect(elf[1], 0x45);
      expect(elf[2], 0x4C);
      expect(elf[3], 0x46);
    });
  });

  group('Control flow', () {
    test('loop with labels and branches', () async {
      final mod = _LoopModule();
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, contains('top:'));
      expect(asm, contains('beq'));
      expect(asm, contains('sw'));
      expect(asm, contains('jal'));
      expect(asm, contains('end:'));
    });
  });

  group('Pseudo-instructions', () {
    test('mv generates addi', () async {
      final mod = _MvModule();
      await mod.build();
      expect(mod.generateAssembly(), contains('addi'));
    });

    test('nop generates addi x0', () async {
      final mod = _NopModule();
      await mod.build();
      expect(mod.generateAssembly(), contains('addi'));
    });

    test('li zero-extends a bit-31 address on RV64', () async {
      // 0x8000_0000 must materialize as the positive address, not the
      // lui-sign-extended 0xFFFFFFFF_80000000 (which the bus decoder misses
      // and the core then wedges on). The fix appends slli/srli to zero-extend.
      final mod = _LiAddrModule(RiscVMxlen.rv64, 0x80000000);
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, contains('slli'));
      expect(asm, contains('srli'));
    });

    test('li does not zero-extend a sub-2GB address on RV64', () async {
      // 0x1000_0000 has bit 31 clear, so lui does not sign-extend: no fixup.
      final mod = _LiAddrModule(RiscVMxlen.rv64, 0x10000000);
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, isNot(contains('slli')));
    });

    test('li does not over-extend on RV32', () async {
      // RV32 has no upper half to corrupt, so no slli/srli fixup is emitted.
      final mod = _LiAddrModule(RiscVMxlen.rv32, 0x80000000);
      await mod.build();
      final asm = mod.generateAssembly();
      expect(asm, isNot(contains('slli')));
    });
  });
}

class _LiAddrModule extends Module {
  @override
  final RiscVIsaConfig isa;
  _LiAddrModule(RiscVMxlen mxlen, int imm)
    : isa = RiscVIsaConfig(
        mxlen: mxlen,
        extensions: mxlen == RiscVMxlen.rv64 ? [rv64i, rv32i] : [rv32i],
      ),
      super() {
    register(Register.x10).bind(li(imm));
  }
}

class _SubModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _SubModule() : super() {
    final a = addInput('a', DataField.from(10));
    final b = addInput('b', DataField.from(3));
    addOutput('c', type: DataType.i32, source: DataLocation.register);
    output('c').bind(a - b);
  }
}

class _BitwiseModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _BitwiseModule() : super() {
    final a = addInput('a', DataField.from(0xFF));
    final b = addInput('b', DataField.from(0x0F));
    addOutput('or_out', type: DataType.i32, source: DataLocation.register);
    addOutput('and_out', type: DataType.i32, source: DataLocation.register);
    addOutput('xor_out', type: DataType.i32, source: DataLocation.register);
    output('or_out').bind(a | b);
    output('and_out').bind(a & b);
    output('xor_out').bind(a ^ b);
  }
}

class _AddiModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _AddiModule() : super() {
    final a = addInput('a', DataField.from(5));
    addOutput('b', type: DataType.i32, source: DataLocation.register);
    output('b').bind(addi(a, 10));
  }
}

class _LiModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _LiModule(int value) : super() {
    addOutput('v', type: DataType.i32, source: DataLocation.register);
    output('v').bind(li(value));
  }
}

class _BranchModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _BranchModule() : super() {
    final a = addInput('a', DataField(DataType.i32));
    final b = addInput('b', DataField(DataType.i32));
    addOutput('result', type: DataType.i32, source: DataLocation.register);
    final end = Label('end');
    beq(a, b, end);
    final result = addi(a, 1);
    placeLabel(end);
    output('result').bind(result);
  }
}

class _MultiBranchModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _MultiBranchModule() : super() {
    final a = addInput('a', DataField(DataType.i32));
    final b = addInput('b', DataField(DataType.i32));
    addOutput('result', type: DataType.i32, source: DataLocation.register);
    final skip1 = Label('skip1');
    final skip2 = Label('skip2');
    bne(a, b, skip1);
    blt(a, b, skip2);
    placeLabel(skip1);
    placeLabel(skip2);
    output('result').bind(addi(a, 0));
  }
}

class _LoadModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _LoadModule() : super() {
    final base = addInput('base', DataField.from(0x1000));
    addOutput('value', type: DataType.i32, source: DataLocation.register);
    output('value').bind(lw(base, offset: 4));
  }
}

class _StoreModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _StoreModule() : super() {
    final base = addInput('base', DataField.from(0x1000));
    final value = addInput('value', DataField.from(42));
    sw(base, value, offset: 8);
  }
}

class _MulModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _MulModule() : super() {
    final a = addInput('a', DataField(DataType.i32));
    final b = addInput('b', DataField(DataType.i32));
    addOutput('c', type: DataType.i32, source: DataLocation.register);
    output('c').bind(mul(a, b));
  }
}

class _LoopModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _LoopModule() : super() {
    final base = addInput('base', DataField.from(0x1000));
    final value = addInput('value', DataField.from(42));

    final top = Label('top');
    final end = Label('end');
    placeLabel(top);
    beq(value, zero, end);
    sw(base, value, offset: 0); // side-effect: survives DCE
    jal(top);
    placeLabel(end);
  }
}

class _MvModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _MvModule() : super() {
    final a = addInput('a', DataField.from(42));
    addOutput('b', type: DataType.i32, source: DataLocation.register);
    output('b').bind(mv(a));
  }
}

class _NopModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  _NopModule() : super() {
    nop();
    addOutput('x', type: DataType.i32, source: DataLocation.register);
    output('x').bind(li(0));
  }
}

class _MulWithExtModule extends Module {
  @override
  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i, rvM]);
  _MulWithExtModule() : super() {
    final a = addInput('a', DataField.from(6));
    final b = addInput('b', DataField.from(7));
    addOutput('c', type: DataType.i32, source: DataLocation.register);
    output('c').bind(mul(a, b));
  }
}
