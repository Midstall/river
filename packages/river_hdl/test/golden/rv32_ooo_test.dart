import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_golden_vectors.dart';
import '../matrix_harness.dart';

void main() {
  const mxlen = RiscVMxlen.rv32;
  runGolden(
    'golden: branch rv32 ooo',
    matrixConfig(mxlen, Uarch.ooo, 'branch'),
    branchGolden(mxlen),
  );
}
