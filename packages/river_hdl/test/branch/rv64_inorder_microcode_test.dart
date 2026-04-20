import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

/// In-order MICROCODE path (DynamicExecutionUnit + microcode ROM,
/// MicrocodeMode.full) for the 'branch' category, validated against the emulator
/// golden. This is the area-first path rc1-s (creek) uses on small FPGAs. Split
/// per-category so dart test parallelizes across isolates (one big file
/// accumulates heap across builds and times out - see project_parity /
/// feedback_test_parallelism).
void main() {
  const category = 'branch';
  const mxlen = RiscVMxlen.rv64;
  const uarch = Uarch.inOrder;
  runMatrix(
    'matrix: $category ${mxlenLabel(mxlen)} ${uarchLabel(uarch)} (microcode)',
    matrixConfig(mxlen, uarch, category, microcodeMode: MicrocodeMode.full),
    instructionsFor(category, mxlen),
  );
}
