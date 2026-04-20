import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';
import 'core_ooo_common.dart';

/// Out-of-order SPECULATIVE front-end (speculativeFetch=true): fetch advances at
/// allocation, instructions overlap in the ROB, and branch/jump redirects flush
/// the back-end and steer the fetcher. Split from core_ooo_test.dart so each
/// file stays under the per-file timeout (each test builds a fresh HDL core).
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Speculative fetch: the PC advances every cycle instead of waiting for
  // commit, so the addis/nops overlap the multi-cycle mul in the ROB.
  test(
    'speculative fetch overlaps a multi-cycle mul with a straight-line backlog',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(6, 0, 0x0, 1), // addi x1, x0, 6
        iimm(7, 0, 0x0, 2), // addi x2, x0, 7
        r(0x01, 2, 1, 0x0, 3), // mul  x3, x1, x2 -> 42 (multi-cycle)
        iimm(1, 1, 0x0, 4), // addi x4, x1, 1 -> 7
        iimm(2, 1, 0x0, 5), // addi x5, x1, 2 -> 8
        iimm(3, 1, 0x0, 6), // addi x6, x1, 3 -> 9
        iimm(4, 1, 0x0, 7), // addi x7, x1, 4 -> 10
        ...List.filled(8, 0x00000013), // nop tail (halt target inside it)
      ]),
      {
        Register.x1: 6,
        Register.x2: 7,
        Register.x3: 42,
        Register.x4: 7,
        Register.x5: 8,
        Register.x6: 9,
        Register.x7: 10,
      },
      oooSpecConfig(),
      nextPc: 0x3C,
    ),
  );

  // Speculative + taken branch: commits its redirect through the ROB -> flush
  // back-end + steer the fetcher to the target. The skipped instruction must NOT
  // retire.
  test(
    'speculative taken branch redirects past the skipped instruction',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1), // addi x1, x0, 5
        iimm(5, 0, 0x0, 2), // addi x2, x0, 5
        b(8, 2, 1, 0x0), // beq x1, x2, +8 -> taken, target = 0x08+8 = 0x10
        iimm(99, 0, 0x0, 3), // addi x3, x0, 99  (SKIPPED, x3 stays 0)
        iimm(7, 0, 0x0, 4), // addi x4, x0, 7   (branch target @0x10)
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x1: 5, Register.x2: 5, Register.x3: 0, Register.x4: 7},
      oooSpecConfig(),
      nextPc: 0x34,
    ),
  );

  // Speculative + NOT-taken branch: must fall through (no redirect) and the
  // following instruction MUST execute.
  test(
    'speculative not-taken branch falls through',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1), // addi x1, x0, 5
        iimm(6, 0, 0x0, 2), // addi x2, x0, 6
        b(8, 2, 1, 0x0), // beq x1, x2, +8 -> NOT taken (5 != 6)
        iimm(99, 0, 0x0, 3), // addi x3, x0, 99  (executes; x3 = 99)
        iimm(7, 0, 0x0, 4), // addi x4, x0, 7
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x1: 5, Register.x2: 6, Register.x3: 99, Register.x4: 7},
      oooSpecConfig(),
      nextPc: 0x34,
    ),
  );

  // Speculative + LOOP (backward taken branches): repeated taken redirects to an
  // earlier PC plus a cross-iteration RAW chain.
  test(
    'speculative counted loop (backward branch redirects)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(3, 0, 0x0, 1), // 0x00 addi x1, x0, 3   (loop count)
        iimm(0, 0, 0x0, 2), // 0x04 addi x2, x0, 0   (accumulator)
        iimm(1, 2, 0x0, 2), // 0x08 addi x2, x2, 1   loop body  <- target
        iimm(-1, 1, 0x0, 1), // 0x0C addi x1, x1, -1
        b(-8, 0, 1, 0x1), // 0x10 bne x1, x0, -8 -> back to 0x08 while x1!=0
        ...List.filled(11, 0x00000013), // 0x14.. nop tail
      ]),
      {Register.x1: 0, Register.x2: 3},
      oooSpecConfig(),
      nextPc: 0x3C,
    ),
  );

  // Straight-line RAW chain in SPECULATIVE mode: every instruction depends on
  // the immediately preceding one with no branch to serialise them, so the
  // producer is still in flight when the consumer renames - exercises the
  // physical-register-file + wakeup forwarding end to end.
  test(
    'speculative straight-line RAW chain forwards in-flight operands',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(1, 0, 0x0, 1), // addi x1, x0, 1  -> 1
        iimm(1, 1, 0x0, 2), // addi x2, x1, 1  -> 2
        iimm(1, 2, 0x0, 3), // addi x3, x2, 1  -> 3
        iimm(1, 3, 0x0, 4), // addi x4, x3, 1  -> 4
        iimm(1, 4, 0x0, 5), // addi x5, x4, 1  -> 5
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {
        Register.x1: 1,
        Register.x2: 2,
        Register.x3: 3,
        Register.x4: 4,
        Register.x5: 5,
      },
      oooSpecConfig(),
      nextPc: 0x34,
    ),
  );

  // CSR execution in OoO: write a CSR then read it back through mscratch.
  // Exercises the CsrUnit completion -> ROB port 2 + the serialisation barrier.
  test(
    'OoO executes csrrw/csrrs round-trip through mscratch',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x42, 0, 0x0, 1), // addi x1, x0, 0x42
        csr(0x340, 1, 0x1, 0), // csrrw x0, mscratch, x1  -> mscratch = 0x42
        csr(0x340, 0, 0x2, 3), // csrrs x3, mscratch, x0  -> x3 = mscratch
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x1: 0x42, Register.x3: 0x42},
      oooSpecConfig(),
      nextPc: 0x2C,
    ),
  );

  // Speculative + JAL: an unconditional jump must redirect past the skipped
  // instruction AND write the link register (rd = pc + 4).
  test(
    'speculative JAL redirects and writes the link register',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1), // 0x00 addi x1, x0, 5
        jal(8, 3), // 0x04 jal x3, +8 -> link x3=0x08, jump 0x0C
        iimm(99, 0, 0x0, 4), // 0x08 addi x4, x0, 99  (SKIPPED)
        iimm(7, 0, 0x0, 2), // 0x0C addi x2, x0, 7   (JAL target)
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {
        Register.x1: 5,
        Register.x2: 7,
        Register.x3: 0x08, // link = pc(0x04) + 4
        Register.x4: 0, // skipped by the jump
      },
      oooSpecConfig(),
      nextPc: 0x30,
    ),
  );

  // Speculative + JALR: indirect jump to a register-computed target, with link.
  test(
    'speculative JALR jumps to a computed target and writes link',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x0C, 0, 0x0, 1), // 0x00 addi x1, x0, 0x0C  (target addr)
        jalr(0, 1, 3), // 0x04 jalr x3, x1, 0 -> link x3=0x08, jump x1=0x0C
        iimm(99, 0, 0x0, 4), // 0x08 addi x4, x0, 99  (SKIPPED)
        iimm(7, 0, 0x0, 2), // 0x0C addi x2, x0, 7   (JALR target)
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {
        Register.x1: 0x0C,
        Register.x2: 7,
        Register.x3: 0x08, // link = pc(0x04) + 4
        Register.x4: 0, // skipped by the jump
      },
      oooSpecConfig(),
      nextPc: 0x30,
    ),
  );
}
