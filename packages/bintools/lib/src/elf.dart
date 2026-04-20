import 'dart:typed_data';

class Elf {
  final Uint8List bytes;
  final ElfHeader header;
  final List<ElfProgramHeader> programHeaders;
  final List<ElfSectionHeader> sectionHeaders;

  Elf._(this.bytes, this.header, this.programHeaders, this.sectionHeaders);

  bool get is64Bit => header.klass == ElfClass.elf64;

  factory Elf.load(List<int> input) {
    final data = Uint8List.fromList(input);
    if (data.length < 16) {
      throw FormatException('File too small to be ELF');
    }

    final reader = _ElfReader(data);
    reader._checkMagic();

    final klass = _parseElfClass(data[4]);
    final enc = _parseElfData(data[5]);

    if (klass == ElfClass.none) {
      throw UnsupportedError('Unsupported ELF class byte: ${data[4]}');
    }
    if (enc == ElfData.none) {
      throw UnsupportedError('Unsupported ELF data encoding byte: ${data[5]}');
    }

    final endian = enc == ElfData.lsb ? Endian.little : Endian.big;

    switch (klass) {
      case ElfClass.elf32:
        return reader.load32(endian, enc);
      case ElfClass.elf64:
        return reader.load64(endian, enc);
      case ElfClass.none:
        throw UnsupportedError('Unsupported ELF class: $klass');
    }
  }

  Uint8List segmentData(ElfProgramHeader ph) {
    if (ph.fileSize == 0) return Uint8List(0);
    final start = ph.offset;
    final end = start + ph.fileSize;
    if (start < 0 || end > bytes.length) {
      throw RangeError('Segment range out of file bounds');
    }
    return Uint8List.sublistView(bytes, start, end);
  }

  Uint8List sectionData(ElfSectionHeader sh) {
    if (sh.size == 0 || sh.type == 8) return Uint8List(0);

    final start = sh.offset;
    final end = start + sh.size;
    if (start < 0 || end > bytes.length) {
      throw RangeError('Section range out of file bounds');
    }
    return Uint8List.sublistView(bytes, start, end);
  }

  ElfSectionHeader? findSectionByName(String name) {
    for (final s in sectionHeaders) {
      if (s.name == name) return s;
    }
    return null;
  }
}

enum ElfClass { none, elf32, elf64 }

enum ElfData { none, lsb, msb }

abstract class ElfHeader {
  ElfClass get klass;
  ElfData get data;

  int get identVersion;
  int get osAbi;
  int get abiVersion;

  int get type;
  int get machine;
  int get version;
  int get entry;
  int get phOff;
  int get shOff;
  int get flags;
  int get ehSize;
  int get phEntSize;
  int get phNum;
  int get shEntSize;
  int get shNum;
  int get shStrNdx;

  bool get isLittleEndian => data == ElfData.lsb;

  @override
  String toString() =>
      '$runtimeType(klass: $klass, data: $data,'
      ' identVersion: $identVersion, osAbi: $osAbi, abiVersion: $abiVersion,'
      ' type: $type, machine: $machine, version: $version, entry: 0x${entry.toRadixString(16)},'
      ' phOff: $phOff, shOff: $shOff, flags: $flags, ehSize: $ehSize, phEntSize: $phEntSize,'
      ' phNum: $phNum, shEntSize: $shEntSize, shNum: $shNum, shStrNdx: $shStrNdx)';
}

abstract class ElfProgramHeader {
  int get type;
  int get flags;
  int get offset;
  int get vAddr;
  int get pAddr;
  int get fileSize;
  int get memSize;
  int get align;

  @override
  String toString() =>
      '$runtimeType(type: 0x${type.toRadixString(16)},'
      ' flags: 0x${flags.toRadixString(16)}, offset: 0x${offset.toRadixString(16)},'
      ' vAddr: 0x${vAddr.toRadixString(16)}, pAddr: 0x${pAddr.toRadixString(16)},'
      ' fileSize: $fileSize, memSize: $memSize, align: $align)';
}

abstract class ElfSectionHeader {
  String? name;

  int get nameIndex;
  int get type;
  int get flags;
  int get addr;
  int get offset;
  int get size;
  int get link;
  int get info;
  int get addrAlign;
  int get entSize;

  @override
  String toString() =>
      '$runtimeType(name: $name, type: 0x${type.toRadixString(16)},'
      ' flags: 0x${flags.toRadixString(16)}, addr: 0x${addr.toRadixString(16)},'
      ' offset: 0x${offset.toRadixString(16)}, size: $size, link: 0x${link.toRadixString(16)},'
      ' info: 0x${info.toRadixString(16)}, addrAlign: $addrAlign, entSize: $entSize)';
}

class Elf32Header extends ElfHeader {
  @override
  final ElfClass klass;

  @override
  final ElfData data;

  @override
  final int identVersion;

  @override
  final int osAbi;

  @override
  final int abiVersion;

  @override
  final int type;

  @override
  final int machine;

  @override
  final int version;

  @override
  final int entry;

  @override
  final int phOff;

  @override
  final int shOff;

  @override
  final int flags;

  @override
  final int ehSize;

  @override
  final int phEntSize;

  @override
  final int phNum;

  @override
  final int shEntSize;

  @override
  final int shNum;

  @override
  final int shStrNdx;

  Elf32Header({
    required this.klass,
    required this.data,
    required this.identVersion,
    required this.osAbi,
    required this.abiVersion,
    required this.type,
    required this.machine,
    required this.version,
    required this.entry,
    required this.phOff,
    required this.shOff,
    required this.flags,
    required this.ehSize,
    required this.phEntSize,
    required this.phNum,
    required this.shEntSize,
    required this.shNum,
    required this.shStrNdx,
  });
}

class Elf64Header extends ElfHeader {
  @override
  final ElfClass klass;

  @override
  final ElfData data;

  @override
  final int identVersion;

  @override
  final int osAbi;

  @override
  final int abiVersion;

  @override
  final int type;

  @override
  final int machine;

  @override
  final int version;

  @override
  final int entry;

  @override
  final int phOff;

  @override
  final int shOff;

  @override
  final int flags;

  @override
  final int ehSize;

  @override
  final int phEntSize;

  @override
  final int phNum;

  @override
  final int shEntSize;

  @override
  final int shNum;

  @override
  final int shStrNdx;

  Elf64Header({
    required this.klass,
    required this.data,
    required this.identVersion,
    required this.osAbi,
    required this.abiVersion,
    required this.type,
    required this.machine,
    required this.version,
    required this.entry,
    required this.phOff,
    required this.shOff,
    required this.flags,
    required this.ehSize,
    required this.phEntSize,
    required this.phNum,
    required this.shEntSize,
    required this.shNum,
    required this.shStrNdx,
  });
}

class Elf32ProgramHeader extends ElfProgramHeader {
  @override
  final int type;

  @override
  final int flags;

  @override
  final int offset;

  @override
  final int vAddr;

  @override
  final int pAddr;

  @override
  final int fileSize;

  @override
  final int memSize;

  @override
  final int align;

  Elf32ProgramHeader({
    required this.type,
    required this.flags,
    required this.offset,
    required this.vAddr,
    required this.pAddr,
    required this.fileSize,
    required this.memSize,
    required this.align,
  });
}

class Elf64ProgramHeader extends ElfProgramHeader {
  @override
  final int type;

  @override
  final int flags;

  @override
  final int offset;

  @override
  final int vAddr;

  @override
  final int pAddr;

  @override
  final int fileSize;

  @override
  final int memSize;

  @override
  final int align;

  Elf64ProgramHeader({
    required this.type,
    required this.flags,
    required this.offset,
    required this.vAddr,
    required this.pAddr,
    required this.fileSize,
    required this.memSize,
    required this.align,
  });
}

class Elf32SectionHeader extends ElfSectionHeader {
  @override
  final int nameIndex;

  @override
  final int type;

  @override
  final int flags;

  @override
  final int addr;

  @override
  final int offset;

  @override
  final int size;

  @override
  final int link;

  @override
  final int info;

  @override
  final int addrAlign;

  @override
  final int entSize;

  Elf32SectionHeader({
    required this.nameIndex,
    required this.type,
    required this.flags,
    required this.addr,
    required this.offset,
    required this.size,
    required this.link,
    required this.info,
    required this.addrAlign,
    required this.entSize,
  });
}

class Elf64SectionHeader extends ElfSectionHeader {
  @override
  final int nameIndex;

  @override
  final int type;

  @override
  final int flags;

  @override
  final int addr;

  @override
  final int offset;

  @override
  final int size;

  @override
  final int link;

  @override
  final int info;

  @override
  final int addrAlign;

  @override
  final int entSize;

  Elf64SectionHeader({
    required this.nameIndex,
    required this.type,
    required this.flags,
    required this.addr,
    required this.offset,
    required this.size,
    required this.link,
    required this.info,
    required this.addrAlign,
    required this.entSize,
  });
}

class _ElfReader {
  final Uint8List bytes;
  final ByteData view;

  _ElfReader(this.bytes) : view = ByteData.sublistView(bytes);

  void _checkMagic() {
    if (bytes[0] != 0x7f ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x46) {
      throw FormatException('Not an ELF file (bad magic)');
    }
  }

  Elf load32(Endian endian, ElfData dataEnc) {
    final klass = ElfClass.elf32;
    final identVersion = bytes[6];
    final osAbi = bytes[7];
    final abiVersion = bytes[8];

    int off = 16;

    final type = _u16(off, endian);
    off += 2;

    final machine = _u16(off, endian);
    off += 2;

    final version = _u32(off, endian);
    off += 4;

    final entry = _u32(off, endian);
    off += 4;

    final phOff = _u32(off, endian);
    off += 4;

    final shOff = _u32(off, endian);
    off += 4;

    final flags = _u32(off, endian);
    off += 4;

    final ehSize = _u16(off, endian);
    off += 2;

    final phEntSize = _u16(off, endian);
    off += 2;

    final phNum = _u16(off, endian);
    off += 2;

    final shEntSize = _u16(off, endian);
    off += 2;

    final shNum = _u16(off, endian);
    off += 2;

    final shStrNdx = _u16(off, endian);
    off += 2;

    final header = Elf32Header(
      klass: klass,
      data: dataEnc,
      identVersion: identVersion,
      osAbi: osAbi,
      abiVersion: abiVersion,
      type: type,
      machine: machine,
      version: version,
      entry: entry,
      phOff: phOff,
      shOff: shOff,
      flags: flags,
      ehSize: ehSize,
      phEntSize: phEntSize,
      phNum: phNum,
      shEntSize: shEntSize,
      shNum: shNum,
      shStrNdx: shStrNdx,
    );

    final ph = _readProgramHeaders32(header, endian);
    final sh = _readSectionHeaders32(header, endian);
    _populateSectionNames(header, sh);

    return Elf._(bytes, header, ph, sh);
  }

  Elf load64(Endian endian, ElfData dataEnc) {
    final klass = ElfClass.elf64;
    final identVersion = bytes[6];
    final osAbi = bytes[7];
    final abiVersion = bytes[8];

    int off = 16;

    final type = _u16(off, endian);
    off += 2;

    final machine = _u16(off, endian);
    off += 2;

    final version = _u32(off, endian);
    off += 4;

    final entry = _u64(off, endian);
    off += 8;

    final phOff = _u64(off, endian);
    off += 8;

    final shOff = _u64(off, endian);
    off += 8;

    final flags = _u32(off, endian);
    off += 4;

    final ehSize = _u16(off, endian);
    off += 2;

    final phEntSize = _u16(off, endian);
    off += 2;

    final phNum = _u16(off, endian);
    off += 2;

    final shEntSize = _u16(off, endian);
    off += 2;

    final shNum = _u16(off, endian);
    off += 2;

    final shStrNdx = _u16(off, endian);
    off += 2;

    final header = Elf64Header(
      klass: klass,
      data: dataEnc,
      identVersion: identVersion,
      osAbi: osAbi,
      abiVersion: abiVersion,
      type: type,
      machine: machine,
      version: version,
      entry: entry,
      phOff: phOff,
      shOff: shOff,
      flags: flags,
      ehSize: ehSize,
      phEntSize: phEntSize,
      phNum: phNum,
      shEntSize: shEntSize,
      shNum: shNum,
      shStrNdx: shStrNdx,
    );

    final ph = _readProgramHeaders64(header, endian);
    final sh = _readSectionHeaders64(header, endian);
    _populateSectionNames(header, sh);

    return Elf._(bytes, header, ph, sh);
  }

  List<ElfProgramHeader> _readProgramHeaders32(
    ElfHeader header,
    Endian endian,
  ) {
    if (header.phOff == 0 || header.phNum == 0) return <ElfProgramHeader>[];

    final result = <ElfProgramHeader>[];
    var base = header.phOff;

    for (var i = 0; i < header.phNum; i++) {
      final offset = base + i * header.phEntSize;

      final type = _u32(offset, endian);
      final pOffset = _u32(offset + 4, endian);
      final vAddr = _u32(offset + 8, endian);
      final pAddr = _u32(offset + 12, endian);
      final fileSize = _u32(offset + 16, endian);
      final memSize = _u32(offset + 20, endian);
      final flags = _u32(offset + 24, endian);
      final align = _u32(offset + 28, endian);

      result.add(
        Elf32ProgramHeader(
          type: type,
          flags: flags,
          offset: pOffset,
          vAddr: vAddr,
          pAddr: pAddr,
          fileSize: fileSize,
          memSize: memSize,
          align: align,
        ),
      );
    }

    return result;
  }

  List<ElfProgramHeader> _readProgramHeaders64(
    ElfHeader header,
    Endian endian,
  ) {
    if (header.phOff == 0 || header.phNum == 0) return <ElfProgramHeader>[];

    final result = <ElfProgramHeader>[];
    var base = header.phOff;

    for (var i = 0; i < header.phNum; i++) {
      final offset = base + i * header.phEntSize;

      final type = _u32(offset, endian);
      final flags = _u32(offset + 4, endian);
      final pOffset = _u64(offset + 8, endian);
      final vAddr = _u64(offset + 16, endian);
      final pAddr = _u64(offset + 24, endian);
      final fileSize = _u64(offset + 32, endian);
      final memSize = _u64(offset + 40, endian);
      final align = _u64(offset + 48, endian);

      result.add(
        Elf64ProgramHeader(
          type: type,
          flags: flags,
          offset: pOffset,
          vAddr: vAddr,
          pAddr: pAddr,
          fileSize: fileSize,
          memSize: memSize,
          align: align,
        ),
      );
    }

    return result;
  }

  List<ElfSectionHeader> _readSectionHeaders32(
    ElfHeader header,
    Endian endian,
  ) {
    if (header.shOff == 0 || header.shNum == 0) return <ElfSectionHeader>[];

    final result = <ElfSectionHeader>[];
    var base = header.shOff;

    for (var i = 0; i < header.shNum; i++) {
      final offset = base + i * header.shEntSize;

      final nameIndex = _u32(offset, endian);
      final type = _u32(offset + 4, endian);
      final flags = _u32(offset + 8, endian);
      final addr = _u32(offset + 12, endian);
      final shOffset = _u32(offset + 16, endian);
      final size = _u32(offset + 20, endian);
      final link = _u32(offset + 24, endian);
      final info = _u32(offset + 28, endian);
      final addrAlign = _u32(offset + 32, endian);
      final entSize = _u32(offset + 36, endian);

      result.add(
        Elf32SectionHeader(
          nameIndex: nameIndex,
          type: type,
          flags: flags,
          addr: addr,
          offset: shOffset,
          size: size,
          link: link,
          info: info,
          addrAlign: addrAlign,
          entSize: entSize,
        ),
      );
    }

    return result;
  }

  List<ElfSectionHeader> _readSectionHeaders64(
    ElfHeader header,
    Endian endian,
  ) {
    if (header.shOff == 0 || header.shNum == 0) return <ElfSectionHeader>[];

    final result = <ElfSectionHeader>[];
    var base = header.shOff;

    for (var i = 0; i < header.shNum; i++) {
      final offset = base + i * header.shEntSize;

      final nameIndex = _u32(offset, endian);
      final type = _u32(offset + 4, endian);
      final flags = _u64(offset + 8, endian);
      final addr = _u64(offset + 16, endian);
      final shOffset = _u64(offset + 24, endian);
      final size = _u64(offset + 32, endian);
      final link = _u32(offset + 40, endian);
      final info = _u32(offset + 44, endian);
      final addrAlign = _u64(offset + 48, endian);
      final entSize = _u64(offset + 56, endian);

      result.add(
        Elf64SectionHeader(
          nameIndex: nameIndex,
          type: type,
          flags: flags,
          addr: addr,
          offset: shOffset,
          size: size,
          link: link,
          info: info,
          addrAlign: addrAlign,
          entSize: entSize,
        ),
      );
    }

    return result;
  }

  void _populateSectionNames(
    ElfHeader header,
    List<ElfSectionHeader> sections,
  ) {
    if (sections.isEmpty) return;
    if (header.shStrNdx < 0 || header.shStrNdx >= sections.length) return;

    final shstr = sections[header.shStrNdx];
    if (shstr.size == 0) return;

    final start = shstr.offset;
    final end = start + shstr.size;
    if (start < 0 || end > bytes.length) return;

    final table = Uint8List.sublistView(bytes, start, end);

    for (final sh in sections) {
      sh.name = _readNullTerminatedString(table, sh.nameIndex);
    }
  }

  String _readNullTerminatedString(Uint8List buf, int offset) {
    if (offset < 0 || offset >= buf.length) return '';
    var end = offset;
    while (end < buf.length && buf[end] != 0) {
      end++;
    }
    return String.fromCharCodes(buf.sublist(offset, end));
  }

  int _u16(int offset, Endian endian) => view.getUint16(offset, endian);
  int _u32(int offset, Endian endian) => view.getUint32(offset, endian);
  int _u64(int offset, Endian endian) => view.getUint64(offset, endian);
}

ElfClass _parseElfClass(int v) {
  switch (v) {
    case 1:
      return ElfClass.elf32;
    case 2:
      return ElfClass.elf64;
    default:
      return ElfClass.none;
  }
}

ElfData _parseElfData(int v) {
  switch (v) {
    case 1:
      return ElfData.lsb;
    case 2:
      return ElfData.msb;
    default:
      return ElfData.none;
  }
}
