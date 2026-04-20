import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// External net feeding module input [name].
Logic _pin(HarborRegisterFile r, String name) => r.input(name).srcConnection!;

void _inj(HarborRegisterFile r, String name, int v) => _pin(r, name).inject(v);

String _en(int w, int n) => n == 1 ? 'wr_en' : 'wr${w}_en';
String _addr(int w, int n) => n == 1 ? 'wr_addr' : 'wr${w}_addr';
String _data(int w, int n) => n == 1 ? 'wr_data' : 'wr${w}_data';
String _ready(int w, int n) => n == 1 ? 'wr_ready' : 'wr${w}_ready';

int _get(HarborRegisterFile regs, int reg) =>
    regs.getData(LogicValue.ofInt(reg, 5))!.toInt();

/// Build a register file (flop/sim backend, target=null), drive its clock and
/// reset, settle out of reset, and return it ready for poking.
Future<HarborRegisterFile> _mk({
  int numReadPorts = 2,
  int numWritePorts = 1,
  int numBanks = 1,
  int writeBufferDepth = 0,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final regs = HarborRegisterFile(
    numEntries: 32,
    dataWidth: 32,
    numReadPorts: numReadPorts,
    numWritePorts: numWritePorts,
    numBanks: numBanks,
    writeBufferDepth: writeBufferDepth,
  );
  _pin(regs, 'clk') <= clk;
  // Default every input so nothing floats to X.
  _inj(regs, 'reset', 1);
  for (var w = 0; w < numWritePorts; w++) {
    _inj(regs, _en(w, numWritePorts), 0);
    _inj(regs, _addr(w, numWritePorts), 0);
    _inj(regs, _data(w, numWritePorts), 0);
  }
  for (var r = 0; r < numReadPorts; r++) {
    _inj(regs, 'rd${r}_addr', 0);
  }
  await regs.build();
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  _inj(regs, 'reset', 0);
  await clk.nextPosedge;
  return regs;
}

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('default 2R/1W: write then read back (back-compat)', () async {
    final regs = await _mk();
    final clk = _pin(regs, 'clk');
    _inj(regs, 'wr_en', 1);
    _inj(regs, 'wr_addr', 5);
    _inj(regs, 'wr_data', 0xABCD);
    await clk.nextNegedge;
    expect(regs.output('wr_ready').value.toInt(), 1, reason: 'always ready');
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(_get(regs, 5), 0xABCD);
    _inj(regs, 'wr_en', 0);
    _inj(regs, 'rd0_addr', 5);
    await clk.nextNegedge;
    expect(regs.rd0Data.value.toInt(), 0xABCD);
  });

  test('2W/2banks: writes to different banks both commit same cycle', () async {
    final regs = await _mk(numWritePorts: 2, numBanks: 2);
    final clk = _pin(regs, 'clk');
    // reg 2 -> bank 0, reg 3 -> bank 1 (bank = low bit).
    _inj(regs, _en(0, 2), 1);
    _inj(regs, _addr(0, 2), 2);
    _inj(regs, _data(0, 2), 0x11);
    _inj(regs, _en(1, 2), 1);
    _inj(regs, _addr(1, 2), 3);
    _inj(regs, _data(1, 2), 0x22);
    await clk.nextNegedge;
    expect(regs.output(_ready(0, 2)).value.toInt(), 1);
    expect(regs.output(_ready(1, 2)).value.toInt(), 1);
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(_get(regs, 2), 0x11);
    expect(_get(regs, 3), 0x22);
  });

  test(
    '2W/1bank conflict (distinct addrs): older wins, younger stalls',
    () async {
      final regs = await _mk(numWritePorts: 2, numBanks: 1);
      final clk = _pin(regs, 'clk');
      _inj(regs, _en(0, 2), 1);
      _inj(regs, _addr(0, 2), 2);
      _inj(regs, _data(0, 2), 0x11);
      _inj(regs, _en(1, 2), 1);
      _inj(regs, _addr(1, 2), 4);
      _inj(regs, _data(1, 2), 0x22);
      await clk.nextNegedge;
      expect(
        regs.output(_ready(0, 2)).value.toInt(),
        1,
        reason: 'older accepted',
      );
      expect(
        regs.output(_ready(1, 2)).value.toInt(),
        0,
        reason: 'younger stalled',
      );
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(_get(regs, 2), 0x11);
      expect(_get(regs, 4), 0, reason: 'younger not yet written');
      // Retry younger alone next cycle.
      _inj(regs, _en(0, 2), 0);
      await clk.nextNegedge;
      expect(regs.output(_ready(1, 2)).value.toInt(), 1);
      await clk.nextPosedge;
      await clk.nextNegedge;
      expect(_get(regs, 4), 0x22);
    },
  );

  test('2W same address WAW: younger value wins, both ready', () async {
    final regs = await _mk(numWritePorts: 2, numBanks: 1);
    final clk = _pin(regs, 'clk');
    _inj(regs, _en(0, 2), 1);
    _inj(regs, _addr(0, 2), 6);
    _inj(regs, _data(0, 2), 0x11);
    _inj(regs, _en(1, 2), 1);
    _inj(regs, _addr(1, 2), 6);
    _inj(regs, _data(1, 2), 0x22);
    await clk.nextNegedge;
    expect(regs.output(_ready(0, 2)).value.toInt(), 1);
    expect(regs.output(_ready(1, 2)).value.toInt(), 1);
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(_get(regs, 6), 0x22, reason: 'younger (slot 1) wins');
  });

  test(
    'depth=1 buffer: same-bank conflict buffers younger (no stall)',
    () async {
      final regs = await _mk(
        numWritePorts: 2,
        numBanks: 1,
        writeBufferDepth: 1,
      );
      final clk = _pin(regs, 'clk');
      _inj(regs, _en(0, 2), 1);
      _inj(regs, _addr(0, 2), 2);
      _inj(regs, _data(0, 2), 0x11);
      _inj(regs, _en(1, 2), 1);
      _inj(regs, _addr(1, 2), 4);
      _inj(regs, _data(1, 2), 0x22);
      await clk.nextNegedge;
      expect(regs.output(_ready(0, 2)).value.toInt(), 1);
      expect(
        regs.output(_ready(1, 2)).value.toInt(),
        1,
        reason: 'younger buffered, not stalled',
      );
      await clk.nextPosedge; // x2 written direct; x4 enqueued
      await clk.nextNegedge;
      expect(_get(regs, 2), 0x11);
      expect(_get(regs, 4), 0, reason: 'x4 still buffered, not drained yet');
      // Read bypass: x4 must be visible from the buffer before it drains.
      _inj(regs, _en(0, 2), 0);
      _inj(regs, _en(1, 2), 0);
      _inj(regs, 'rd0_addr', 4);
      await clk.nextNegedge;
      expect(
        regs.rd0Data.value.toInt(),
        0x22,
        reason: 'bypass from write buffer',
      );
      await clk.nextPosedge; // buffer drains x4 -> storage
      await clk.nextNegedge;
      expect(_get(regs, 4), 0x22, reason: 'drained to storage');
    },
  );

  test(
    'depth=1 buffer overflow: second conflict stalls when buffer full',
    () async {
      final regs = await _mk(
        numWritePorts: 2,
        numBanks: 1,
        writeBufferDepth: 1,
      );
      final clk = _pin(regs, 'clk');
      // Cycle T: x2 direct, x4 buffered.
      _inj(regs, _en(0, 2), 1);
      _inj(regs, _addr(0, 2), 2);
      _inj(regs, _data(0, 2), 0x11);
      _inj(regs, _en(1, 2), 1);
      _inj(regs, _addr(1, 2), 4);
      _inj(regs, _data(1, 2), 0x22);
      await clk.nextPosedge;
      // Cycle T+1: buffer holds x4 (drains this cycle), and two NEW writes
      // arrive. x6 buffers (slot freed by drain); x8 overflows depth-1 buffer.
      _inj(regs, _addr(0, 2), 6);
      _inj(regs, _data(0, 2), 0x33);
      _inj(regs, _addr(1, 2), 8);
      _inj(regs, _data(1, 2), 0x44);
      await clk.nextNegedge;
      expect(regs.output(_ready(0, 2)).value.toInt(), 1, reason: 'x6 buffered');
      expect(
        regs.output(_ready(1, 2)).value.toInt(),
        0,
        reason: 'x8 stalls: buffer full',
      );
    },
  );

  test('depth=2 buffer: two conflicts buffer and both drain', () async {
    final regs = await _mk(numWritePorts: 2, numBanks: 1, writeBufferDepth: 2);
    final clk = _pin(regs, 'clk');
    // T: x2 direct, x4 -> buffer[0].
    _inj(regs, _en(0, 2), 1);
    _inj(regs, _addr(0, 2), 2);
    _inj(regs, _data(0, 2), 0x11);
    _inj(regs, _en(1, 2), 1);
    _inj(regs, _addr(1, 2), 4);
    _inj(regs, _data(1, 2), 0x22);
    await clk.nextPosedge;
    // T+1: buffer drains x4; x6 and x8 both buffer (depth 2 holds both).
    _inj(regs, _addr(0, 2), 6);
    _inj(regs, _data(0, 2), 0x33);
    _inj(regs, _addr(1, 2), 8);
    _inj(regs, _data(1, 2), 0x44);
    await clk.nextNegedge;
    expect(regs.output(_ready(0, 2)).value.toInt(), 1);
    expect(
      regs.output(_ready(1, 2)).value.toInt(),
      1,
      reason: 'depth-2 holds both',
    );
    await clk
        .nextPosedge; // latch: drain x4, enqueue x6 & x8 (inputs still driven)
    _inj(regs, _en(0, 2), 0);
    _inj(regs, _en(1, 2), 0);
    // Drain the buffer over the next few cycles.
    for (var i = 0; i < 3; i++) {
      await clk.nextPosedge;
    }
    await clk.nextNegedge;
    expect(_get(regs, 2), 0x11);
    expect(_get(regs, 4), 0x22);
    expect(_get(regs, 6), 0x33);
    expect(_get(regs, 8), 0x44);
  });
}
