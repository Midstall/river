import 'package:river/river.dart';

import '../matrix_configs.dart';
import '../matrix_instructions.dart';
import '../matrix_harness.dart';

/// Validates the registered (full-cycle) register-file read path in simulation.
///
/// The ECP5 EBR register file reads on the posedge (readLatency == 1) so the
/// read stays off the combinational ALU path and timing closes at 48 MHz. The
/// DP16KD is a blackbox with no sim model, so here we force the *flop* register
/// file to the same latency via [matrixConfig]'s regfileReadLatency. If the
/// in-order operand-read handshake (hold address, wait for done&valid, then
/// latch) correctly absorbs the extra cycle, every instruction still produces
/// the golden result. Runs the operand-read-heavy base + M categories.
void main() {
  const mxlen = RiscVMxlen.rv64;
  const uarch = Uarch.inOrder;
  for (final category in ['base', 'm']) {
    runMatrix(
      'matrix: $category ${mxlenLabel(mxlen)} ${uarchLabel(uarch)} '
      '(regfile readLatency=1)',
      matrixConfig(mxlen, uarch, category, regfileReadLatency: 1),
      instructionsFor(category, mxlen),
    );
  }
}
