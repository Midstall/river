import 'package:river/river.dart';
import 'package:test/test.dart';

/// Decode-correctness audit for funct7-bearing R-type ops (base OP 0x33, OP-32
/// 0x3B, M extension) at SPEC encodings. Same bug class as the AMO funct7 bug
/// (project_amo_funct7_bug): catches any op whose funct7/funct3 in Harbor doesn't
/// match the real RISC-V encoding, which would silently mis-decode real code.
void main() {
  final config = RiverCoreConfigV1.macro(
    mmu: HarborMmuConfig(
      mxlen: RiscVMxlen.rv64,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    interrupts: [],
    clock: const HarborClockConfig(
      name: 'test',
      rate: HarborFixedClockRate(10000),
    ),
  );

  // (opcode, funct3, funct7, rs2, mnemonic). rs1=rd=0.
  int enc(int opcode, int f3, int f7, int rs2) =>
      (f7 << 25) | (rs2 << 20) | (f3 << 12) | opcode;

  // OP-FP (0x53) ops: funct7-distinguished arithmetic, plus a couple rs2-coded
  // fcvt pairs (same funct7, differ only by rs2 - exercises rs2 disambiguation).
  final fpCases = <(int, int, int, int, String)>[
    (0x53, 0x0, 0x00, 0, 'fadd.s'), (0x53, 0x0, 0x01, 0, 'fadd.d'),
    (0x53, 0x0, 0x04, 0, 'fsub.s'), (0x53, 0x0, 0x05, 0, 'fsub.d'),
    (0x53, 0x0, 0x08, 0, 'fmul.s'), (0x53, 0x0, 0x09, 0, 'fmul.d'),
    (0x53, 0x0, 0x0C, 0, 'fdiv.s'), (0x53, 0x0, 0x0D, 0, 'fdiv.d'),
    (0x53, 0x0, 0x10, 0, 'fsgnj.s'), (0x53, 0x1, 0x10, 0, 'fsgnjn.s'),
    (0x53, 0x0, 0x14, 0, 'fmin.s'), (0x53, 0x1, 0x14, 0, 'fmax.s'),
    (0x53, 0x2, 0x50, 0, 'feq.s'), (0x53, 0x1, 0x50, 0, 'flt.s'),
    (0x53, 0x0, 0x50, 0, 'fle.s'),
    (0x53, 0x0, 0x60, 0, 'fcvt.w.s'), (0x53, 0x0, 0x68, 0, 'fcvt.s.w'),
    // NOTE: the rs2-coded fcvt variants (fcvt.wu/l/lu .s/.d, fcvt.s.wu/l/lu) are
    // NOT yet defined as Harbor decode ops, and the defined ones lack an rs2
    // matchMask, so a real fcvt.wu.s (rs2=1) currently mis-decodes to fcvt.w.s.
    // Decode-completion is a separate task - see project_fcvt_decode_gap.
  ];

  final cases = <(int, int, int, String)>[
    // base OP (0x33)
    (0x33, 0x0, 0x00, 'add'), (0x33, 0x0, 0x20, 'sub'),
    (0x33, 0x1, 0x00, 'sll'), (0x33, 0x2, 0x00, 'slt'),
    (0x33, 0x3, 0x00, 'sltu'), (0x33, 0x4, 0x00, 'xor'),
    (0x33, 0x5, 0x00, 'srl'), (0x33, 0x5, 0x20, 'sra'),
    (0x33, 0x6, 0x00, 'or'), (0x33, 0x7, 0x00, 'and'),
    // M extension (0x33, funct7=0x01)
    (0x33, 0x0, 0x01, 'mul'), (0x33, 0x1, 0x01, 'mulh'),
    (0x33, 0x2, 0x01, 'mulhsu'), (0x33, 0x3, 0x01, 'mulhu'),
    (0x33, 0x4, 0x01, 'div'), (0x33, 0x5, 0x01, 'divu'),
    (0x33, 0x6, 0x01, 'rem'), (0x33, 0x7, 0x01, 'remu'),
    // OP-32 (0x3B, RV64)
    (0x3B, 0x0, 0x00, 'addw'), (0x3B, 0x0, 0x20, 'subw'),
    (0x3B, 0x1, 0x00, 'sllw'), (0x3B, 0x5, 0x00, 'srlw'),
    (0x3B, 0x5, 0x20, 'sraw'),
    // M64 (0x3B, funct7=0x01)
    (0x3B, 0x0, 0x01, 'mulw'), (0x3B, 0x4, 0x01, 'divw'),
    (0x3B, 0x5, 0x01, 'divuw'), (0x3B, 0x6, 0x01, 'remw'),
    (0x3B, 0x7, 0x01, 'remuw'),
  ];

  test('R-type / M ops decode at spec encodings', () {
    final fails = <String>[];
    for (final (op, f3, f7, want) in cases) {
      final got = config.isa.findOperation(enc(op, f3, f7, 0))?.mnemonic;
      if (got != want) {
        fails.add(
          '$want (op=0x${op.toRadixString(16)} f3=$f3 '
          'f7=0x${f7.toRadixString(16)}) -> ${got ?? "NULL"}',
        );
      }
    }
    expect(fails, isEmpty, reason: 'mis-decoded: ${fails.join("; ")}');
  });

  test('OP-FP (F/D) ops decode at spec encodings', () {
    final fails = <String>[];
    for (final (op, f3, f7, rs2, want) in fpCases) {
      final got = config.isa.findOperation(enc(op, f3, f7, rs2))?.mnemonic;
      if (got != want) {
        fails.add(
          '$want (f3=$f3 f7=0x${f7.toRadixString(16)} rs2=$rs2) '
          '-> ${got ?? "NULL"}',
        );
      }
    }
    expect(fails, isEmpty, reason: 'mis-decoded: ${fails.join("; ")}');
  });

  // SYSTEM (0x73) privileged ops. sret/wfi share funct7=0x08 and differ only in
  // rs2 (sret=2, wfi=5); without an rs2 matchMask wfi mis-decoded to sret (a real
  // OS-idle crash). Guards that fix plus the other SYSTEM ops.
  test('SYSTEM privileged ops decode at spec encodings (wfi != sret)', () {
    // (opcode, funct3, funct7, rs2, mnemonic)
    final sysCases = <(int, int, int, int, String)>[
      (0x73, 0x0, 0x00, 0, 'ecall'),
      (0x73, 0x0, 0x00, 1, 'ebreak'),
      (0x73, 0x0, 0x08, 2, 'sret'),
      (0x73, 0x0, 0x18, 2, 'mret'),
      (0x73, 0x0, 0x08, 5, 'wfi'), // was mis-decoding to sret
    ];
    final fails = <String>[];
    for (final (op, f3, f7, rs2, want) in sysCases) {
      final got = config.isa.findOperation(enc(op, f3, f7, rs2))?.mnemonic;
      if (got != want) {
        fails.add(
          '$want (f7=0x${f7.toRadixString(16)} rs2=$rs2) '
          '-> ${got ?? "NULL"}',
        );
      }
    }
    expect(fails, isEmpty, reason: 'mis-decoded: ${fails.join("; ")}');
  });

  // FMA (R4-type): opcode picks the op (fmadd/fmsub/fnmsub/fnmadd), fmt[26:25]
  // picks single (0) vs double (1). rs3/rs2/rs1/rm/rd carry registers.
  test('FMA R4-type ops decode at spec encodings (fmt picks s/d)', () {
    int enc4(int opcode, int fmt) =>
        (0 << 27) | (fmt << 25) | (0 << 20) | (0 << 15) | (0 << 12) | opcode;
    final fmaCases = <(int, int, String)>[
      (0x43, 0, 'fmadd.s'),
      (0x47, 0, 'fmsub.s'),
      (0x4B, 0, 'fnmsub.s'),
      (0x4F, 0, 'fnmadd.s'),
      (0x43, 1, 'fmadd.d'),
      (0x47, 1, 'fmsub.d'),
      (0x4B, 1, 'fnmsub.d'),
      (0x4F, 1, 'fnmadd.d'),
    ];
    final fails = <String>[];
    for (final (op, fmt, want) in fmaCases) {
      final got = config.isa.findOperation(enc4(op, fmt))?.mnemonic;
      if (got != want) {
        fails.add(
          '$want (op=0x${op.toRadixString(16)} fmt=$fmt) '
          '-> ${got ?? "NULL"}',
        );
      }
    }
    expect(fails, isEmpty, reason: 'mis-decoded: ${fails.join("; ")}');
  });
}
