import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Drives [RiscVCsrFile] directly to check the Smstateen SE0 access gate: when
/// mstateen0.SE0 (bit 63) is clear, an sstateen0 access from below M is illegal
/// (csrRead.valid drops, which the pipeline turns into a trap); when set, it is
/// allowed and reads 0. Mirrors the emulator's stateen_test.
void main() {
  const mstateen0 = 0x30C;
  const sstateen0 = 0x10C;
  final se0 = BigInt.one << 63;

  test('mstateen0.SE0 gates S-mode sstateen0 (and WARL)', () async {
    await Simulator.reset();
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final mode = Logic(name: 'mode', width: 3);
    final csrRead = DataPortInterface(64, 12);
    final csrWrite = DataPortInterface(64, 12);

    final csrs = RiscVCsrFile(
      clk,
      reset,
      mode,
      mxlen: RiscVMxlen.rv64,
      misa: RiscVMxlen.rv64.misa,
      hasSupervisor: true,
      hasStateen: true,
      csrRead: csrRead,
      csrWrite: csrWrite,
    );
    await csrs.build();

    csrRead.en.inject(0);
    csrRead.addr.inject(0);
    csrWrite.en.inject(0);
    csrWrite.addr.inject(0);
    csrWrite.data.inject(0);
    mode.inject(3); // machine
    reset.inject(1);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    // Frontdoor write a CSR from M-mode (mstateen0 is an M CSR).
    Future<void> writeM(int addr, BigInt data) async {
      mode.inject(3);
      csrWrite.addr.inject(addr);
      csrWrite.data.inject(LogicValue.ofBigInt(data, 64));
      csrWrite.en.inject(1);
      await clk.nextPosedge;
      csrWrite.en.inject(0);
      await clk.nextPosedge;
    }

    // Drive a read in [m] mode and return (valid, data).
    Future<(int, BigInt)> read(int modeId, int addr) async {
      mode.inject(modeId);
      csrRead.addr.inject(addr);
      csrRead.en.inject(1);
      await clk.nextPosedge;
      final v = csrRead.valid.value.toInt();
      final d = csrRead.data.value.toBigInt();
      csrRead.en.inject(0);
      return (v, d);
    }

    // SE0 set -> S-mode sstateen0 access allowed, reads 0.
    await writeM(mstateen0, se0);
    final (vAllowed, dAllowed) = await read(1, sstateen0);
    expect(vAllowed, 1, reason: 'SE0 set -> sstateen0 access legal');
    expect(dAllowed, BigInt.zero, reason: 'sstateen0 reads 0');

    // SE0 clear -> S-mode sstateen0 access denied (illegal -> valid drops).
    await writeM(mstateen0, BigInt.zero);
    final (vDenied, _) = await read(1, sstateen0);
    expect(vDenied, 0, reason: 'SE0 clear -> sstateen0 access illegal');

    // M-mode is never gated, even with SE0 clear.
    final (vM, _) = await read(3, sstateen0);
    expect(vM, 1, reason: 'M-mode sstateen0 access is always legal');

    // WARL: only SE0 (bit 63) sticks.
    await writeM(mstateen0, (BigInt.one << 64) - BigInt.one); // all ones
    final (vWarl, dWarl) = await read(3, mstateen0);
    expect(vWarl, 1);
    expect(dWarl, se0, reason: 'only SE0 writable; other bits WARL-0');

    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  });
}
