import 'dart:async';

import 'package:test/test.dart';
import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';

Future<void> testMultiDataPortWriter(
  int size,
  int addr,
  int value, {
  bool useDword = false,
  int initialValue = 0,
}) async {
  final clk = SimpleClockGenerator(5).clk;
  final reset = Logic();

  final backingSize = useDword ? 64 : 32;

  final backingWriteByte = DataPortInterface(8, backingSize);
  final backingWriteHalf = DataPortInterface(16, backingSize);
  final backingWriteWord = DataPortInterface(32, backingSize);
  final backingWriteDword = DataPortInterface(64, backingSize);

  final source = DataPortInterface(backingSize + 7, backingSize);

  final writer = SizedWriteMultiDataPort(
    clk,
    reset,
    backingWriteByte: backingWriteByte,
    backingWriteHalf: backingWriteHalf,
    backingWriteWord: backingWriteWord,
    backingWriteDword: useDword ? backingWriteDword : null,
    source: source,
  );

  final backingWrite = switch (size) {
    8 => backingWriteByte,
    16 => backingWriteHalf,
    32 => backingWriteWord,
    64 => backingWriteDword,
    _ => throw 'Incompatible size $size',
  };

  await writer.build();

  unawaited(Simulator.run());

  reset.inject(0);
  source.en.inject(0);

  await clk.nextPosedge;
  reset.put(0);

  await clk.nextPosedge;

  source.en.put(1);
  source.addr.put(addr);
  source.data.put((size & 0xFF) | (value << 7));

  await clk.nextPosedge;

  final mask = (1 << size) - 1;
  final expectedValue = (initialValue & ~mask) | (value & mask);

  expect(backingWrite.en.value.toBool(), isTrue);
  expect(backingWrite.addr.value.toInt(), addr);
  expect(backingWrite.data.value.toInt(), expectedValue);

  backingWrite.done.put(1);
  backingWrite.valid.put(1);

  await clk.nextPosedge;

  await Simulator.endSimulation();

  expect(source.done.value.toBool(), isTrue);
  expect(source.valid.value.toBool(), isTrue);
}

Future<void> testSingleDataPortWriter(
  int size,
  int addr,
  int value, {
  int? backingSize,
  int initialValue = 0,
}) async {
  final clk = SimpleClockGenerator(5).clk;
  final reset = Logic();

  backingSize ??= size;

  final backingRead = DataPortInterface(backingSize, backingSize);
  final backingWrite = DataPortInterface(backingSize, backingSize);
  final source = DataPortInterface(backingSize + 7, backingSize);

  final writer = SizedWriteSingleDataPort(
    clk,
    reset,
    backingRead: backingRead,
    backingWrite: backingWrite,
    source: source,
  );

  await writer.build();

  unawaited(Simulator.run());

  reset.inject(0);
  source.en.inject(0);

  await clk.nextPosedge;
  reset.put(0);

  await clk.nextPosedge;

  source.en.put(1);
  source.addr.put(addr);
  source.data.put((size & 0xFF) | (value << 7));

  await clk.nextPosedge;

  expect(backingRead.en.value.toBool(), isTrue);
  expect(backingRead.addr.value.toInt(), addr);

  backingRead.data.put(initialValue);
  backingRead.done.put(1);
  backingRead.valid.put(1);

  await clk.nextPosedge;

  final mask = (1 << size) - 1;
  final expectedValue = (initialValue & ~mask) | (value & mask);

  expect(backingWrite.en.value.toBool(), isTrue);
  expect(backingWrite.addr.value.toInt(), addr);
  expect(backingWrite.data.value.toInt(), expectedValue);

  backingWrite.done.put(1);
  backingWrite.valid.put(1);

  await clk.nextPosedge;

  await Simulator.endSimulation();

  expect(source.done.value.toBool(), isTrue);
  expect(source.valid.value.toBool(), isTrue);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Multi Data Port Writer', () {
    test('8-bits -> 32-bits', () => testMultiDataPortWriter(8, 0, 0xA0));
    test('16-bits -> 32-bits', () => testMultiDataPortWriter(16, 0, 0xA0));
    test('32-bits -> 32-bits', () => testMultiDataPortWriter(32, 0, 0xA0));

    test(
      '8-bits -> 64-bits',
      () => testMultiDataPortWriter(8, 0, 0xA0, useDword: true),
    );
    test(
      '16-bits -> 64-bits',
      () => testMultiDataPortWriter(16, 0, 0xA0, useDword: true),
    );
    test(
      '32-bits -> 64-bits',
      () => testMultiDataPortWriter(32, 0, 0xA0, useDword: true),
    );
    test(
      '64-bits -> 64-bits',
      () => testMultiDataPortWriter(64, 0, 0xA0, useDword: true),
    );

    test(
      '8-bits -> 32-bits with initial',
      () => testMultiDataPortWriter(8, 0, 0xA0, initialValue: 0xFF),
    );
    test(
      '16-bits -> 32-bits with initial',
      () => testMultiDataPortWriter(16, 0, 0xA0, initialValue: 0xFF00),
    );
    test(
      '32-bits -> 32-bits with initial',
      () => testMultiDataPortWriter(32, 0, 0xA0, initialValue: 0xFFFFF00),
    );

    test(
      '8-bits -> 64-bits with initial',
      () => testMultiDataPortWriter(
        8,
        0,
        0xA0,
        useDword: true,
        initialValue: 0xFF,
      ),
    );
    test(
      '16-bits -> 64-bits with initial',
      () => testMultiDataPortWriter(
        16,
        0,
        0xA0,
        useDword: true,
        initialValue: 0xFF00,
      ),
    );
    test(
      '32-bits -> 64-bits with initial',
      () => testMultiDataPortWriter(
        32,
        0,
        0xA0,
        useDword: true,
        initialValue: 0xFFFFF00,
      ),
    );
    test(
      '64-bits -> 64-bits with initial',
      () => testMultiDataPortWriter(
        64,
        0,
        0xA0,
        useDword: true,
        initialValue: 0xFFFFFFF00,
      ),
    );
  });

  group('Single Data Port Writer', () {
    test('8-bits -> 8-bits', () => testSingleDataPortWriter(8, 0, 0xA0));
    test('8-bits -> 16-bits', () => testSingleDataPortWriter(16, 1, 0xA0));
    test('8-bits -> 32-bits', () => testSingleDataPortWriter(32, 2, 0xA0));
    test('8-bits -> 64-bits', () => testSingleDataPortWriter(64, 3, 0xA0));

    test(
      '8-bits -> 8-bits with initial',
      () => testSingleDataPortWriter(
        8,
        0,
        0xA0,
        initialValue: 0xFF,
        backingSize: 8,
      ),
    );
    test(
      '8-bits -> 16-bits with initial',
      () => testSingleDataPortWriter(
        8,
        1,
        0xA0,
        initialValue: 0xFF00,
        backingSize: 16,
      ),
    );
    test(
      '8-bits -> 32-bits with initial',
      () => testSingleDataPortWriter(
        8,
        2,
        0xA0,
        initialValue: 0xFFFFF00,
        backingSize: 32,
      ),
    );
    test(
      '8-bits -> 64-bits with initial',
      () => testSingleDataPortWriter(
        8,
        3,
        0xA0,
        initialValue: 0xFFFFFFF00,
        backingSize: 64,
      ),
    );
  });
}
