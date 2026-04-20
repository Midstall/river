import 'package:harbor/harbor.dart';
import 'package:river/river.dart';
import 'package:river_hdl/src/core/decode_control.dart';
import 'package:river_hdl/src/core/issue.dart' show FuType;
import 'package:test/test.dart';

import '../constants.dart';

void main() {
  group('decodeControlForOp', () {
    // RC1.mi (RV32IMAC + Zicsr) has the full mix: ALU, mem, branch, jump, CSR.
    final ops = kCpuConfigs['RC1.mi']!.isa.allOperations;
    DecodeControl ctrl(String mnemonic) {
      final op = ops.firstWhere(
        (o) => o.mnemonic == mnemonic,
        orElse: () => throw StateError('no op "$mnemonic" in RC1.mi'),
      );
      return decodeControlForOp(op);
    }

    test('add → ALU, add, writes rd, register operand', () {
      final c = ctrl('add');
      expect(c.fuType, FuType.alu);
      expect(c.aluFunct, RiscVAluFunct.add);
      expect(c.writesRd, isTrue);
      expect(c.useImm, isFalse);
      expect(c.isLoad, isFalse);
      expect(c.isStore, isFalse);
    });

    test('addi → ALU, add, immediate operand', () {
      final c = ctrl('addi');
      expect(c.fuType, FuType.alu);
      expect(c.aluFunct, RiscVAluFunct.add);
      expect(c.useImm, isTrue);
      expect(c.writesRd, isTrue);
    });

    test('sub → ALU, sub', () {
      expect(ctrl('sub').aluFunct, RiscVAluFunct.sub);
    });

    test('lw → memory load, writes rd, word size', () {
      final c = ctrl('lw');
      expect(c.fuType, FuType.memory);
      expect(c.isLoad, isTrue);
      expect(c.isStore, isFalse);
      expect(c.writesRd, isTrue);
      expect(c.memSize, RiscVMemSize.word);
    });

    test('sw → memory store, no rd write', () {
      final c = ctrl('sw');
      expect(c.fuType, FuType.memory);
      expect(c.isStore, isTrue);
      expect(c.isLoad, isFalse);
      expect(c.writesRd, isFalse);
    });

    test('beq → branch, eq condition, no jump, no rd write', () {
      final c = ctrl('beq');
      expect(c.fuType, FuType.branch);
      expect(c.branchCond, RiscVBranchCondition.eq);
      expect(c.isJump, isFalse);
      expect(c.writesRd, isFalse);
    });

    test('jal → unconditional jump, PC-relative, writes link', () {
      final c = ctrl('jal');
      expect(c.fuType, FuType.branch);
      expect(c.isJump, isTrue);
      expect(c.isJalr, isFalse);
      expect(c.writesRd, isTrue);
    });

    test('jalr → unconditional jump, register-indirect, writes link', () {
      final c = ctrl('jalr');
      expect(c.fuType, FuType.branch);
      expect(c.isJump, isTrue);
      expect(c.isJalr, isTrue);
      expect(c.writesRd, isTrue);
    });

    test('csrrw → CSR unit, writes rd', () {
      final c = ctrl('csrrw');
      expect(c.fuType, FuType.csr);
      expect(c.isCsr, isTrue);
      expect(c.writesRd, isTrue);
    });
  });
}
