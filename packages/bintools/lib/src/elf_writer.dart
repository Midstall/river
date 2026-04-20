import 'dart:typed_data';
import 'section.dart';

enum ElfWriterClass { elf32, elf64 }

class ElfWriter {
  final ElfWriterClass elfClass;
  final int machine;
  final int entryPoint;
  final Endian endian;

  final List<_ElfWriterSection> _sections = [];

  static const int emRiscV = 0xF3;

  ElfWriter({
    this.elfClass = ElfWriterClass.elf32,
    this.machine = emRiscV,
    this.entryPoint = 0,
    this.endian = Endian.little,
  });

  void addSection(Section section, {int address = 0}) {
    _sections.add(_ElfWriterSection(section, address));
  }

  Uint8List write() {
    return elfClass == ElfWriterClass.elf32 ? _write32() : _write64();
  }

  Uint8List _write32() {
    final ehdrSize = 52;
    final shdrSize = 40;
    final phdrSize = 32;

    final allSections = <_ElfWriterSection>[
      _ElfWriterSection._null(),
      ..._sections,
      _ElfWriterSection._shstrtab(_sections),
    ];

    final shstrtabIdx = allSections.length - 1;
    final numLoadable = _sections
        .where((s) => s.section.type != SectionType.bss)
        .length;

    var offset = ehdrSize + phdrSize * numLoadable;

    for (final s in allSections) {
      if (s.isNull) continue;
      s.fileOffset = offset;
      offset += s.data.length;
    }

    final totalSize = offset + shdrSize * allSections.length;
    final shoff = offset;

    final buf = ByteData(totalSize);
    var pos = 0;

    // ELF header
    buf.setUint8(pos++, 0x7F);
    buf.setUint8(pos++, 0x45); // E
    buf.setUint8(pos++, 0x4C); // L
    buf.setUint8(pos++, 0x46); // F
    buf.setUint8(pos++, 1); // 32-bit
    buf.setUint8(pos++, endian == Endian.little ? 1 : 2);
    buf.setUint8(pos++, 1); // version
    buf.setUint8(pos++, 0); // OS/ABI
    for (var i = 0; i < 8; i++) {
      buf.setUint8(pos++, 0); // padding
    }
    buf.setUint16(pos, 2, endian);
    pos += 2; // ET_EXEC
    buf.setUint16(pos, machine, endian);
    pos += 2;
    buf.setUint32(pos, 1, endian);
    pos += 4; // version
    buf.setUint32(pos, entryPoint, endian);
    pos += 4; // entry
    buf.setUint32(pos, ehdrSize, endian);
    pos += 4; // phoff
    buf.setUint32(pos, shoff, endian);
    pos += 4; // shoff
    buf.setUint32(pos, 0, endian);
    pos += 4; // flags
    buf.setUint16(pos, ehdrSize, endian);
    pos += 2; // ehsize
    buf.setUint16(pos, phdrSize, endian);
    pos += 2; // phentsize
    buf.setUint16(pos, numLoadable, endian);
    pos += 2; // phnum
    buf.setUint16(pos, shdrSize, endian);
    pos += 2; // shentsize
    buf.setUint16(pos, allSections.length, endian);
    pos += 2; // shnum
    buf.setUint16(pos, shstrtabIdx, endian);
    pos += 2; // shstrndx

    // Program headers (one per loadable section)
    for (final s in _sections) {
      if (s.section.type == SectionType.bss) continue;
      buf.setUint32(pos, 1, endian);
      pos += 4; // PT_LOAD
      buf.setUint32(pos, s.fileOffset!, endian);
      pos += 4; // offset
      buf.setUint32(pos, s.address, endian);
      pos += 4; // vaddr
      buf.setUint32(pos, s.address, endian);
      pos += 4; // paddr
      buf.setUint32(pos, s.data.length, endian);
      pos += 4; // filesz
      buf.setUint32(pos, s.data.length, endian);
      pos += 4; // memsz
      var flags = 4; // PF_R
      if (s.section.flags.contains(SectionFlags.write)) flags |= 2;
      if (s.section.flags.contains(SectionFlags.execInstr)) flags |= 1;
      buf.setUint32(pos, flags, endian);
      pos += 4; // flags
      buf.setUint32(pos, s.section.alignment, endian);
      pos += 4; // align
    }

    // Section data
    for (final s in allSections) {
      if (s.isNull) continue;
      final data = s.data;
      for (var i = 0; i < data.length; i++) {
        buf.setUint8(s.fileOffset! + i, data[i]);
      }
    }

    // Section headers
    pos = shoff;
    final shstrtab = allSections[shstrtabIdx];

    for (final s in allSections) {
      final nameOffset = s.isNull
          ? 0
          : shstrtab.nameOffsets[s.section.name] ?? 0;
      buf.setUint32(pos, nameOffset, endian);
      pos += 4; // name
      buf.setUint32(pos, s.shType, endian);
      pos += 4; // type
      buf.setUint32(pos, s.shFlags, endian);
      pos += 4; // flags
      buf.setUint32(pos, s.isNull ? 0 : s.address, endian);
      pos += 4; // addr
      buf.setUint32(pos, s.isNull ? 0 : s.fileOffset!, endian);
      pos += 4; // offset
      buf.setUint32(pos, s.data.length, endian);
      pos += 4; // size
      buf.setUint32(pos, 0, endian);
      pos += 4; // link
      buf.setUint32(pos, 0, endian);
      pos += 4; // info
      buf.setUint32(pos, s.isNull ? 0 : s.section.alignment, endian);
      pos += 4; // addralign
      buf.setUint32(pos, 0, endian);
      pos += 4; // entsize
    }

    return buf.buffer.asUint8List(0, totalSize);
  }

  Uint8List _write64() {
    // Simplified: same structure but with 64-bit fields
    // For now, delegate to 32-bit with wider fields
    throw UnimplementedError('ELF64 writer not yet implemented');
  }
}

class _ElfWriterSection {
  final Section section;
  final int address;
  int? fileOffset;
  final bool isNull;
  final Map<String, int> nameOffsets;

  _ElfWriterSection(this.section, this.address)
    : isNull = false,
      nameOffsets = {};

  _ElfWriterSection._null()
    : section = Section(''),
      address = 0,
      isNull = true,
      nameOffsets = {};

  factory _ElfWriterSection._shstrtab(List<_ElfWriterSection> sections) {
    final strtab = Section('.shstrtab', type: SectionType.rodata);
    final offsets = <String, int>{};

    strtab.emitByte(0); // null string at offset 0
    offsets[''] = 0;

    for (final s in sections) {
      offsets[s.section.name] = strtab.size;
      strtab.emitString(s.section.name);
    }

    offsets['.shstrtab'] = strtab.size;
    strtab.emitString('.shstrtab');

    final result = _ElfWriterSection(strtab, 0);
    result.nameOffsets.addAll(offsets);
    return result;
  }

  Uint8List get data => isNull ? Uint8List(0) : section.bytes;

  int get shType {
    if (isNull) return 0; // SHT_NULL
    if (section.name == '.shstrtab') return 3; // SHT_STRTAB
    return switch (section.type) {
      SectionType.text => 1, // SHT_PROGBITS
      SectionType.data => 1,
      SectionType.rodata => 1,
      SectionType.bss => 8, // SHT_NOBITS
    };
  }

  int get shFlags {
    if (isNull) return 0;
    var f = 0;
    if (section.flags.contains(SectionFlags.alloc)) f |= 2; // SHF_ALLOC
    if (section.flags.contains(SectionFlags.write)) f |= 1; // SHF_WRITE
    if (section.flags.contains(SectionFlags.execInstr)) f |= 4; // SHF_EXECINSTR
    return f;
  }
}
