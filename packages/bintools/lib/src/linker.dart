import 'dart:typed_data';
import 'section.dart';

class LinkerError implements Exception {
  final String message;
  const LinkerError(this.message);
  @override
  String toString() => 'LinkerError: $message';
}

class MemoryRegion {
  final String name;
  final int origin;
  final int length;

  const MemoryRegion({
    required this.name,
    required this.origin,
    required this.length,
  });

  int get end => origin + length;
}

class LinkerScript {
  final int entryPoint;
  final List<MemoryRegion> memory;
  final Map<String, String> sectionPlacement;

  const LinkerScript({
    this.entryPoint = 0,
    this.memory = const [],
    this.sectionPlacement = const {},
  });
}

class LinkedBinary {
  final Uint8List bytes;
  final int entryPoint;
  final Map<String, int> symbolTable;
  final int baseAddress;

  const LinkedBinary({
    required this.bytes,
    required this.entryPoint,
    required this.symbolTable,
    required this.baseAddress,
  });
}

class Linker {
  final List<Section> sections = [];
  final Map<String, Symbol> globalSymbols = {};

  void addSection(Section section) {
    sections.add(section);
    for (final entry in section.symbols.entries) {
      globalSymbols[entry.key] = Symbol(
        name: entry.key,
        section: section.name,
        offset: entry.value,
      );
    }
  }

  void addGlobalSymbol(Symbol symbol) {
    globalSymbols[symbol.name] = symbol;
  }

  int resolveSymbol(String name, Map<String, int> sectionBases) {
    final sym = globalSymbols[name];
    if (sym == null) throw LinkerError('Undefined symbol: $name');

    if (sym.section != null) {
      final base = sectionBases[sym.section];
      if (base == null) {
        throw LinkerError('Section "${sym.section}" not placed');
      }
      return base + sym.offset;
    }

    return sym.offset;
  }

  LinkedBinary link({LinkerScript script = const LinkerScript()}) {
    final sectionBases = <String, int>{};
    var cursor = script.entryPoint;

    final orderedSections = <Section>[];

    for (final region in script.memory) {
      cursor = region.origin;
      for (final section in sections) {
        final placement = script.sectionPlacement[section.name];
        if (placement != null && placement != region.name) continue;
        if (sectionBases.containsKey(section.name)) continue;

        final rem = cursor % section.alignment;
        if (rem != 0) cursor += section.alignment - rem;

        sectionBases[section.name] = cursor;
        orderedSections.add(section);
        cursor += section.size;

        if (cursor > region.end) {
          throw LinkerError(
            'Section "${section.name}" overflows memory region "${region.name}" '
            '(${cursor - region.origin} > ${region.length})',
          );
        }
      }
    }

    for (final section in sections) {
      if (sectionBases.containsKey(section.name)) continue;
      final rem = cursor % section.alignment;
      if (rem != 0) cursor += section.alignment - rem;
      sectionBases[section.name] = cursor;
      orderedSections.add(section);
      cursor += section.size;
    }

    final totalSize = cursor - script.entryPoint;
    final output = Uint8List(totalSize);

    for (final section in orderedSections) {
      if (section.type == SectionType.bss) continue;

      final base = sectionBases[section.name]!;
      final offset = base - script.entryPoint;
      final data = section.bytes;
      output.setRange(offset, offset + data.length, data);
    }

    for (final section in orderedSections) {
      final sectionBase = sectionBases[section.name]!;

      for (final reloc in section.relocations) {
        final target = resolveSymbol(reloc.symbol, sectionBases) + reloc.addend;
        final patchOffset = sectionBase - script.entryPoint + reloc.offset;

        switch (reloc.type) {
          case RelocationType.abs32:
            _patch32(output, patchOffset, target);

          case RelocationType.hi20:
            final hi = ((target + 0x800) >> 12) & 0xFFFFF;
            final existing = _read32(output, patchOffset);
            _patch32(output, patchOffset, (existing & 0xFFF) | (hi << 12));

          case RelocationType.lo12:
            final lo = target & 0xFFF;
            final existing = _read32(output, patchOffset);
            _patch32(output, patchOffset, (existing & 0xFFFFF) | (lo << 20));

          case RelocationType.branch:
            final pc = sectionBase + reloc.offset;
            final offset = target - pc;
            final existing = _read32(output, patchOffset);
            final b12 = (offset >> 12) & 1;
            final b11 = (offset >> 11) & 1;
            final b10_5 = (offset >> 5) & 0x3F;
            final b4_1 = (offset >> 1) & 0xF;
            _patch32(
              output,
              patchOffset,
              (existing & 0x1FFF07F) |
                  (b12 << 31) |
                  (b10_5 << 25) |
                  (b4_1 << 8) |
                  (b11 << 7),
            );

          case RelocationType.jal:
            final pc = sectionBase + reloc.offset;
            final offset = target - pc;
            final existing = _read32(output, patchOffset);
            final b20 = (offset >> 20) & 1;
            final b19_12 = (offset >> 12) & 0xFF;
            final b11 = (offset >> 11) & 1;
            final b10_1 = (offset >> 1) & 0x3FF;
            _patch32(
              output,
              patchOffset,
              (existing & 0xFFF) |
                  (b20 << 31) |
                  (b10_1 << 21) |
                  (b11 << 20) |
                  (b19_12 << 12),
            );

          case RelocationType.pcrel:
            final pc = sectionBase + reloc.offset;
            _patch32(output, patchOffset, target - pc);
        }
      }
    }

    final resolvedSymbols = <String, int>{};
    for (final entry in globalSymbols.entries) {
      resolvedSymbols[entry.key] = resolveSymbol(entry.key, sectionBases);
    }

    return LinkedBinary(
      bytes: output,
      entryPoint: script.entryPoint,
      symbolTable: resolvedSymbols,
      baseAddress: script.entryPoint,
    );
  }

  static void _patch32(Uint8List data, int offset, int value) {
    data[offset] = value & 0xFF;
    data[offset + 1] = (value >> 8) & 0xFF;
    data[offset + 2] = (value >> 16) & 0xFF;
    data[offset + 3] = (value >> 24) & 0xFF;
  }

  static int _read32(Uint8List data, int offset) =>
      data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
}
