import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:riscv/riscv.dart';

abstract class InstructionDecoder extends Module {
  final Mxlen mxlen;
  final Microcode microcode;
  final List<String> staticInstructions;

  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get index => output('index');
  Logic get counter => output('counter');

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
    required this.microcode,
    required this.mxlen,
    this.staticInstructions = const [],
    super.name = 'river_instruction_decoder',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);
    input = addInput('instr', input, width: 32);

    if (microcodeRead != null) {
      microcodeRead = microcodeRead!.clone()
        ..connectIO(
          this,
          microcodeRead!,
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
          if (microcodeRead != null) ...[
            microcodeRead!.en < 0,
            microcodeRead!.addr < 0,
          ],
          ...instrTypeMap.entries.map((entry) => entry.value < 0).toList(),
          ...fields.entries.map((entry) => entry.value < 0).toList(),
          ...this.reset(),
        ],
        orElse: [
          If(
            enable,
            then: [
              counter < (counter + 1),
              ...decode(input),
              if (microcodeRead != null)
                ...decodeMicrocode(input, microcodeRead!),
            ],
            orElse: [
              valid < 0,
              index < 0,
              done < 0,
              if (microcodeRead != null) ...[
                microcodeRead!.en < 0,
                microcodeRead!.addr < 0,
              ],
              ...instrTypeMap.entries.map((entry) => entry.value < 0).toList(),
              ...fields.entries.map((entry) => entry.value < 0).toList(),
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
    ].swizzle().zeroExtend(mxlen.size).signExtend(mxlen.size),
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
    _ => Const(0, width: mxlen.size),
  };

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
      final t = Microcode.instrType(i);
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

  DynamicInstructionDecoder(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic input,
    DataPortInterface microcodeRead, {
    required Microcode microcode,
    required Mxlen mxlen,
    int counterWidth = 32,
    List<String> staticInstructions = const [],
    String name = 'river_dynamic_instruction_decoder',
  }) : super(
         clk,
         reset,
         enable,
         input,
         microcodeRead: microcodeRead,
         microcode: microcode,
         mxlen: mxlen,
         counterWidth: counterWidth,
         staticInstructions: staticInstructions,
         name: name,
       );

  @override
  void initState() {
    _counter = Logic(
      name: 'counter',
      width: microcode.decodeLookup.length.bitLength,
    );
  }

  @override
  List<Conditional> reset() => [_counter < 0];

  @override
  List<Conditional> decodeMicrocode(
    Logic input,
    DataPortInterface microcodeRead,
  ) {
    final patternStruct = OperationDecodePattern.struct(
      microcode.opIndices.length.bitLength,
      microcode.typeStructs.length.bitLength,
      microcode.fieldIndices,
    );

    final pattern = Map.fromEntries(
      patternStruct.mapping.entries.map((entry) {
        final patternName = entry.key;
        final range = entry.value;
        final value = microcodeRead.data.getRange(range.start, range.end + 1);
        return MapEntry(patternName, value);
      }),
    );

    final nzfMatch = mux(
      pattern['nzfMask']!.neq(0),
      (input & pattern['nzfMask']!).neq(0),
      Const(1),
    ).named('nzfMatch');
    final zfMatch = mux(
      pattern['zfMask']!.neq(0),
      (input & pattern['zfMask']!).eq(0),
      Const(1),
    ).named('zfMatch');

    final patternMatch = (input & pattern['mask']!)
        .eq(pattern['value']!)
        .named('patternMatch');

    return [
      microcodeRead.en < 1,
      microcodeRead.addr < _counter,
      If(
        microcodeRead.done,
        then: [
          If(
            microcodeRead.valid,
            then: [
              If(
                patternMatch & nzfMatch & zfMatch,
                then: [
                  index < pattern['opIndex']!.zeroExtend(index.width),
                  ...fields.entries.map((entry) => entry.value < 0).toList(),
                  ...instrTypeMap.entries
                      .map((entry) => entry.value < 0)
                      .toList(),
                  Case(pattern['type']!, [
                    for (final e in instrTypeMap.entries.indexed)
                      CaseItem(
                        Const(e.$1, width: instrTypeMap.length.bitLength),
                        [
                          e.$2.value < 1,
                          done < 1,
                          valid < 1,
                          ...microcode.typeStructs[e.$2.key]!.mapping.entries
                              .where((entry) => entry.key != 'imm')
                              .map((entry) {
                                final fieldName = entry.key;
                                final fieldOutput = fields[fieldName]!;
                                final range = entry.value;
                                final value = input
                                    .slice(range.end, range.start)
                                    .zeroExtend(fieldOutput.width)
                                    .named(fieldName);
                                return fieldOutput < value;
                              })
                              .toList(),
                          fields['imm']! < decodeImm(e.$2.key, input),
                        ],
                      ),
                  ]),
                ],
                orElse: [
                  _counter < (_counter + 1),
                  done < 0,
                  valid < 0,
                  index < 0,
                  ...instrTypeMap.entries
                      .map((entry) => entry.value < 0)
                      .toList(),
                  ...fields.entries.map((entry) => entry.value < 0).toList(),
                ],
              ),
            ],
            orElse: [
              done < 1,
              valid < 0,
              index < 0,
              ...instrTypeMap.entries.map((entry) => entry.value < 0).toList(),
              ...fields.entries.map((entry) => entry.value < 0).toList(),
            ],
          ),
        ],
        orElse: [
          done < 0,
          valid < 0,
          index < 0,
          ...instrTypeMap.entries.map((entry) => entry.value < 0).toList(),
          ...fields.entries.map((entry) => entry.value < 0).toList(),
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
    super.name = 'river_static_instruction_decoder',
  });

  List<Conditional> decode(Logic input) {
    final decodeMap = lookupDecode(input);

    return [
      If.block([
        ...decodeMap.entries
            .map(
              (entry) => Iff(entry.value, [
                valid < 1,
                index < Const(entry.key.opIndex, width: index.width),
                ...fields.entries.map((entry) => entry.value < 0).toList(),
                ...instrTypeMap.entries
                    .map((entry) => entry.value < 0)
                    .toList(),
                instrTypeMap[Microcode.instrType(
                      microcode.execLookup[entry.key.opIndex]!,
                    )]! <
                    1,
                ...microcode
                    .execLookup[entry.key.opIndex]!
                    .struct
                    .mapping
                    .entries
                    .where((entry) => entry.key != 'imm')
                    .map((entry) {
                      final fieldName = entry.key;
                      final fieldOutput = fields[fieldName]!;
                      final range = entry.value;
                      final value = input
                          .getRange(range.start, range.end + 1)
                          .zeroExtend(fieldOutput.width)
                          .named(fieldName);
                      return fieldOutput < value;
                    })
                    .toList(),
                fields['imm']! <
                    decodeImm(
                      Microcode.instrType(
                        microcode.execLookup[entry.key.opIndex]!,
                      ),
                      input,
                    ),
                done < 1,
              ]),
            )
            .toList(),
        Else([
          valid < 0,
          index < 0,
          done < 1,
          ...instrTypeMap.entries.map((entry) => entry.value < 0).toList(),
          ...fields.entries.map((entry) => entry.value < 0).toList(),
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
