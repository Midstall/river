import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_golden_vectors.dart';
import '../matrix_harness.dart';

void main() {
  const mxlen = RiscVMxlen.rv32;
  runGolden(
    'golden: rv32 inorder',
    matrixConfig(mxlen, Uarch.inOrder, 'm'),
    inOrderGolden(mxlen),
  );
}
