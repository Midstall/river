import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_golden_vectors.dart';
import '../matrix_harness.dart';

void main() {
  const mxlen = RiscVMxlen.rv64;
  // Branch vectors need a predictor -> OoO+btfn config.
  runGolden(
    'golden: branch rv64 ooo',
    matrixConfig(mxlen, Uarch.ooo, 'branch'),
    branchGolden(mxlen),
  );
}
