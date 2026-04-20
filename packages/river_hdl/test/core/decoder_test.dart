import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:harbor/harbor.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

Future<void> decoderTest(
  int instr,
  Map<String, int> fields,
  RiscVMxlen mxlen,
  MicrocodeRom microcode, {
  bool isDynamic = false,
}) async {
  final clk = SimpleClockGenerator(20).clk;

  final reset = Logic();
  final enable = Logic();
  final input = Const(instr, width: 32);

  final microcodeRead = DataPortInterface(
    microcode.patternWidth,
    microcode.decodeLookup.length.bitLength,
  );

  RegisterFile(
    clk,
    reset,
    [],
    [wrapReadForRegisterFile(microcodeRead)],
    numEntries: microcode.map.length,
    resetValue: microcode.encodedPatterns,
  );

  final decoder = isDynamic
      ? DynamicInstructionDecoder(
          clk,
          reset,
          enable,
          input,
          microcodeRead,
          microcode: microcode,
          mxlen: mxlen,
        )
      : StaticInstructionDecoder(
          clk,
          reset,
          enable,
          input,
          microcode: microcode,
          mxlen: mxlen,
        );

  await decoder.build();

  reset.inject(1);
  enable.inject(0);

  Simulator.registerAction(20, () {
    reset.put(0);
    enable.put(1);
  });

  unawaited(Simulator.run());

  await clk.nextPosedge;

  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  while (true) {
    final d = decoder.done.value;
    if (d.isValid && d.toBool()) break;
    await clk.nextPosedge;
  }

  // Capture field values when done is asserted
  final valid = decoder.valid.value;
  final fieldValues = <String, LogicValue>{};
  for (final entry in fields.entries) {
    final f = decoder.fields[entry.key];
    if (f != null) fieldValues[entry.key] = f.value;
  }

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  expect(valid.toBool(), isTrue);

  for (final entry in fields.entries) {
    final value = fieldValues[entry.key]!.toInt();
    expect(value, equals(entry.value), reason: '${entry.key}=$value');
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  void define(bool isDynamic) {
    group('RV32I', () {
      final microcode = MicrocodeRom(
        RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]),
      );

      test('R-type: add x3, x1, x2', () async {
        await decoderTest(
          0x002081B3,
          {
            'opcode': 0x33,
            'rd': 3,
            'rs1': 1,
            'rs2': 2,
            'funct3': 0,
            'funct7': 0,
          },
          RiscVMxlen.rv32,
          microcode,
          isDynamic: isDynamic,
        );
      });

      test('I-type: addi x5, x1, 10', () async {
        await decoderTest(
          0x00A08293,
          {'opcode': 0x13, 'rd': 5, 'rs1': 1, 'imm': 10, 'funct3': 0},
          RiscVMxlen.rv32,
          microcode,
          isDynamic: isDynamic,
        );
      });

      test('S-type: sw x2, 12(x1)', () async {
        await decoderTest(
          0x0020A623,
          {'opcode': 0x23, 'rs1': 1, 'rs2': 2, 'funct3': 0x2, 'immLo': 12},
          RiscVMxlen.rv32,
          microcode,
          isDynamic: isDynamic,
        );
      });

      // A negative store offset must sign-extend the S-type immediate to full
      // width. Regression for the zero-extend-then-sign-extend no-op bug.
      test('S-type sign-extend: sw x2, -4(x1)', () async {
        await decoderTest(
          0xFE20AE23,
          {
            'opcode': 0x23,
            'rs1': 1,
            'rs2': 2,
            'funct3': 0x2,
            'imm': 0xFFFFFFFC,
          },
          RiscVMxlen.rv32,
          microcode,
          isDynamic: isDynamic,
        );
      });
    });
  }

  group('Static decoding', () => define(false));
  group('Dynamic decoding', () => define(true));
}
