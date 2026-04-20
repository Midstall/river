import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:test/test.dart';
import '../core_harness.dart';
import '../constants.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  cpuTests('RV32I', condition: (c) => c.mxlen == RiscVMxlen.rv32, (config) {
    test(
      'Small program',
      timeout: Timeout(Duration(seconds: 30)),
      () => coreTest(
        '''@${config.resetVector.toRadixString(16)}
93 00 80 3E 13 81 00 7D 93 01 81 C1 13 82 01 83
93 02 82 3E 13 00 00 00
''',
        {
          Register.x1: 0x3E8,
          Register.x2: 0xBB8,
          Register.x3: 0x7D0,
          Register.x4: 0,
          Register.x5: 0x3E8,
        },
        config,
        nextPc: 0x18,
      ),
    );
    test(
      'lw loads from memory',
      timeout: Timeout(Duration(seconds: 30)),
      () => coreTest(
        // addi x10, x0, 0x100  (base addr)
        // lw x5, 0(x10)        (load word from 0x100)
        // nop
        '''@${config.resetVector.toRadixString(16)}
13 05 00 10 83 22 05 00 13 00 00 00
@100
ef be ad de
''',
        {Register.x5: 0xDEADBEEF, Register.x10: 0x100},
        config,
        nextPc: 0x0C,
      ),
    );

    test(
      'sw stores to memory',
      timeout: Timeout(Duration(seconds: 30)),
      () => coreTest(
        // addi x10, x0, 0x200  (base addr)
        // addi x5, x0, 42      (value)
        // sw x5, 0(x10)        (store word)
        // nop
        '''@${config.resetVector.toRadixString(16)}
13 05 00 20 93 02 a0 02 23 20 55 00 13 00 00 00
''',
        {Register.x10: 0x200, Register.x5: 42},
        config,
        nextPc: 0x10,
        memStates: {0x200: 42},
      ),
    );

    // Variable-latency robustness: the in-order pipeline's load handshake must
    // wait for memRead.done however many cycles the memory takes. The
    // emulator/fetcher tests cover fetch latency; these exercise the dport.
    // Multi-cycle memory (single-cycle SRAM through DRAM-ish latencies). Higher
    // latencies are correct too but make the full-core sim too slow to be worth
    // running here; fetcher_test covers the high-latency extreme on the fetch
    // port directly.
    const memLatencies = <int>[1, 4, 12];
    for (final lat in memLatencies) {
      test(
        'lw with memLatency=$lat',
        timeout: Timeout(Duration(seconds: lat ~/ 10 + 30)),
        () => coreTest(
          '''@${config.resetVector.toRadixString(16)}
13 05 00 10 83 22 05 00 13 00 00 00
@100
ef be ad de
''',
          {Register.x5: 0xDEADBEEF, Register.x10: 0x100},
          config,
          nextPc: 0x0C,
          memLatency: lat,
        ),
      );
      test(
        'sw with memLatency=$lat',
        timeout: Timeout(Duration(seconds: lat ~/ 10 + 30)),
        () => coreTest(
          '''@${config.resetVector.toRadixString(16)}
13 05 00 20 93 02 a0 02 23 20 55 00 13 00 00 00
''',
          {Register.x10: 0x200, Register.x5: 42},
          config,
          nextPc: 0x10,
          memStates: {0x200: 42},
          memLatency: lat,
        ),
      );
    }
  });
}
