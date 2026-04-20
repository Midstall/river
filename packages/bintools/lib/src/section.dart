import 'dart:typed_data';

enum SectionType { text, data, rodata, bss }

enum SectionFlags { alloc, write, execInstr }

class Section {
  final String name;
  final SectionType type;
  final Set<SectionFlags> flags;
  final int alignment;
  final BytesBuilder _data = BytesBuilder();
  final List<Relocation> relocations = [];
  final Map<String, int> symbols = {};

  int get size => _data.length;
  Uint8List get bytes => _data.toBytes();

  Section(
    this.name, {
    this.type = SectionType.text,
    Set<SectionFlags>? flags,
    this.alignment = 4,
  }) : flags = flags ?? _defaultFlags(type);

  static Set<SectionFlags> _defaultFlags(SectionType type) => switch (type) {
    SectionType.text => {SectionFlags.alloc, SectionFlags.execInstr},
    SectionType.data => {SectionFlags.alloc, SectionFlags.write},
    SectionType.rodata => {SectionFlags.alloc},
    SectionType.bss => {SectionFlags.alloc, SectionFlags.write},
  };

  void emitByte(int value) {
    _data.addByte(value & 0xFF);
  }

  void emitHalf(int value) {
    _data.addByte(value & 0xFF);
    _data.addByte((value >> 8) & 0xFF);
  }

  void emitWord(int value) {
    _data.addByte(value & 0xFF);
    _data.addByte((value >> 8) & 0xFF);
    _data.addByte((value >> 16) & 0xFF);
    _data.addByte((value >> 24) & 0xFF);
  }

  void emitDword(int value) {
    emitWord(value & 0xFFFFFFFF);
    emitWord((value >> 32) & 0xFFFFFFFF);
  }

  void emitBytes(List<int> data) {
    _data.add(data);
  }

  void emitString(String s, {bool nullTerminate = true}) {
    _data.add(s.codeUnits);
    if (nullTerminate) _data.addByte(0);
  }

  void align(int boundary) {
    final rem = size % boundary;
    if (rem != 0) {
      final pad = boundary - rem;
      for (var i = 0; i < pad; i++) {
        _data.addByte(0);
      }
    }
  }

  void space(int count, {int fill = 0}) {
    for (var i = 0; i < count; i++) {
      _data.addByte(fill);
    }
  }

  void addSymbol(String name) {
    symbols[name] = size;
  }

  void addRelocation(Relocation reloc) {
    relocations.add(reloc);
  }
}

enum RelocationType { abs32, branch, jal, hi20, lo12, pcrel }

class Relocation {
  final int offset;
  final String symbol;
  final RelocationType type;
  final int addend;

  const Relocation({
    required this.offset,
    required this.symbol,
    required this.type,
    this.addend = 0,
  });
}

class Symbol {
  final String name;
  final String? section;
  final int offset;
  final bool global;

  const Symbol({
    required this.name,
    this.section,
    required this.offset,
    this.global = false,
  });
}
