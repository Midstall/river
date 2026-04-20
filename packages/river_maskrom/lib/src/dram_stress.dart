import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// A diagnostic stub run FROM DRAM (copied and jumped to by [RiverDramExec])
/// that reproduces the Weir-main bss-memset hang in isolation. [RiverDramPing]
/// showed instruction fetch from DRAM alone is clean; the hang only appears when
/// the core fetches its loop from DRAM WHILE streaming heavy writes to DRAM.
/// This recreates that: a tight store loop across a multi-MB region (every store
/// crosses the MMU arbiter, the 2:1 downsizer, and the CDC bridge into the PHY),
/// with the loop body itself re-fetched from DRAM every iteration.
///
/// Prints a '.' after each sweep: steady dots => fetch-under-write is sound;
/// dots stop/garble => the core wandered mid-sweep (the hang).
///
/// Position-independent; UART base and write region are absolute immediates. The
/// write region starts at dramBase + 0x100000 so it never overwrites this stub.
class RiverDramWriteStress extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDramWriteStress({
    required this.isa,
    required int uartBase,
    required int dramBase,
    int unroll = 512, // inline stores per pass: makes the CODE span many DRAM
    // rows so instruction fetch constantly row-misses (like Weir main's MB of
    // code), which a tight one-row loop never hits. Bounded by the boot ROM.
    bool useSd = false, // 64-bit `sd` stores (drive BOTH downsizer lanes, sel
    // 0xFF) instead of 32-bit `sw` (one lane). Weir's memset is 8-byte; the
    // both-lanes split is an untested downsizer path under contention.
    int writeOffset = 0x100000, // store-region offset from dramBase. The stub
    // CODE is fetched from low DRAM (dramBase); a LARGE writeOffset puts the
    // store stream far from the fetch stream (like Weir: code low, bss reaching
    // ~8MB up), exposing any ifetch-vs-dport address-mux race in the arbiter/CDC
    // that close-together stubs never hit.
  }) {
    final writeBase = dramBase + writeOffset; // store region
    final step = useSd ? 8 : 4;
    register(Register.x13).bind(li(uartBase)); // UART base
    register(Register.x19).bind(li(0xA5A5A5A5)); // store pattern

    // Walk a pointer CONTIGUOUSLY up DRAM (NO reset), emitting a '.' every 64
    // KiB, exactly like Weir's bss clear. This reproduces the Weir hang outside
    // Weir: from a PAGE-ALIGNED writeOffset it runs for many MB, but from a
    // page-MISALIGNED writeOffset (e.g. Weir's bss_start 0x9xx) it should hang
    // after ~1 MiB if the controller's alignment handling is the bug. [unroll]
    // is ignored here (kept for the API); the per-dot count gives a 64 KiB body.
    final perDot = 0x10000 ~/ step; // stores per 64 KiB
    register(Register.x17).bind(li(writeBase)); // ptr (walks, never resets)
    final outer = label('stress_outer');
    register(Register.x18).bind(li(perDot)); // down-counter for this 64 KiB
    final inner = label('stress_inner');
    if (useSd) {
      sd(register(Register.x17), register(Register.x19));
    } else {
      sw(register(Register.x17), register(Register.x19));
    }
    register(Register.x17).bind(addi(register(Register.x17), step));
    register(Register.x18).bind(addi(register(Register.x18), -1));
    bne(register(Register.x18), register(Register.x0), inner);
    // 64 KiB done: print '.'.
    final poll = label('stress_poll');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x14).bind(andi(lsr, 0x20));
    beq(register(Register.x14), register(Register.x0), poll);
    register(Register.x11).bind(li(0x2e)); // '.'
    sb(register(Register.x13), register(Register.x11));
    jal(outer);
  }

  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
