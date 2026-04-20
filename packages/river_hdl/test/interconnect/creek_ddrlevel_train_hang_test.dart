// Reproduces (or refutes) the OrangeCrab DDR train-control read HANG in a FULL
// creek SoC ROHD simulation, with full wishbone-bus visibility.
//
// On hardware the creek `ddrlevel` firmware prints its UART self-test
// `12345678` then HANGS on the FIRST train-control STATUS read (`lw` at
// 0x88000018). The controller-only sim (ddr_train_soc_test.dart) acks a
// hand-built `lui` program fine, but that test reproduces a hang only with a
// DELIBERATELY naive `lui` that sign-extends bit 31. The real firmware does NOT
// use raw `lui`: RiverDdrLevel builds the STATUS address with `li(regStatus)`,
// and `li` (river_adl instruction_set.dart) already zero-extends bit-31
// addresses on RV64. So the open question this test answers definitively is:
// does the ACTUAL ddrlevel firmware, in the SAME full SoC the hardware uses,
// reproduce the hang?
//
// This test boots the FULL creek SoC (rc1-s core + SRAM + flash + clint + plic
// + ns16550a UART + the OrangeCrab DDR3 controller WITH the train-control
// window, all on the wishbone fabric) with `--boot-program ddrlevel`, a
// passthrough clock and an external reset (no PLL/target). It taps the core's
// data-bus master and logs the FIRST access into the train-control window
// [0x88000000, 0x88001000): the exact ADR presented (sign-extended or not),
// whether CYC&STB assert, and whether any slave ACKs. That single logged line
// is the smoking gun that resolves the contradiction.
import 'dart:async';

import 'package:river/river.dart' show HarborClockConfig, HarborFixedClockRate;
import 'package:river_maskrom/river_maskrom.dart' show RiverDdrLevel;
import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // FAST, default-suite guard (no sim): the firmware must build the train-
  // control STATUS address 0x88000018 as a ZERO-extended positive RV64 value,
  // not a sign-extended `lui`. This is the load-bearing fact that resolves the
  // hardware-hang contradiction without paying for the multi-minute full-SoC
  // sim below: `li(0x88000018)` already applies the slli32/srli32 zero-extend
  // (river_adl instruction_set.dart), so the bus sees 0x0000000088000018 (which
  // the DDR slave's [base, base+size+trainCtrlSize) decode routes and ctrlAcks),
  // NOT 0xFFFFFFFF88000018 (which no slave decodes -> the only sign-ext hang).
  test(
    'ddrlevel materializes the 0x88000018 STATUS address zero-extended '
    '(not a sign-extended lui) - the train-control hang precondition',
    () async {
      final coreClock = HarborClockConfig(
        name: 'sysclk',
        rate: HarborFixedClockRate(1152000),
      );
      // rc1-s is the creek core; reuse genip's exact ISA build for it.
      final config = RiverGenIpConfig(
        name: 'creek_v1',
        cores: const ['rc1-s'],
        clockFrequency: 1152000,
        oscFrequency: 1152000,
        devices: [
          Device.parse('dram:0x80000000:128M:orangecrab'),
          Device.parse('uart:0x10000000:ns16550a'),
        ],
      );
      final coreConfig = config.buildCoreConfig(coreClock, 'rc1-s', hartId: 0);

      final fw = RiverDdrLevel(
        isa: coreConfig.isa,
        uartBase: 0x10000000,
        dramBase: 0x80000000,
        trainCtrlBase: 0x88000000, // dramBase + 128M
        clockHz: 1152000,
      );
      await fw.build();
      final bin = fw.generateBinary();
      final words = <int>[];
      for (var i = 0; i + 3 < bin.length; i += 4) {
        words.add(
          bin[i] | (bin[i + 1] << 8) | (bin[i + 2] << 16) | (bin[i + 3] << 24),
        );
      }

      // Find the `li(0x88000018)` -> `lw` sequence: a `LUI rd, 0x88000` whose
      // i+1=ADDI(+24), i+2=SLLI 32, i+3=SRLI 32 (the zero-extension), i+4=LOAD.
      // The presence of the SLLI32/SRLI32 pair proves the address is corrected.
      var foundStatusLoad = false;
      for (var i = 0; i + 4 < words.length; i++) {
        final lui = words[i];
        if ((lui & 0x7f) != 0x37) continue; // LUI
        if (((lui >> 12) & 0xfffff) != 0x88000) continue; // imm 0x88000
        final addi = words[i + 1];
        final slli = words[i + 2];
        final srli = words[i + 3];
        final load = words[i + 4];
        final isAddi24 =
            (addi & 0x7f) == 0x13 &&
            ((addi >> 12) & 0x7) == 0 &&
            ((addi >> 20) & 0xfff) == 24;
        final isSlli32 =
            (slli & 0x7f) == 0x13 &&
            ((slli >> 12) & 0x7) == 1 &&
            ((slli >> 20) & 0x3f) == 32;
        final isSrli32 =
            (srli & 0x7f) == 0x13 &&
            ((srli >> 12) & 0x7) == 5 &&
            ((srli >> 20) & 0x3f) == 32;
        final isLoad = (load & 0x7f) == 0x03; // LW/LD
        if (isAddi24 && isSlli32 && isSrli32 && isLoad) {
          foundStatusLoad = true;
          break;
        }
      }

      // There must be NO bare `lui` of the STATUS address feeding a load directly
      // without the zero-extension (that would be the sign-extension hang).
      var foundNakedSignExt = false;
      for (var i = 0; i + 1 < words.length; i++) {
        final lui = words[i];
        if ((lui & 0x7f) != 0x37) continue;
        if (((lui >> 12) & 0xfffff) != 0x88000) continue;
        final rd = (lui >> 7) & 0x1f;
        final addi = words[i + 1];
        final next2 = i + 2 < words.length ? words[i + 2] : 0;
        // lui rd,0x88000 ; addi rd,rd,24 ; <load rd>  (no slli/srli between)
        final isAddi24Same =
            (addi & 0x7f) == 0x13 &&
            ((addi >> 7) & 0x1f) == rd &&
            ((addi >> 15) & 0x1f) == rd &&
            ((addi >> 20) & 0xfff) == 24;
        final next2IsLoadOfRd =
            (next2 & 0x7f) == 0x03 && ((next2 >> 15) & 0x1f) == rd;
        if (isAddi24Same && next2IsLoadOfRd) foundNakedSignExt = true;
      }

      expect(
        foundStatusLoad,
        isTrue,
        reason:
            'ddrlevel must build 0x88000018 with the slli32/srli32 '
            'zero-extension before the STATUS lw (the lui sign-extension fix)',
      );
      expect(
        foundNakedSignExt,
        isFalse,
        reason:
            'ddrlevel must NOT load STATUS from a naked sign-extended lui '
            '(that is the only address-construction hang mechanism)',
      );
    },
  );

  // The hardware creek/orangecrab map (devices.nix base + orangecrab override),
  // collapsed to the single-clock passthrough form so the ROHD sim is tractable
  // (osc == core => no CDC; the DDR control window is served on the bus clock
  // regardless, so the control-read path under test is identical).
  //
  //   dram  0x80000000 : 128M : orangecrab  -> trainCtrlBase 0x88000000
  //   sram  0x08000000 : 32K
  //   flash 0x20000000 : 16M
  //   clint 0x02000000, plic 0x04000000, uart 0x10000000 ns16550a
  //
  // trainCtrlBase = dramBase + dramSize = 0x80000000 + 0x08000000 = 0x88000000,
  // STATUS (reg3) at 0x88000018 - the exact address the hardware hangs on, with
  // bit 31 set (the case that would expose an RV64 lui sign-extension trap).
  //
  // Small clock so the baked UART divisor (clockHz / 115200) is tiny and the
  // self-test streams in a few thousand sim cycles. The logic under test is
  // identical to the 48 MHz build; only the divisor immediate differs.
  const clockHz = 1152000; // divisor = 10
  const divisor = clockHz ~/ 115200;
  const trainCtrlLo = 0x88000000;
  const trainCtrlHi = 0x88001000;
  const statusAddr = 0x88000018;

  test(
    'creek ddrlevel: full-SoC wishbone visibility at the first train-control '
    'read (resolves the hardware hang contradiction)',
    // The microcode core is slow under the interpreted ROHD simulator. We only
    // need to reach the FIRST train-control access (right after the 12345678
    // self-test print), which is a few thousand cycles, not the full 640-combo
    // sweep. Budgeted accordingly; kept runnable but not in the default fast
    // suite (mirrors the sibling banner test's rationale).
    timeout: const Timeout(Duration(minutes: 20)),
    skip:
        'slow under interpreted ROHD sim; run explicitly to reproduce/refute '
        'the train-control hang (dart test '
        'test/interconnect/creek_ddrlevel_train_hang_test.dart)',
    () async {
      final config = RiverGenIpConfig(
        name: 'creek_v1',
        cores: const ['rc1-s'],
        clockFrequency: clockHz,
        oscFrequency: clockHz, // equal -> passthrough clock, single domain
        devices: [
          Device.parse('flash:0x20000000:16M'),
          Device.parse('sram:0x08000000:32K'),
          Device.parse('dram:0x80000000:128M:orangecrab'),
          Device.parse('clint:0x02000000'),
          Device.parse('plic:0x04000000'),
          Device.parse('uart:0x10000000:ns16550a'),
        ],
        pins: [
          PinAssignment.parse('uart_tx=uart@tx:N17'),
          PinAssignment.parse('uart_rx=uart@rx:M18'),
        ],
        bootProgram: 'ddrlevel',
      );

      final soc = await config.buildSoC();

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');

      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      soc.input('uart_rx').srcConnection! <= Const(1);

      await soc.build();

      final tx = soc.output('uart_tx');

      // Tap the core's data-bus wishbone master. Inside a built SoC these ports
      // are already connected to the WishboneDecoder, so we OBSERVE them (the
      // fabric drives ACK back into the core). These are exactly the signals the
      // hardware decoder sees, so an ADR/ACK mismatch here is the hardware bug.
      final core = soc.masters.first as RiverCore;
      final adr = core.output('dataBus_ADR');
      final cyc = core.output('dataBus_CYC');
      final stb = core.output('dataBus_STB');
      final we = core.output('dataBus_WE');
      final ack = core.input('dataBus_ACK');

      int? readv(Logic l) => l.value.isValid ? l.value.toInt() : null;
      String hex(int? v) =>
          v == null ? 'X' : '0x${v.toRadixString(16).padLeft(16, '0')}';

      reset.inject(1);
      Simulator.setMaxSimTime(2000000000);
      unawaited(Simulator.run());

      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);

      // --- UART decode (liveness proof: 12345678 must emit) ---------------
      final received = <int>[];
      final sb = StringBuffer();
      var prev = 1;

      // --- Wishbone watch (the smoking gun) -------------------------------
      // Log the FIRST access whose ADR lands in [0x88000000, 0x88001000), and
      // the ADR of the access right after the 12345678 print. Also count how
      // many cycles the core then waits without an ack.
      var sawSelfTest = false;
      var firstCtrlLogged = false;
      var firstPostPrintLogged = false;
      var ctrlAckSeen = false;
      var ctrlWaitCycles = 0;
      int? prevAdr;

      const maxCycles = 4000000;
      var emittedDiag = false;

      for (var cycle = 0; cycle < maxCycles; cycle++) {
        await clk.nextPosedge;

        // Wishbone observation, every cycle.
        final a = readv(adr);
        final c = readv(cyc) ?? 0;
        final s = readv(stb) ?? 0;
        final w = readv(we) ?? 0;
        final k = readv(ack) ?? 0;

        // The access right after the self-test print: log the first distinct
        // bus address presented once 12345678 has streamed.
        if (sawSelfTest && !firstPostPrintLogged && c == 1 && s == 1) {
          if (a != prevAdr) {
            // ignore: avoid_print
            print(
              'POST-PRINT first bus access: ADR=${hex(a)} '
              'CYC=$c STB=$s WE=$w ACK=$k',
            );
            firstPostPrintLogged = true;
          }
        }

        // First train-control-window access.
        final inCtrl = a != null && a >= trainCtrlLo && a < trainCtrlHi;
        // Also catch the sign-extended form 0xFFFFFFFF_88000018 explicitly.
        final lowMatchesStatus = a != null && (a & 0xFFFFFFFF) == statusAddr;
        if (!firstCtrlLogged &&
            c == 1 &&
            s == 1 &&
            (inCtrl || lowMatchesStatus)) {
          final low32 = (a & 0xFFFFFFFF).toRadixString(16);
          // ignore: avoid_print
          print(
            'FIRST train-control access @cycle $cycle: '
            'ADR=${hex(a)} (low32=0x$low32) '
            'CYC=$c STB=$s WE=$w ACK=$k '
            'inWindow=$inCtrl signExtended=${a > 0xFFFFFFFF}',
          );
          firstCtrlLogged = true;
        }
        if (firstCtrlLogged && !ctrlAckSeen) {
          if (k == 1) {
            ctrlAckSeen = true;
            // ignore: avoid_print
            print(
              'train-control access ACKED after $ctrlWaitCycles wait '
              'cycles: ADR=${hex(a)} ACK=$k',
            );
          } else if (c == 1 && s == 1) {
            ctrlWaitCycles++;
          }
        }
        if (c == 1 && s == 1) prevAdr = a;

        // UART decode (sample once per sysclk; mid-bit on falling edge).
        final cur = tx.value.isValid ? tx.value.toInt() : 1;
        if (prev == 1 && cur == 0) {
          for (var x = 0; x < divisor + divisor ~/ 2; x++) {
            await clk.nextPosedge;
            cycle++;
          }
          var byte = 0;
          for (var b = 0; b < 8; b++) {
            final bit = tx.value.isValid ? tx.value.toInt() & 1 : 1;
            byte |= bit << b;
            for (var x = 0; x < divisor; x++) {
              await clk.nextPosedge;
              cycle++;
            }
          }
          received.add(byte);
          if (byte >= 0x20 && byte < 0x7f) {
            sb.writeCharCode(byte);
          } else {
            sb.write('[${byte.toRadixString(16).padLeft(2, '0')}]');
          }
          final text = String.fromCharCodes(
            received.where((b) => b >= 0x20 && b < 0x7f),
          );
          if (text.contains('12345678')) sawSelfTest = true;
          // DIAG only prints if the STATUS read returned (control read acked).
          if (text.contains('DIAG')) emittedDiag = true;
          prev = tx.value.isValid ? tx.value.toInt() : 1;
          // Stop early once we have the verdict either way: DIAG means the
          // control read acked (no hang); a logged control access that never
          // acks for a long stretch means the hang reproduced.
          if (emittedDiag) break;
          if (firstCtrlLogged && ctrlWaitCycles > 2000) break;
          continue;
        }
        prev = cur;

        if (firstCtrlLogged && ctrlWaitCycles > 2000) break;
      }

      await Simulator.endSimulation();
      await Simulator.simulationEnded;

      // ignore: avoid_print
      print('UART bytes (${received.length}): $sb');
      // ignore: avoid_print
      print(
        'summary: selfTest=$sawSelfTest firstCtrlLogged=$firstCtrlLogged '
        'ctrlAckSeen=$ctrlAckSeen ctrlWaitCycles=$ctrlWaitCycles '
        'emittedDiag=$emittedDiag',
      );

      // Liveness: the core must at least reach the self-test print.
      final text = String.fromCharCodes(
        received.where((b) => b >= 0x20 && b < 0x7f),
      );
      expect(
        text,
        contains('12345678'),
        reason: 'core must emit the 12345678 self-test (decoded: $sb)',
      );

      // The definitive question: did the train-control STATUS read ack?
      // If DIAG emits or the control access acked, the full-SoC RTL does NOT
      // reproduce the hang (the control plane is correct, so the hardware hang
      // is a silicon/analog/config effect needing board instrumentation). If
      // the control access never acked, the hang reproduced and the logged ADR
      // above pinpoints the mechanism.
      expect(
        ctrlAckSeen || emittedDiag,
        isTrue,
        reason:
            'train-control STATUS read at 0x88000018 never acked: the '
            'hardware hang reproduced in full-SoC RTL. See the logged FIRST '
            'train-control access ADR/CYC/STB/ACK above for the mechanism.',
      );
    },
  );
}
