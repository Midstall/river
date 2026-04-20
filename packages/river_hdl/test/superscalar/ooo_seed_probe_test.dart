import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';
import 'core_ooo_common.dart';

/// Regression for the OoO initRegisters-seed limitation (task #78). coreTest's
/// initRegisters seeds the ARCHITECTURAL regfile (core.regWritePort -> regs),
/// but the OoO core reads operand values from a SEPARATE PHYSICAL register file
/// (`prf` in pipeline.dart - srcValue() reads `muxArr(prf, psrc)`), which is
/// written only at execute-writeback (by physical dest), never from the seed. So
/// a seeded register reads as 0 on OoO. SKIPPED until a prf seed port lands;
/// until then OoO tests must COMPUTE register inputs in the program, not seed.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'OoO: a small seeded register reaches the read path',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        csr(0x340, 10, 0x1, 0), // csrrw x0, mscratch, x10  -> mscratch = x10
        csr(0x340, 0, 0x2, 3), // csrrs x3, mscratch, x0   -> x3 = mscratch
        ...List.filled(8, 0x00000013),
      ]),
      {Register.x3: 0x42},
      oooSpecConfig(),
      initRegisters: {Register.x10: 0x42},
      nextPc: 0x28,
    ),
  );
}
