import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river_hdl/src/core/rename.dart';
import 'package:test/test.dart';

/// Drives a [RegisterRenameTable] for speculative free-list rollback testing.
class _Harness {
  final Logic clk;
  final Logic reset = Logic(name: 'reset');
  final Logic rs1_0 = Logic(name: 'rs1_0', width: 5);
  final Logic rs2_0 = Logic(name: 'rs2_0', width: 5);
  final Logic rd_0 = Logic(name: 'rd_0', width: 5);
  final Logic valid0 = Logic(name: 'valid0');
  final Logic writesRd0 = Logic(name: 'writesRd0');
  final Logic rs1_1 = Logic(name: 'rs1_1', width: 5);
  final Logic rs2_1 = Logic(name: 'rs2_1', width: 5);
  final Logic rd_1 = Logic(name: 'rd_1', width: 5);
  final Logic valid1 = Logic(name: 'valid1');
  final Logic writesRd1 = Logic(name: 'writesRd1');
  final Logic freeValid0 = Logic(name: 'freeValid0');
  final Logic freeReg0 = Logic(name: 'freeReg0', width: 7);
  final Logic freeValid1 = Logic(name: 'freeValid1');
  final Logic freeReg1 = Logic(name: 'freeReg1', width: 7);
  final Logic commitValid0 = Logic(name: 'commitValid0');
  final Logic commitRd0 = Logic(name: 'commitRd0', width: 5);
  final Logic commitPdst0 = Logic(name: 'commitPdst0', width: 7);
  final Logic commitValid1 = Logic(name: 'commitValid1');
  final Logic commitRd1 = Logic(name: 'commitRd1', width: 5);
  final Logic commitPdst1 = Logic(name: 'commitPdst1', width: 7);
  final Logic flush = Logic(name: 'flush');
  late final RegisterRenameTable rt;

  _Harness(this.clk) {
    rt = RegisterRenameTable(
      clk,
      reset,
      rs1Arch0: rs1_0,
      rs2Arch0: rs2_0,
      rdArch0: rd_0,
      valid0: valid0,
      writesRd0: writesRd0,
      rs1Arch1: rs1_1,
      rs2Arch1: rs2_1,
      rdArch1: rd_1,
      valid1: valid1,
      writesRd1: writesRd1,
      freeValid0: freeValid0,
      freeReg0: freeReg0,
      freeValid1: freeValid1,
      freeReg1: freeReg1,
      commitValid0: commitValid0,
      commitRd0: commitRd0,
      commitPdst0: commitPdst0,
      commitValid1: commitValid1,
      commitRd1: commitRd1,
      commitPdst1: commitPdst1,
      flush: flush,
      numPhysRegs: 96,
    );
  }

  void idle() {
    valid0.inject(0);
    writesRd0.inject(0);
    valid1.inject(0);
    writesRd1.inject(0);
    freeValid0.inject(0);
    freeValid1.inject(0);
    commitValid0.inject(0);
    commitValid1.inject(0);
    flush.inject(0);
    for (final l in [
      rs1_0,
      rs2_0,
      rd_0,
      rs1_1,
      rs2_1,
      rd_1,
      commitRd0,
      commitRd1,
    ]) {
      l.inject(0);
    }
    freeReg0.inject(0);
    freeReg1.inject(0);
    commitPdst0.inject(0);
    commitPdst1.inject(0);
  }

  /// Rename a single reg-writing instruction with destination [rd].
  void renameRd(int rd) {
    valid0.inject(1);
    writesRd0.inject(1);
    rd_0.inject(rd);
    rs1_0.inject(1);
    rs2_0.inject(2);
    valid1.inject(0);
    writesRd1.inject(0);
  }

  /// Commit a single reg-writing instruction (frees [oldPdst], maps [rd]->[pdst]).
  void commitRd(int rd, int pdst, int oldPdst) {
    commitValid0.inject(1);
    commitRd0.inject(rd);
    commitPdst0.inject(pdst);
    freeValid0.inject(1);
    freeReg0.inject(oldPdst);
  }
}

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  Future<_Harness> setup() async {
    final clk = SimpleClockGenerator(10).clk;
    final h = _Harness(clk);
    h.idle();
    h.reset.inject(1);
    await h.rt.build();
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    h.reset.inject(0);
    await clk.nextPosedge;
    return h;
  }

  test('flush with no commits reclaims all speculative allocations', () async {
    final h = await setup();
    final clk = h.clk;
    // pdst0 is combinational from freeHead; first free phys reg is 32.
    h.renameRd(5);
    await clk.nextNegedge;
    expect(h.rt.pdst0.value.toInt(), 32, reason: 'first alloc');
    await clk.nextPosedge; // consume 32 for x5
    h.renameRd(6);
    await clk.nextNegedge;
    expect(h.rt.pdst0.value.toInt(), 33, reason: 'second alloc');
    await clk.nextPosedge; // consume 33 for x6
    // Flush (no commits): both speculative allocations must be reclaimed.
    h.idle();
    h.flush.inject(1);
    await clk.nextPosedge;
    h.idle();
    h.renameRd(7);
    await clk.nextNegedge;
    expect(
      h.rt.pdst0.value.toInt(),
      32,
      reason: 'flush reclaimed 32 and 33; next alloc reuses 32',
    );
  });

  test(
    'flush after a commit keeps committed alloc, reclaims younger',
    () async {
      final h = await setup();
      final clk = h.clk;
      h.renameRd(5); // x5 -> 32
      await clk.nextNegedge;
      expect(h.rt.pdst0.value.toInt(), 32);
      await clk.nextPosedge;
      // Commit x5 (its alloc 32 becomes permanent), while renaming x6 -> 33.
      h.idle();
      h.commitRd(5, 32, 5); // old mapping of x5 was phys 5
      h.renameRd(6);
      await clk.nextNegedge;
      expect(h.rt.pdst0.value.toInt(), 33);
      await clk.nextPosedge;
      // Flush: x5's 32 stays committed; x6's 33 is reclaimed.
      h.idle();
      h.flush.inject(1);
      await clk.nextPosedge;
      h.idle();
      h.renameRd(7);
      await clk.nextNegedge;
      expect(
        h.rt.pdst0.value.toInt(),
        33,
        reason: 'next alloc reuses reclaimed 33, not 34',
      );
    },
  );
}
