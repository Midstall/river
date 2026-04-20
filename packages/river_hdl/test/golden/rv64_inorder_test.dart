import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_golden_vectors.dart';
import '../matrix_harness.dart';

void main() {
  const mxlen = RiscVMxlen.rv64;
  // Config carries base + M (covers arith/shift/mul/memory/lui golden vectors).
  runGolden(
    'golden: rv64 inorder',
    matrixConfig(mxlen, Uarch.inOrder, 'm'),
    inOrderGolden(mxlen),
  );
}
