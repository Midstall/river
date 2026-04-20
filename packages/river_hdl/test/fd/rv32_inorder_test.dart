import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

void main() {
  const category = 'fd';
  const mxlen = RiscVMxlen.rv32;
  const uarch = Uarch.inOrder;
  runMatrix(
    'matrix: $category ${mxlenLabel(mxlen)} ${uarchLabel(uarch)}',
    matrixConfig(mxlen, uarch, category),
    instructionsFor(category, mxlen),
  );
}
