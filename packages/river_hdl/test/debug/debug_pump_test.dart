import 'package:river_hdl/river_hdl.dart';
import 'package:test/test.dart';

/// Unit tests for [ResumePump]'s resume-aware clocking, using a mock core so the
/// loop logic is exercised without building any RTL (fast). The mock counts
/// `advanceOneClock` calls and reports "halted" via a programmable predicate, so
/// each test scripts exactly when the core self-halts.
void main() {
  test(
    'no resume edge: a running core advances exactly one clock per pump',
    () async {
      // Core is running and stays running (never halted, no edge). Each pump must
      // advance exactly one clock - no free-run.
      final mock = _Mock(haltsAfter: null, startHalted: false);
      final pump = mock.makePump(1000000);
      for (var i = 0; i < 5; i++) {
        await pump.pump();
      }
      expect(mock.clocks, 5, reason: 'one clock per bit when never halted');
    },
  );

  test(
    'post-reset running never triggers free-run even after many pumps',
    () async {
      // The dummy-firmware case: running from reset, never halted. Must NOT spin
      // the budget (the bug the redesign fixes).
      final mock = _Mock(haltsAfter: null, startHalted: false);
      final pump = mock.makePump(1000000);
      for (var i = 0; i < 20; i++) {
        await pump.pump();
      }
      expect(
        mock.clocks,
        20,
        reason: 'no edge -> no free-run -> no budget spin',
      );
    },
  );

  test('resume edge free-runs to self-halt', () async {
    // Core starts halted; the first pump observes the running transition (the
    // mock flips to running once pumped) and free-runs until it self-halts.
    final mock = _Mock(haltsAfter: 7, startHalted: true);
    final pump = mock.makePump(1000000);
    // First pump: advanceOneClock makes the mock "resumed" (running), the pump
    // sees was-halted && now-running -> free-run until clock 7 self-halts.
    await pump.pump();
    expect(mock.halted, isTrue, reason: 'free-run reached the self-halt');
    expect(mock.clocks, 7, reason: 'ran exactly to the ebreak (clock 7)');
    expect(pump.wasHalted, isTrue);
  });

  test('non-self-halting resume falls back at the budget (no wedge)', () async {
    // Resume onto a program with no ebreak: the free-run must stop at the budget
    // and hand control back, not spin forever.
    final mock = _Mock(haltsAfter: null, startHalted: true);
    final pump = mock.makePump(500);
    await pump.pump();
    // 1 clock for the pump's own advance (the resume edge) + 500 free-run.
    expect(mock.clocks, 501, reason: 'free-run bounded by the budget');
    expect(pump.wasHalted, isFalse, reason: 'still running after the budget');
    // After the budget it is one-clock-per-bit again (no fresh edge: it was
    // already running at the end of the last pump).
    await pump.pump();
    expect(
      mock.clocks,
      502,
      reason: 'no re-trigger; back to one clock per bit',
    );
  });

  test('halt then resume across pumps is a single edge', () async {
    // Running -> debugger halts -> debugger resumes onto a self-halting program.
    final mock = _Mock(haltsAfter: null, startHalted: false);
    final pump = mock.makePump(1000000);
    await pump.pump(); // running, one clock
    expect(mock.clocks, 1);

    // Debugger halts the core.
    mock.forceHalt();
    await pump.pump(); // observes halted; one clock, no edge
    expect(pump.wasHalted, isTrue);

    // Debugger resumes onto a program that self-halts after 4 clocks.
    mock.resumeSelfHaltingAfter(4);
    await pump.pump(); // edge -> free-run to self-halt
    expect(mock.halted, isTrue);
    expect(pump.wasHalted, isTrue);
  });
}

/// Mock core driving a [ResumePump]. Halt state is scripted so tests can place
/// the self-halt at a precise clock.
class _Mock {
  _Mock({required this.haltsAfter, required this.startHalted})
    : _halted = startHalted;

  /// Clocks-since-resume at which the core self-halts (null = never).
  int? haltsAfter;
  final bool startHalted;

  int clocks = 0;
  int _clocksSinceResume = 0;
  bool _halted;
  bool _forcedHalt = false;

  bool get halted => _halted;

  ResumePump makePump(int resumeBudget) => ResumePump(
    advanceOneClock: _advance,
    coreHalted: () => _halted,
    resumeBudget: resumeBudget,
    yieldEvery: 64,
    initiallyHalted: startHalted,
  );

  Future<void> _advance() async {
    clocks++;
    // The first clock after being halted is the resume: the core starts running.
    if (_halted && !_forcedHalt) {
      _halted = false;
      _clocksSinceResume = 0;
    }
    if (!_halted) {
      _clocksSinceResume++;
      if (haltsAfter != null && _clocksSinceResume >= haltsAfter!) {
        _halted = true;
      }
    }
  }

  /// Debugger halt: the core is halted and stays halted until a resume is set up.
  void forceHalt() {
    _halted = true;
    _forcedHalt = true;
  }

  /// Debugger resume onto a program that self-halts after [n] clocks.
  void resumeSelfHaltingAfter(int n) {
    _forcedHalt = false;
    haltsAfter = n;
  }
}
