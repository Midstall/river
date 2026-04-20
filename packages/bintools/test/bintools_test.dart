import 'package:bintools/bintools.dart';
import 'package:test/test.dart';

void main() {
  group('Section', () {
    test('emitByte adds single byte', () {
      final s = Section('.data', type: SectionType.data);
      s.emitByte(0x42);
      expect(s.size, 1);
      expect(s.bytes[0], 0x42);
    });

    test('emitWord adds 4 bytes little-endian', () {
      final s = Section('.data', type: SectionType.data);
      s.emitWord(0xDEADBEEF);
      expect(s.size, 4);
      expect(s.bytes[0], 0xEF);
      expect(s.bytes[1], 0xBE);
      expect(s.bytes[2], 0xAD);
      expect(s.bytes[3], 0xDE);
    });

    test('emitHalf adds 2 bytes little-endian', () {
      final s = Section('.data', type: SectionType.data);
      s.emitHalf(0x1234);
      expect(s.size, 2);
      expect(s.bytes[0], 0x34);
      expect(s.bytes[1], 0x12);
    });

    test('emitString adds null-terminated ASCII', () {
      final s = Section('.rodata', type: SectionType.rodata);
      s.emitString('hello');
      expect(s.size, 6);
      expect(s.bytes[5], 0);
    });

    test('align pads to boundary', () {
      final s = Section('.text');
      s.emitByte(0x01);
      s.align(4);
      expect(s.size, 4);
    });

    test('space fills with zeros', () {
      final s = Section('.bss', type: SectionType.bss);
      s.space(16);
      expect(s.size, 16);
    });

    test('symbols track offset', () {
      final s = Section('.text');
      s.emitWord(0);
      s.addSymbol('func');
      s.emitWord(0);
      expect(s.symbols['func'], 4);
    });

    test('default flags by type', () {
      expect(Section('.text').flags, {
        SectionFlags.alloc,
        SectionFlags.execInstr,
      });
      expect(Section('.data', type: SectionType.data).flags, {
        SectionFlags.alloc,
        SectionFlags.write,
      });
      expect(Section('.rodata', type: SectionType.rodata).flags, {
        SectionFlags.alloc,
      });
    });
  });

  group('Linker', () {
    test('resolves symbols across sections', () {
      final text = Section('.text');
      text.addSymbol('_start');
      text.emitWord(0);
      text.emitWord(0);

      final data = Section('.data', type: SectionType.data);
      data.addSymbol('my_var');
      data.emitWord(42);

      final linker = Linker();
      linker.addSection(text);
      linker.addSection(data);

      final binary = linker.link(
        script: LinkerScript(
          entryPoint: 0x1000,
          memory: [MemoryRegion(name: 'rom', origin: 0x1000, length: 0x1000)],
        ),
      );

      expect(binary.symbolTable['_start'], 0x1000);
      expect(binary.symbolTable['my_var'], 0x1008);
      expect(binary.bytes.length, 12);
    });

    test('throws on undefined symbol', () {
      final text = Section('.text');
      text.addRelocation(
        Relocation(
          offset: 0,
          symbol: 'nonexistent',
          type: RelocationType.abs32,
        ),
      );
      text.emitWord(0);

      final linker = Linker();
      linker.addSection(text);

      expect(() => linker.link(), throwsA(isA<LinkerError>()));
    });

    test('abs32 relocation patches correctly', () {
      final text = Section('.text');
      text.addRelocation(
        Relocation(offset: 0, symbol: 'target', type: RelocationType.abs32),
      );
      text.emitWord(0);

      final data = Section('.data', type: SectionType.data);
      data.addSymbol('target');
      data.emitWord(0xCAFE);

      final linker = Linker();
      linker.addSection(text);
      linker.addSection(data);

      final binary = linker.link(script: LinkerScript(entryPoint: 0x100));

      final patched =
          binary.bytes[0] |
          (binary.bytes[1] << 8) |
          (binary.bytes[2] << 16) |
          (binary.bytes[3] << 24);
      expect(patched, 0x104);
    });

    test('section alignment respected', () {
      final text = Section('.text', alignment: 16);
      text.emitByte(0x90);

      final data = Section('.data', type: SectionType.data, alignment: 16);
      data.emitWord(42);

      final linker = Linker();
      linker.addSection(text);
      linker.addSection(data);

      final binary = linker.link(script: LinkerScript(entryPoint: 0));
      expect(binary.symbolTable.isEmpty, true);
      expect(binary.bytes.length, 16 + 4);
    });

    test('overflow detection', () {
      final text = Section('.text');
      text.space(256);

      final linker = Linker();
      linker.addSection(text);

      expect(
        () => linker.link(
          script: LinkerScript(
            entryPoint: 0,
            memory: [MemoryRegion(name: 'rom', origin: 0, length: 128)],
          ),
        ),
        throwsA(isA<LinkerError>()),
      );
    });
  });

  group('ElfWriter', () {
    test('produces valid ELF32 header', () {
      final writer = ElfWriter(entryPoint: 0x80000000);

      final text = Section('.text');
      text.emitWord(0x00000013); // nop (addi x0, x0, 0)
      text.emitWord(0x00000013);
      writer.addSection(text, address: 0x80000000);

      final elf = writer.write();

      // Check magic
      expect(elf[0], 0x7F);
      expect(elf[1], 0x45); // E
      expect(elf[2], 0x4C); // L
      expect(elf[3], 0x46); // F

      // Check class (32-bit)
      expect(elf[4], 1);

      // Check data (little-endian)
      expect(elf[5], 1);

      // Verify it can be parsed back
      final parsed = Elf.load(elf);
      expect(parsed.header.entry, 0x80000000);
      expect(parsed.header.machine, ElfWriter.emRiscV);
    });

    test('multiple sections', () {
      final writer = ElfWriter(entryPoint: 0x1000);

      final text = Section('.text');
      text.emitWord(0x00000013);
      writer.addSection(text, address: 0x1000);

      final data = Section('.data', type: SectionType.data);
      data.emitWord(0xDEADBEEF);
      writer.addSection(data, address: 0x2000);

      final elf = writer.write();
      final parsed = Elf.load(elf);

      expect(
        parsed.sectionHeaders.length,
        greaterThanOrEqualTo(3),
      ); // null + text + data + shstrtab
    });

    test('section names in shstrtab', () {
      final writer = ElfWriter();

      final text = Section('.text');
      text.emitWord(0);
      writer.addSection(text);

      final elf = writer.write();
      final parsed = Elf.load(elf);

      // shstrtab should be the last section
      final shstrtab = parsed.sectionHeaders.last;
      expect(shstrtab.type, 3); // SHT_STRTAB
    });

    test('round-trip: write then read preserves entry', () {
      final writer = ElfWriter(entryPoint: 0x42);
      final text = Section('.text');
      text.emitWord(0xCAFEBABE);
      writer.addSection(text, address: 0x42);

      final elf = writer.write();
      final parsed = Elf.load(elf);
      expect(parsed.header.entry, 0x42);
      expect(parsed.header.type, 2); // ET_EXEC
    });
  });
}
