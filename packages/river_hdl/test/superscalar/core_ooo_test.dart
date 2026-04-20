import 'package:river/river.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../core_harness.dart';
import 'core_ooo_common.dart';

/// Out-of-order pipeline bring-up: basic single-issue, dual-commit, and the
/// memory functional unit. The speculative front-end tests live in
/// core_ooo_spec_test.dart (split so each file stays under the per-file timeout;
/// each test builds a fresh HDL core). See project_hdl_ooo_state in memory.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Single-issue OoO retires register-only programs correctly.
  test(
    'OoO runs RV32I small program',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      // addi x1,x0,0x3E8 ; addi x2,x2,0x7D0 ; addi x3,x2,-0x3E8 ;
      // addi x4,x3,0x18 ; addi x5,x5,0x3E8 ; nop
      '''@0
93 00 80 3E 13 81 00 7D 93 01 81 C1 13 82 01 83
93 02 82 3E 13 00 00 00
''',
      {
        Register.x1: 0x3E8,
        Register.x2: 0xBB8,
        Register.x3: 0x7D0,
        Register.x5: 0x3E8,
      },
      oooConfig(),
      nextPc: 0x18,
    ),
  );

  // Dual-commit (commitWidth=dual): a second register write port lets two ROB
  // entries retire in one cycle. A multi-cycle `mul` stalls at the ROB head
  // while the independent `addi`s behind it complete and queue; when the mul
  // finally retires, the queued ops retire alongside it through slot 1.
  test(
    'dual-commit retires a backlog behind a multi-cycle mul',
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
      oooDualConfig(),
      nextPc: 0x3C,
    ),
  );

  // Same backlog program with a depth-2 register-file write buffer
  // (writeBufferDepth=2): same-bank commit collisions are buffered instead of
  // stalling. The architectural result must be identical.
  test(
    'dual-commit with write buffer retires backlog behind a multi-cycle mul',
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
      oooDualBufConfig(),
      nextPc: 0x3C,
    ),
  );

  // OoO branch bring-up (lockstep): kept skipped to document that lockstep OoO
  // has no branch-redirect path (it advances the arch PC only at commit). Branch
  // support in OoO requires speculativeFetch=true (see core_ooo_spec_test.dart).
  test(
    'OoO taken branch redirects past the skipped instruction',
    timeout: Timeout(Duration(seconds: 60)),
    skip: 'lockstep OoO has no branch-redirect path; use speculativeFetch',
    () => coreTest(
      prog([
        iimm(5, 0, 0x0, 1), // addi x1, x0, 5
        iimm(5, 0, 0x0, 2), // addi x2, x0, 5
        b(8, 2, 1, 0x0), // beq x1, x2, +8  -> taken, target = 0x08+8 = 0x10
        iimm(99, 0, 0x0, 3), // addi x3, x0, 99  (SKIPPED, x3 stays 0)
        iimm(7, 0, 0x0, 4), // addi x4, x0, 7   (branch target @0x10)
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x1: 5, Register.x2: 5, Register.x3: 0, Register.x4: 7},
      oooConfig(),
      nextPc: 0x34,
    ),
  );

  // Zbb/Zba/Zbs ALU ops through the OoO datapath. A nop tail lets the ROB drain.
  test(
    'OoO runs bitmanip (max/minu/andn/rol/clz/cpop/sh1add)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(16, 0, 0x0, 1), // addi x1, x0, 16
        iimm(3, 0, 0x0, 2), // addi x2, x0, 3
        r(0x05, 2, 1, 0x6, 5), // max  x5, x1, x2 -> 16
        r(0x05, 2, 1, 0x5, 6), // minu x6, x1, x2 -> 3
        r(0x20, 2, 1, 0x7, 7), // andn x7, x1, x2 -> 16
        r(0x30, 2, 1, 0x1, 9), // rol  x9, x1, x2 -> 128
        iimm(0x600, 2, 0x1, 10), // clz  x10, x2  -> 30 (rv32)
        iimm(0x602, 1, 0x1, 11), // cpop x11, x1  -> 1
        r(0x10, 1, 2, 0x2, 8), // sh1add x8, x2, x1 -> 22
        ...List.filled(8, 0x00000013), // nop tail (halt target inside it)
      ]),
      {
        Register.x5: 16,
        Register.x6: 3,
        Register.x7: 16,
        Register.x9: 128,
        Register.x10: 30,
        Register.x11: 1,
        Register.x8: 22,
      },
      oooBConfig(),
      nextPc: 0x3C,
    ),
  );

  // Memory functional unit on the OoO datapath: store a value then load it back.
  // The separation nops between sw and lw are load-bearing (store visibility
  // takes several cycles through the MMU->Wishbone->memory path).
  test(
    'OoO runs sw + lw round-trip through memory (with store-visibility gap)',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100  (base addr)
        iimm(0x123, 0, 0x0, 5), // addi x5, x0, 0x123   (value)
        s(0, 5, 10, 0x2, 0x23), // sw x5, 0(x10)        mem[0x100]=0x123
        ...List.filled(4, 0x00000013), // separation nops (diagnose visibility)
        lw(0, 10, 6), // lw x6, 0(x10)        x6 = 0x123
        ...List.filled(8, 0x00000013), // nop tail
      ]),
      {Register.x10: 0x100, Register.x5: 0x123, Register.x6: 0x123},
      oooConfig(),
      nextPc: 0x3C,
      memStates: {0x100: 0x123},
    ),
  );

  // Isolate the load path: read from pre-initialized memory (no store dep).
  test(
    'OoO runs lw from preloaded memory',
    timeout: Timeout(Duration(seconds: 60)),
    () => coreTest(
      '${prog([
        iimm(0x100, 0, 0x0, 10), // addi x10, x0, 0x100
        lw(0, 10, 6), // lw x6, 0(x10)  -> 0xDEADBEEF
        ...List.filled(8, 0x00000013), // nop tail
      ])}@100\nef be ad de\n',
      {Register.x10: 0x100, Register.x6: 0xDEADBEEF},
      oooConfig(),
      nextPc: 0x24,
    ),
  );
}
