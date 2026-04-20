import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

void main() {
  const category = 'bitmanip';
  const mxlen = RiscVMxlen.rv64;
  const uarch = Uarch.ooo;
  runMatrix(
    'matrix: $category ${mxlenLabel(mxlen)} ${uarchLabel(uarch)}',
    matrixConfig(mxlen, uarch, category),
    instructionsFor(category, mxlen),
  );
}
