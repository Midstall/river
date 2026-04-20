import 'package:river/river.dart' as river;

class InterruptController {
  final river.InterruptController config;

  final Map<int, bool> _pending = {};
  final Map<int, int> _priority = {};
  final Map<String, Set<int>> _enabled = {};
  final Map<String, int> _threshold = {};
  final Map<int, String> _targetByIrq = {};
  final Map<int, String> _sourceByIrq = {};

  InterruptController(this.config) {
    for (final line in config.lines) {
      final irq = line.irq;
      _pending[irq] = false;
      _priority[irq] = 1;
      _targetByIrq[irq] = line.target;
      _sourceByIrq[irq] = line.source;

      _enabled.putIfAbsent(line.target, () => <int>{});
      _enabled[line.target]!.add(irq);
      _threshold.putIfAbsent(line.target, () => 0);
    }
  }

  Iterable<int> get irqs => _pending.keys;
  Iterable<String> get targets => _enabled.keys;

  bool isKnownIrq(int irq) => _pending.containsKey(irq);
  String? targetOf(int irq) => _targetByIrq[irq];
  String? sourceOf(int irq) => _sourceByIrq[irq];

  int getPriority(int irq) {
    _checkIrq(irq);
    return _priority[irq] ?? 0;
  }

  void setPriority(int irq, int prio) {
    _checkIrq(irq);
    _priority[irq] = prio;
  }

  int getThreshold(String target) {
    _checkTarget(target);
    return _threshold[target] ?? 0;
  }

  void setThreshold(String target, int value) {
    _checkTarget(target);
    _threshold[target] = value;
  }

  bool isEnabled(String target, int irq) {
    _checkIrq(irq);
    _checkTarget(target);
    return _enabled[target]?.contains(irq) ?? false;
  }

  void setEnabled(String target, int irq, bool enable) {
    _checkIrq(irq);
    _checkTarget(target);
    final set = _enabled[target]!;
    if (enable) {
      set.add(irq);
    } else {
      set.remove(irq);
    }
  }

  bool isPending(int irq) {
    _checkIrq(irq);
    return _pending[irq] ?? false;
  }

  void raise(String source, int irq) {
    _checkIrq(irq);

    final expectedSource = _sourceByIrq[irq];
    if (expectedSource != null && expectedSource != source) {
      throw StateError(
        'Interrupt source mismatch for IRQ $irq: '
        'expected $expectedSource, got $source',
      );
    }

    _pending[irq] = true;
  }

  void lower(String source, int irq) {
    _checkIrq(irq);

    final expectedSource = _sourceByIrq[irq];
    if (expectedSource != null && expectedSource != source) {
      throw StateError(
        'Interrupt source mismatch for IRQ $irq: '
        'expected $expectedSource, got $source',
      );
    }

    _pending[irq] = false;
  }

  int pendingMaskForTarget(String target) {
    _checkTarget(target);
    int mask = 0;
    for (final irq in _pending.keys) {
      if (_pending[irq] == true && (_enabled[target]?.contains(irq) ?? false)) {
        mask |= (1 << irq);
      }
    }
    return mask;
  }

  bool hasDeliverableInterrupt(String target) =>
      _findBestIrqForTarget(target) != null;

  int? _findBestIrqForTarget(String target) {
    _checkTarget(target);

    final thr = _threshold[target] ?? 0;
    int? bestIrq;
    int bestPrio = 0;

    for (final irq in _pending.keys) {
      if (_pending[irq] != true) continue;
      if (!(_enabled[target]?.contains(irq) ?? false)) continue;

      final prio = _priority[irq] ?? 0;
      if (prio <= thr) continue;

      if (bestIrq == null || prio > bestPrio) {
        bestIrq = irq;
        bestPrio = prio;
      }
    }

    return bestIrq;
  }

  int? nextPending() {
    final active = _pending.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toList();

    if (active.isEmpty) return null;

    active.sort();
    return active.first;
  }

  void complete(String target, int irq) {
    _checkIrq(irq);
    _checkTarget(target);

    if (targetOf(irq) != target) {
      throw StateError(
        'IRQ $irq is wired to target ${targetOf(irq)}, '
        'but completed for $target',
      );
    }

    _pending[irq] = false;
  }

  void _checkIrq(int irq) {
    if (!_pending.containsKey(irq)) {
      throw ArgumentError('Unknown IRQ $irq for controller ${config.name}');
    }
  }

  void _checkTarget(String target) {
    if (!_enabled.containsKey(target)) {
      throw ArgumentError(
        'Unknown interrupt target "$target" for controller ${config.name}',
      );
    }
  }

  @override
  String toString() => 'InterruptController(config: $config, pending: $irqs)';
}
