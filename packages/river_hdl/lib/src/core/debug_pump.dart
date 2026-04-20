import 'dart:async';

/// Paces the remote-bitbang sim clock against JTAG activity, with a resume-aware
/// free-run so a resumed program actually executes.
///
/// The remote_bitbang JTAG transport advances the simulator on demand: normally
/// one core clock per JTAG bit (the TAP shifts once per bit). That cadence is
/// fine for examine/halt/abstract-command traffic, but it STARVES a running
/// program. After the debugger resumes the hart, OpenOCD only clocks the core
/// while it is polling `dmstatus`, so a multi-instruction program never reaches
/// its result before OpenOCD force-halts. The half-run state then reads back as
/// a spurious "divergence" against a free-running golden model (spike/emulator).
///
/// [ResumePump] fixes that: on a halted -> running RESUME EDGE it free-runs the
/// core to its self-halt (an armed `ebreak`), bounded by [resumeBudget] so a
/// program that never self-halts falls back to one-clock-per-bit instead of
/// wedging. It yields to the event loop every [yieldEvery] clocks so a long
/// free-run does not monopolize the loop (the failure mode of `Simulator.run()`,
/// which starves all I/O and timers).
///
/// NOTE: the remote_bitbang server processes JTAG bits serially
/// (`await for (data) { ... await onTick() }`), so an OpenOCD halt request that
/// arrives DURING the free-run is not read until the free-run returns. The
/// free-run therefore terminates on the program's own self-halt or the budget,
/// not on a mid-run debugger halt. That is correct for the verification flow
/// (Heimdall loads self-halting firmware). Honoring a mid-run halt would require
/// driving the core clock from a background loop decoupled from `onTick`; that is
/// a future refinement, see project_debug_jtag.
///
/// Critically, the free-run is gated on the halted -> running EDGE, not on
/// "the core is running". The core also runs after reset/examine (the default
/// firmware is an idle loop that never self-halts); free-running THAT would spin
/// the budget on every bit and wedge examine. Only a real debugger resume (the
/// hart was halted on the previous observation and is running now) triggers it.
class ResumePump {
  /// Advance the simulator by exactly one core clock (one rising edge),
  /// servicing whatever the sim needs to service on that edge (e.g. SBA).
  final Future<void> Function() advanceOneClock;

  /// Read the core's current debug-halt state (true = halted in Debug Mode).
  final bool Function() coreHalted;

  /// Maximum clocks to free-run after a resume before falling back to
  /// one-clock-per-bit. Real firmware self-halts long before this.
  final int resumeBudget;

  /// Yield to the event loop (to service the JTAG socket) every this many
  /// free-run clocks. Must be a power of two minus one is not required; this is
  /// used as a modulus.
  final int yieldEvery;

  bool _wasHalted;

  ResumePump({
    required this.advanceOneClock,
    required this.coreHalted,
    this.resumeBudget = 2000000,
    this.yieldEvery = 256,
    bool initiallyHalted = false,
  }) : _wasHalted = initiallyHalted;

  /// The halt state observed at the end of the most recent [pump]. Exposed for
  /// tests and tracing.
  bool get wasHalted => _wasHalted;

  /// Drive one JTAG bit's worth of clocking. Advances one core clock; if that
  /// clock completed a resume edge, free-runs to self-halt (bounded).
  Future<void> pump() async {
    await advanceOneClock();
    if (_wasHalted && !coreHalted()) {
      var budget = resumeBudget;
      while (budget > 0 && !coreHalted()) {
        await advanceOneClock();
        budget--;
        if (budget % yieldEvery == 0) {
          // Hand the event loop a turn so a long free-run does not monopolize it
          // (keeps timers / other I/O alive). Does not let the parked JTAG read
          // process a new bit; see the class note.
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    _wasHalted = coreHalted();
  }
}
