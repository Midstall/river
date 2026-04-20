import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Unit tests for the variable-length instruction aligner: given a halfword
/// window, it must extract two back-to-back instructions of any 2/4-byte length
/// combination, with correct sizes, PCs (via size), and validity (boundary).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Compressed (16-bit) halfword: low 2 bits != 0b11. e.g. c.addi = 0x0505.
  // 32-bit halfword: low 2 bits == 0b11. e.g. addi low half ...0x13 (bits 1:0=11).
  const comp = 0x4505; // c.li x10, 1 low bits 01 -> compressed
  const comp2 = 0x4585; // c.li x11, 1
  // 32-bit instr 0x00100513 = addi x10,x0,1 -> low half 0x0513, high half 0x0010
  const w32lo = 0x0513;
  const w32hi = 0x0010;
  const w32 = 0x00100513;
  const x32lo = 0x0593; // addi x11,x0,... low half
  const x32hi = 0x0020;
  const x32 = 0x00200593;

  /// Build the aligner with a 4-halfword window and drive it.
  Future<Map<String, int>> align(List<int> hwords, int validCount) async {
    final halves = Logic(width: 64);
    final vc = Logic(width: 3);
    final a = InstructionAligner(halves, vc, laneCount: 4);
    await a.build();
    var packed = 0;
    for (var i = 0; i < 4; i++) {
      packed |= (hwords[i] & 0xFFFF) << (16 * i);
    }
    halves.put(packed);
    vc.put(validCount);
    return {
      'instr0': a.instr0.value.toInt(),
      'size0': a.size0.value.toInt(),
      'comp0': a.compressed0.value.toInt(),
      'valid0': a.valid0.value.toInt(),
      'instr1': a.instr1.value.toInt(),
      'size1': a.size1.value.toInt(),
      'comp1': a.compressed1.value.toInt(),
      'valid1': a.valid1.value.toInt(),
    };
  }

  test('compressed + compressed', () async {
    final r = await align([comp, comp2, 0, 0], 2);
    expect(r['instr0'], comp);
    expect(r['size0'], 1);
    expect(r['comp0'], 1);
    expect(r['valid0'], 1);
    expect(r['instr1'], comp2);
    expect(r['size1'], 1);
    expect(r['comp1'], 1);
    expect(r['valid1'], 1);
  });

  test('compressed + 32-bit', () async {
    final r = await align([comp, w32lo, w32hi, 0], 3);
    expect(r['instr0'], comp);
    expect(r['size0'], 1);
    expect(r['valid0'], 1);
    expect(r['instr1'], w32); // {hi, lo} at halfwords 1,2
    expect(r['size1'], 2);
    expect(r['comp1'], 0);
    expect(r['valid1'], 1);
  });

  test('32-bit + compressed', () async {
    final r = await align([w32lo, w32hi, comp2, 0], 3);
    expect(r['instr0'], w32);
    expect(r['size0'], 2);
    expect(r['comp0'], 0);
    expect(r['valid0'], 1);
    expect(r['instr1'], comp2); // halfword 2
    expect(r['size1'], 1);
    expect(r['comp1'], 1);
    expect(r['valid1'], 1);
  });

  test('32-bit + 32-bit', () async {
    final r = await align([w32lo, w32hi, x32lo, x32hi], 4);
    expect(r['instr0'], w32);
    expect(r['size0'], 2);
    expect(r['valid0'], 1);
    expect(r['instr1'], x32); // halfwords 2,3
    expect(r['size1'], 2);
    expect(r['valid1'], 1);
  });

  test(
    'boundary: only lane 0 valid (32-bit instr0, 2 halves, no room for i1)',
    () async {
      final r = await align([w32lo, w32hi, comp2, 0], 2);
      expect(r['instr0'], w32);
      expect(r['valid0'], 1);
      expect(r['valid1'], 0); // only 2 halfwords -> instr1 not present
    },
  );

  test(
    'boundary: 32-bit instr0 straddles, only 1 half valid -> instr0 invalid',
    () async {
      final r = await align([w32lo, w32hi, 0, 0], 1);
      expect(r['size0'], 2);
      expect(r['valid0'], 0); // needs 2 halfwords, only 1 valid
      expect(r['valid1'], 0);
    },
  );

  test(
    'boundary: compressed instr0 with 1 half valid -> instr0 valid, i1 not',
    () async {
      final r = await align([comp, 0, 0, 0], 1);
      expect(r['instr0'], comp);
      expect(r['valid0'], 1);
      expect(r['valid1'], 0);
    },
  );
}
