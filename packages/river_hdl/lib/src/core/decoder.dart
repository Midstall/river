import 'package:rohd/rohd.dart';
import 'package:harbor/harbor.dart' hide PrivilegeMode;
import 'package:river/river.dart';
import '../data_port.dart';
import '../microcode_rom.dart';

abstract class InstructionDecoder extends Module {
  final RiscVMxlen mxlen;
  final MicrocodeRom microcode;
  final List<String> staticInstructions;

  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get index => output('index');
  Logic get counter => output('counter');

  /// The PC of the instruction whose decode is on the outputs. Passed in
  /// alongside the raw instruction and registered with the decode, so the PC,
  /// instruction, and decoded fields all describe the same instruction (fixes
  /// the PC/decode skew that mis-routes branches).
  Logic get pcOut => output('pc_out');

  Map<String, Logic> get fields => Map.fromEntries(
    fieldWidths.entries.map(
      (entry) => MapEntry(entry.key, output(computeName(entry.key))),
    ),
  );

  Map<String, Logic> get instrTypeMap =>
      Map.fromEntries(instrTypes.map((t) => MapEntry(t, output('is_$t'))));

  InstructionDecoder(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic input, {
    int counterWidth = 32,
    DataPortInterface? microcodeRead,
    Logic? pcIn,
    required this.microcode,
    required this.mxlen,
    this.staticInstructions = const [],
    super.name = 'river_instruction_decoder',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);
    input = addInput('instr', input, width: 32);
    pcIn = addInput(
      'pc_in',
      pcIn ?? Const(0, width: mxlen.size),
      width: mxlen.size,
    );

    if (microcodeRead != null) {
      microcodeRead = microcodeRead.clone()
        ..connectIO(
          this,
          microcodeRead,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'microcodeRead_$og',
        );
    }

    addOutput('done');
    addOutput('valid');
    addOutput('index', width: microcode.opIndexWidth);
    addOutput('imm', width: mxlen.size);
    addOutput('counter', width: counterWidth);
    addOutput('pc_out', width: mxlen.size);

    for (final entry in fieldWidths.entries) {
      if (entry.key == 'imm') continue;

      addOutput(computeName(entry.key), width: entry.value);
    }

    for (final t in instrTypes) {
      addOutput('is_$t');
    }

    initState();

    Sequential(clk, [
      If(
        reset,
        then: [
          valid < 0,
          index < 0,
          done < 0,
          counter < 0,
          pcOut < 0,
          if (microcodeRead != null) ...[
            microcodeRead.en < 0,
            microcodeRead.addr < 0,
          ],
          ...instrTypeMap.entries.map((entry) => entry.value < 0),
          ...fields.entries.map((entry) => entry.value < 0),
          ...this.reset(),
        ],
        orElse: [
          If(
            enable,
            then: [
              counter < (counter + 1),
              pcOut < pcIn,
              ...decode(input),
              if (microcodeRead != null)
                ...decodeMicrocode(input, microcodeRead),
            ],
            orElse: [
              valid < 0,
              index < 0,
              done < 0,
              if (microcodeRead != null) ...[
                microcodeRead.en < 0,
                microcodeRead.addr < 0,
              ],
              ...instrTypeMap.entries.map((entry) => entry.value < 0),
              ...fields.entries.map((entry) => entry.value < 0),
              ...this.reset(),
            ],
          ),
        ],
      ),
    ]);
  }

  Logic decodeImm(String type, Logic input) => switch (type) {
    'IType' => input.slice(31, 20).signExtend(mxlen.size),
    'SType' => [
      input.slice(31, 25),
      input.slice(11, 7),
    ].swizzle().signExtend(mxlen.size),
    'BType' => [
      input.slice(31, 31),
      input.slice(7, 7),
      input.slice(30, 25),
      input.slice(11, 8),
      Const(0, width: 1),
    ].swizzle().signExtend(mxlen.size),
    'UType' => [
      input.slice(31, 12),
      Const(0, width: 12),
    ].swizzle().signExtend(mxlen.size),
    'JType' => [
      input.slice(31, 31),
      input.slice(19, 12),
      input.slice(20, 20),
      input.slice(30, 21),
      Const(0, width: 1),
    ].swizzle().signExtend(mxlen.size),
    'SystemIType' => input.slice(31, 20).signExtend(mxlen.size),
    // CJ/CB now go through immFor()/rvcImmLogic via op.immKind; these legacy
    // cases remain for the dynamic (microcoded) decoder's type-string path.
    // CJ-type (c.j, c.jal): offset[11|4|9:8|10|6|7|3:1|5], sign-extended.
    'CJType' => [
      input.slice(12, 12), // off[11]
      input.slice(8, 8), // off[10]
      input.slice(10, 10), // off[9]
      input.slice(9, 9), // off[8]
      input.slice(6, 6), // off[7]
      input.slice(7, 7), // off[6]
      input.slice(2, 2), // off[5]
      input.slice(11, 11), // off[4]
      input.slice(5, 5), // off[3]
      input.slice(4, 4), // off[2]
      input.slice(3, 3), // off[1]
      Const(0, width: 1), // off[0]
    ].swizzle().signExtend(mxlen.size),
    // CB-type (c.beqz, c.bnez): offset[8|4:3|7:6|2:1|5], sign-extended.
    'CBType' => [
      input.slice(12, 12), // off[8]
      input.slice(6, 6), // off[7]
      input.slice(5, 5), // off[6]
      input.slice(2, 2), // off[5]
      input.slice(11, 11), // off[4]
      input.slice(10, 10), // off[3]
      input.slice(4, 4), // off[2]
      input.slice(3, 3), // off[1]
      Const(0, width: 1), // off[0]
    ].swizzle().signExtend(mxlen.size),
    _ => Const(0, width: mxlen.size),
  };

  /// Immediate for [op]: compressed instructions use their per-instruction RVC
  /// descramble ([RiscVOperation.immKind]); everything else uses the format's
  /// type-based layout via [decodeImm].
  Logic immFor(RiscVOperation op, Logic input) => op.immKind != null
      ? rvcImmLogic(op.immKind!, input, mxlen.size)
      : decodeImm(MicrocodeRom.instrType(op), input);

  /// Computes the canonical 5-bit register index for [role] ('rd'/'rs1'/'rs2')
  /// of a compressed operation [op] from [instr]. Handles implicit (fixed)
  /// registers, the rd_rs1 alias, and the 3-bit prime fields that map to
  /// x8-x15. Mirrors [DecodedInstruction.fromCompressed] in the emulator.
  /// Shared by the static and dynamic (microcode) decoders.
  Logic compReg(RiscVOperation op, Logic instr, String role) {
    final fixed = switch (role) {
      'rd' => op.fixedRd,
      'rs1' => op.fixedRs1,
      'rs2' => op.fixedRs2,
      _ => null,
    };
    if (fixed != null) return Const(fixed, width: 5);

    final f = op.format.fields;
    String? key;
    var prime = false;
    switch (role) {
      case 'rd':
        if (f.containsKey('rd_rs1_prime')) {
          key = 'rd_rs1_prime';
          prime = true;
        } else if (f.containsKey('rd_prime')) {
          key = 'rd_prime';
          prime = true;
        } else if (f.containsKey('rd_rs1')) {
          key = 'rd_rs1';
        } else if (f.containsKey('rd')) {
          key = 'rd';
        }
      case 'rs1':
        if (f.containsKey('rd_rs1_prime')) {
          key = 'rd_rs1_prime';
          prime = true;
        } else if (f.containsKey('rs1_prime')) {
          key = 'rs1_prime';
          prime = true;
        } else if (f.containsKey('rd_rs1')) {
          key = 'rd_rs1';
        } else if (f.containsKey('rs1')) {
          key = 'rs1';
        }
      case 'rs2':
        if (f.containsKey('rs2_prime')) {
          key = 'rs2_prime';
          prime = true;
        } else if (f.containsKey('rs2')) {
          key = 'rs2';
        }
    }
    if (key == null) return Const(0, width: 5);

    final range = f[key]!;
    final raw = instr.slice(range.end, range.start);
    // Prime fields are 3 bits and map to x8-x15: {2'b01, raw} == raw + 8.
    return prime ? [Const(1, width: 2), raw].swizzle() : raw.zeroExtend(5);
  }

  void initState() {}

  List<Conditional> decode(Logic instr) => [];

  List<Conditional> decodeMicrocode(
    Logic instr,
    DataPortInterface microcodeRead,
  ) => [];

  List<Conditional> reset() => [];

  List<String> get instrTypes {
    List<String> result = [];
    for (final i in microcode.map.values) {
      final t = MicrocodeRom.instrType(i);
      if (result.contains(t)) continue;
      result.add(t);
    }
    return result;
  }

  Map<String, int> get fieldWidths {
    final widths = <String, int>{};
    for (final entry in microcode.fields.entries) {
      final fieldName = entry.key;
      final patternMap = entry.value;

      int maxWidth = 0;
      for (final range in patternMap.values) {
        if (range.width > maxWidth) maxWidth = range.width;
      }

      widths[fieldName] = maxWidth;
    }
    return widths;
  }

  static String computeName(String input) {
    return input.replaceAll('[', '_').replaceAll(']', '').replaceAll(':', '_');
  }
}

class DynamicInstructionDecoder extends InstructionDecoder {
  late final Logic _counter;

  /// Latched once the pattern search matches, holding the decode result stable
  /// while the multi-cycle exec unit consumes it. The base decoder clears it
  /// (via [reset]) when `enable` drops at the commit boundary, so the next
  /// instruction re-searches fresh.
  late final Logic _held;

  DynamicInstructionDecoder(
    super.clk,
    super.reset,
    super.enable,
    super.input,
    DataPortInterface microcodeRead, {
    required super.microcode,
    required super.mxlen,
    super.counterWidth,
    super.staticInstructions,
    super.pcIn,
    super.name = 'river_dynamic_instruction_decoder',
  }) : super(microcodeRead: microcodeRead);

  @override
  void initState() {
    _counter = Logic(
      name: 'counter',
      width: microcode.decodeLookup.length.bitLength,
    );
    _held = Logic(name: 'held');
  }

  @override
  List<Conditional> reset() => [_counter < 0, _held < 0];

  @override
  List<Conditional> decodeMicrocode(
    Logic instr,
    DataPortInterface microcodeRead,
  ) {
    final patternStruct = OperationDecodePattern.struct(
      microcode.opIndexWidth,
      microcode.typeStructs.length.bitLength,
    );

    // Parallel decode lanes: microcodeRead.data holds `lanes` pattern rows
    // (lane 0 in the low bits). Match the instruction against every lane this
    // cycle and priority-select the lowest-index matching row, so the scan
    // advances `lanes` patterns per cycle instead of one. lanes==1 degenerates
    // to reading the single row straight through.
    final rowW = microcode.patternWidth;
    final lanes = microcodeRead.data.width ~/ rowW;
    Logic laneRow(int lane) =>
        microcodeRead.data.getRange(lane * rowW, (lane + 1) * rowW);
    Logic rowField(Logic row, String name) {
      final r = patternStruct.mapping[name]!;
      return row.getRange(r.start, r.end + 1);
    }

    Logic laneMatch(Logic row) {
      final pm = (instr & rowField(row, 'mask')).eq(rowField(row, 'value'));
      final nzf = mux(
        rowField(row, 'nzfMask').neq(0),
        (instr & rowField(row, 'nzfMask')).neq(0),
        Const(1),
      );
      final zf = mux(
        rowField(row, 'zfMask').neq(0),
        (instr & rowField(row, 'zfMask')).eq(0),
        Const(1),
      );
      return pm & nzf & zf;
    }

    var selData = laneRow(lanes - 1);
    for (var l = lanes - 2; l >= 0; l--) {
      selData = mux(
        laneMatch(laneRow(l)),
        laneRow(l),
        selData,
      ).named('decodeSelData_$l');
    }

    final pattern = Map.fromEntries(
      patternStruct.mapping.entries.map((entry) {
        final patternName = entry.key;
        final range = entry.value;
        final value = selData.getRange(range.start, range.end + 1);
        return MapEntry(patternName, value);
      }),
    );

    // opIndex -> operation, using the same running offset the ROM assigns
    // (i += microcode.length + 1). Lets the per-op override below key on the
    // runtime opIndex; the generic type-based extraction is blind to
    // op.fixedRs1/fixedRd/fixedRs2 and op.immKind (so c.sdsp/c.ldsp would else
    // decode rs1=0/imm=0 -> store/load @ 0).
    final opByIndex = <int, RiscVOperation>{};
    {
      var i = 0;
      for (final e in microcode.map.entries) {
        opByIndex[i] = e.value;
        i += e.value.microcode.length + 1;
      }
    }
    // Ops needing an override: anything compressed, or carrying a fixed implicit
    // register or a per-instruction RVC immediate kind.
    bool needsOverride(RiscVOperation op) =>
        (op.opcode & 0x3) != 0x3 ||
        op.immKind != null ||
        op.fixedRd != null ||
        op.fixedRs1 != null ||
        op.fixedRs2 != null;
    final overrideOps = opByIndex.entries
        .where((e) => needsOverride(e.value))
        .toList();
    final opIdxWidth = pattern['opIndex']!.width;

    final nzfMatch = mux(
      pattern['nzfMask']!.neq(0),
      (instr & pattern['nzfMask']!).neq(0),
      Const(1),
    ).named('nzfMatch');
    final zfMatch = mux(
      pattern['zfMask']!.neq(0),
      (instr & pattern['zfMask']!).eq(0),
      Const(1),
    ).named('zfMatch');

    final patternMatch = (instr & pattern['mask']!)
        .eq(pattern['value']!)
        .named('patternMatch');

    return [
      If(
        _held,
        // Decode already found: hold the latched result and re-assert done/valid
        // so the multi-cycle exec sees a stable decode. Base clears _held via
        // reset() at the commit boundary.
        then: [microcodeRead.en < 0, done < 1, valid < 1],
        orElse: [
          microcodeRead.en < 1,
          // _counter is sized for the unpacked pattern count; the packed ROM has
          // ceil(patterns/lanes) words, so its address port is narrower.
          microcodeRead.addr < _counter.getRange(0, microcodeRead.addr.width),
          If(
            microcodeRead.done,
            then: [
              If(
                microcodeRead.valid,
                then: [
                  If(
                    patternMatch & nzfMatch & zfMatch,
                    then: [
                      _held < 1,
                      index < pattern['opIndex']!.zeroExtend(index.width),
                      ...fields.entries.map((entry) => entry.value < 0),
                      ...instrTypeMap.entries.map((entry) => entry.value < 0),
                      Case(pattern['type']!, [
                        for (final e in instrTypeMap.entries.indexed)
                          CaseItem(
                            Const(e.$1, width: instrTypeMap.length.bitLength),
                            [
                              e.$2.value < 1,
                              done < 1,
                              valid < 1,
                              ...microcode.typeStructs[e.$2.key]!.fields.entries
                                  .where((entry) => entry.key != 'imm')
                                  .map((entry) {
                                    final fieldName = entry.key;
                                    final fieldOutput = fields[fieldName]!;
                                    final range = entry.value;
                                    final extracted = instr.slice(
                                      range.end,
                                      range.start,
                                    );
                                    final value =
                                        extracted.width <= fieldOutput.width
                                        ? extracted.zeroExtend(
                                            fieldOutput.width,
                                          )
                                        : extracted.slice(
                                            fieldOutput.width - 1,
                                            0,
                                          );
                                    return fieldOutput < value.named(fieldName);
                                  }),
                              fields['imm']! < decodeImm(e.$2.key, instr),
                            ],
                          ),
                      ]),
                      // Per-op override: apply implicit fixed registers and the RVC
                      // immediate descramble for compressed ops (the type-based
                      // extraction above is blind to op.fixedRs1 etc. and op.immKind).
                      // Keyed on the matched opIndex, later in the list so it wins.
                      if (overrideOps.isNotEmpty)
                        Case(pattern['opIndex']!, [
                          for (final e in overrideOps)
                            CaseItem(Const(e.key, width: opIdxWidth), [
                              fields['rd']! < compReg(e.value, instr, 'rd'),
                              fields['rs1']! < compReg(e.value, instr, 'rs1'),
                              fields['rs2']! < compReg(e.value, instr, 'rs2'),
                              fields['imm']! < immFor(e.value, instr),
                            ]),
                        ]),
                    ],
                    orElse: [
                      _counter < (_counter + 1),
                      done < 0,
                      valid < 0,
                      index < 0,
                      ...instrTypeMap.entries.map((entry) => entry.value < 0),
                      ...fields.entries.map((entry) => entry.value < 0),
                    ],
                  ),
                ],
                orElse: [
                  done < 1,
                  valid < 0,
                  index < 0,
                  ...instrTypeMap.entries.map((entry) => entry.value < 0),
                  ...fields.entries.map((entry) => entry.value < 0),
                ],
              ),
            ],
            orElse: [
              done < 0,
              valid < 0,
              index < 0,
              ...instrTypeMap.entries.map((entry) => entry.value < 0),
              ...fields.entries.map((entry) => entry.value < 0),
            ],
          ),
        ],
      ),
    ];
  }
}

class StaticInstructionDecoder extends InstructionDecoder {
  StaticInstructionDecoder(
    super.clk,
    super.reset,
    super.enable,
    super.input, {
    required super.microcode,
    required super.mxlen,
    super.staticInstructions,
    super.counterWidth = 32,
    super.pcIn,
    super.name = 'river_static_instruction_decoder',
  });

  @override
  List<Conditional> decode(Logic instr) {
    final decodeMap = lookupDecode(instr);

    return [
      If.block([
        ...decodeMap.entries.map((mapEntry) {
          final op = microcode.execLookup[mapEntry.key.opIndex]!;
          final isComp = (op.opcode & 0x3) != 0x3;
          return Iff(mapEntry.value, [
            valid < 1,
            index < Const(mapEntry.key.opIndex, width: index.width),
            ...fields.entries.map((e) => e.value < 0),
            ...instrTypeMap.entries.map((e) => e.value < 0),
            instrTypeMap[MicrocodeRom.instrType(op)]! < 1,
            ...op.format.fields.entries.where((e) => e.key != 'imm').map((e) {
              final fieldOutput = fields[e.key]!;
              final range = e.value;
              final extracted = instr.getRange(range.start, range.end + 1);
              final value = extracted.width <= fieldOutput.width
                  ? extracted.zeroExtend(fieldOutput.width)
                  : extracted.slice(fieldOutput.width - 1, 0);
              return fieldOutput < value.named(e.key);
            }),
            // Compressed register mapping: translate prime (x8-x15), rd_rs1
            // aliasing, and implicit (fixed) registers into rd/rs1/rs2 that the
            // pipeline reads. Mirrors the emulator's DecodedInstruction logic.
            if (isComp) ...[
              fields['rd']! < compReg(op, instr, 'rd'),
              fields['rs1']! < compReg(op, instr, 'rs1'),
              fields['rs2']! < compReg(op, instr, 'rs2'),
            ],
            fields['imm']! < immFor(op, instr),
            done < 1,
          ]);
        }),
        Else([
          valid < 0,
          index < 0,
          done < 1,
          ...instrTypeMap.entries.map((entry) => entry.value < 0),
          ...fields.entries.map((entry) => entry.value < 0),
        ]),
      ]),
    ];
  }

  Map<OperationDecodePattern, Logic> lookupDecode(Logic input) =>
      Map.fromEntries(
        microcode.decodeLookup.entries
            .where(
              (entry) => staticInstructions.isNotEmpty
                  ? staticInstructions.contains(
                      microcode.execLookup[entry.key]!.mnemonic,
                    )
                  : true,
            )
            .map((entry) {
              final nzfMatch = entry.value.nzfMask == 0
                  ? Const(1)
                  : (input & Const(entry.value.nzfMask, width: 32)).neq(0);
              final zfMatch = entry.value.zfMask == 0
                  ? Const(1)
                  : (input & Const(entry.value.zfMask, width: 32)).eq(0);

              final mask = Const(entry.value.mask, width: 32);
              final value = Const(entry.value.value, width: 32);

              return MapEntry(
                entry.value,
                (input & mask).eq(value) & nzfMatch & zfMatch,
              );
            }),
      );
}
