import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

Future<void> fetcherTest(
  int instr, {
  bool isCompressed = false,
  bool hasCompressed = false,
  int latency = 0,
}) async {
  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();
  final enable = Logic();

  final memRead = DataPortInterface(32, 32);

  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [],
    [wrapReadForRegisterFile(memRead, clk: clk, readLatency: latency)],
    readLatency: latency,
    storage: SparseMemoryStorage(
      addrWidth: 32,
      dataWidth: 32,
      alignAddress: (addr) => addr,
      onInvalidRead: (addr, dataWidth) =>
          LogicValue.ofInt(addr.toInt() == 0 ? instr : 0, dataWidth),
    ),
  );

  final fetcher = FetchUnit(
    clk,
    reset,
    enable,
    Const(0, width: 32),
    memRead,
    hasCompressed: hasCompressed,
  );

  await fetcher.build();

  Simulator.registerAction(15, () {
    reset.put(0);
    enable.put(1);
  });

  reset.inject(1);
  enable.inject(0);

  Simulator.setMaxSimTime(10000 + latency * 50);
  unawaited(Simulator.run());

  await clk.nextPosedge;

  while (reset.value.toBool()) {
    await clk.nextPosedge;
  }

  await clk.nextPosedge;

  while (true) {
    await clk.nextPosedge;
    final d = fetcher.done.value;
    if (d.isValid && d.toBool()) break;
  }

  final resultValue = fetcher.result.value;
  final doneValue = fetcher.done.value;
  final compressedValue = hasCompressed ? fetcher.compressed.value : null;

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  expect(doneValue.toBool(), isTrue);
  expect(resultValue.toInt(), instr);

  if (hasCompressed) {
    expect(compressedValue!.toBool(), isCompressed);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Fetch non-compressed', () {
    test('Simple', () => fetcherTest(0x00a08293));

    const latencies = <int>[12, 24, 36, 120, 240, 360, 1200];

    for (final latency in latencies) {
      test(
        'Latency $latency',
        () => fetcherTest(0x00a08293, latency: latency),
        timeout: Timeout(Duration(seconds: latency ~/ 10 + 30)),
      );
    }
  });

  group('Compressed', () {
    test(
      'Simple',
      () => fetcherTest(0x200, hasCompressed: true, isCompressed: true),
    );

    const latencies = <int>[12, 24, 36, 120, 240, 360, 1200];

    for (final latency in latencies) {
      test(
        'Latency $latency',
        () => fetcherTest(
          0x200,
          latency: latency,
          hasCompressed: true,
          isCompressed: true,
        ),
        timeout: Timeout(Duration(seconds: latency ~/ 10 + 30)),
      );
    }
  });
}
