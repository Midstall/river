import 'dart:math' show max;

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:river/river.dart';

enum InterruptPortGroup { control, hostData, clientData, integrity }

class InterruptPortInterface extends Interface<InterruptPortGroup> {
  final int dataWidth;
  final int addrWidth;

  Logic get en => port('en');
  Logic get write => port('write');
  Logic get addr => port('addr');
  Logic get wdata => port('wdata');
  Logic get wstrb => port('wstrb');
  Logic get rdata => port('rdata');
  Logic get valid => port('valid');
  Logic get done => port('done');

  InterruptPortInterface(this.dataWidth, this.addrWidth) {
    if (dataWidth % 8 != 0) {
      throw RohdHclException(
        'InterruptPortInterface dataWidth must be byte-aligned.',
      );
    }

    setPorts(
      [Logic.port('en'), Logic.port('write'), Logic.port('addr', addrWidth)],
      [InterruptPortGroup.control],
    );

    setPorts(
      [Logic.port('wdata', dataWidth), Logic.port('wstrb', dataWidth ~/ 8)],
      [InterruptPortGroup.hostData],
    );

    setPorts([Logic.port('rdata', dataWidth)], [InterruptPortGroup.clientData]);

    setPorts(
      [Logic.port('valid'), Logic.port('done')],
      [InterruptPortGroup.integrity],
    );
  }

  @override
  InterruptPortInterface clone() =>
      InterruptPortInterface(dataWidth, addrWidth);
}

class RiscVInterruptController extends Module {
  final InterruptController config;

  static const int _prioBase = 0x0000;
  static const int _pendBase = 0x1000;
  static const int _ctxBase = 0x3000;

  static const int _ctxStride = 0x100;
  static const int _thrOff = 0x00;
  static const int _claimOff = 0x04;

  Logic get srcIrqLevel => input('srcIrqLevel');
  Logic get irqToTargets => output('irqToTargets');

  late final int maxIrq;
  late final int numIrqs;
  late final List<String> targets;
  late final int numTargets;

  late final List<Logic> _known;
  late final List<Logic> _prio;
  late final List<Logic> _pending;
  late final List<Logic> _inService;
  late final List<List<Logic>> _enable;
  late final List<Logic> _threshold;

  late final List<Logic> _bestIrq;
  late final List<Logic> _bestPrio;
  late final List<Logic> _bestValid;

  RiscVInterruptController(
    this.config,
    Logic clk,
    Logic reset,
    Logic srcIrqLevelIn,
    InterruptPortInterface ipi, {
    super.name = 'riscv_int_ctrl',
  }) {
    final irqList = config.lines.map((l) => l.irq).toList();
    maxIrq = irqList.isEmpty ? 0 : irqList.reduce((a, b) => a > b ? a : b);
    numIrqs = maxIrq + 1;

    final tset = <String>{};
    for (final l in config.lines) {
      tset.add(l.target);
    }
    targets = tset.toList()..sort();
    numTargets = targets.length;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    srcIrqLevelIn = addInput(
      'srcIrqLevel',
      srcIrqLevelIn,
      width: max(1, numIrqs),
    );
    addOutput('irqToTargets', width: max(1, numTargets));

    ipi = ipi.clone()
      ..connectIO(
        this,
        ipi,
        inputTags: {InterruptPortGroup.control, InterruptPortGroup.hostData},
        outputTags: {
          InterruptPortGroup.clientData,
          InterruptPortGroup.integrity,
        },
        uniquify: (o) => 'ipi_$o',
      );

    final knownSet = {for (final l in config.lines) l.irq};

    _known = List.generate(
      numIrqs,
      (i) => Const((i != 0 && knownSet.contains(i)) ? 1 : 0),
    );

    _prio = List.generate(numIrqs, (i) => Logic(name: 'prio_$i', width: 32));
    _pending = List.generate(numIrqs, (i) => Logic(name: 'pend_$i'));
    _inService = List.generate(numIrqs, (i) => Logic(name: 'svc_$i'));

    _threshold = List.generate(
      numTargets,
      (t) => Logic(name: 'thr_t$t', width: 32),
    );

    _enable = List.generate(
      numTargets,
      (t) => List.generate(numIrqs, (i) => Logic(name: 'en_t${t}_$i')),
    );

    _bestIrq = List.generate(
      numTargets,
      (t) => Logic(name: 'bestIrq_t$t', width: 32),
    );
    _bestPrio = List.generate(
      numTargets,
      (t) => Logic(name: 'bestPrio_t$t', width: 32),
    );
    _bestValid = List.generate(numTargets, (t) => Logic(name: 'bestValid_t$t'));

    Logic eqAddr(int value) => ipi.addr.eq(Const(value, width: ipi.addr.width));

    Logic maskedWrite32(Logic old32, Logic wdata32, Logic wstrb4) {
      Logic out = Const(0, width: 32);
      for (var b = 0; b < 4; b++) {
        final oldB = old32.getRange(b * 8, b * 8 + 8);
        final newB = wdata32.getRange(b * 8, b * 8 + 8);
        out = out.withSet(b * 8, mux(wstrb4[b], newB, oldB));
      }
      return out;
    }

    for (var t = 0; t < numTargets; t++) {
      Logic bestIrq = Const(0, width: 32);
      Logic bestPrio = Const(0, width: 32);
      Logic bestValid = Const(0);

      for (var i = 1; i < numIrqs; i++) {
        final cand =
            _known[i] &
            _pending[i] &
            ~_inService[i] &
            _enable[t][i] &
            _prio[i].gt(_threshold[t]);

        final better = cand & (~bestValid | _prio[i].gt(bestPrio));

        bestIrq = mux(better, Const(i, width: 32), bestIrq);
        bestPrio = mux(better, _prio[i], bestPrio);
        bestValid = bestValid | cand;
      }

      _bestIrq[t] <= bestIrq;
      _bestPrio[t] <= bestPrio;
      _bestValid[t] <= bestValid;
    }

    Logic irqAny = Const(0);
    for (var t = 0; t < numTargets; t++) {
      irqAny = irqAny | _bestValid[t];
    }
    irqToTargets <= irqAny;

    Logic rdExpr = Const(0, width: ipi.dataWidth);

    void addRead(Logic hit, Logic val) {
      rdExpr = mux(hit, val, rdExpr);
    }

    final base = config.baseAddr;

    for (var i = 0; i < numIrqs; i++) {
      addRead(
        ipi.en & ~ipi.write & eqAddr(base + _prioBase + 4 * i),
        _prio[i].zeroExtend(ipi.dataWidth),
      );
    }

    final numWords = (numIrqs + 31) ~/ 32;
    for (var w = 0; w < numWords; w++) {
      Logic word = Const(0, width: 32);
      for (var b = 0; b < 32; b++) {
        final idx = w * 32 + b;
        if (idx < numIrqs) {
          word = word.withSet(b, _pending[idx]);
        }
      }
      addRead(
        ipi.en & ~ipi.write & eqAddr(base + _pendBase + 4 * w),
        word.zeroExtend(ipi.dataWidth),
      );
    }

    for (var t = 0; t < numTargets; t++) {
      addRead(
        ipi.en &
            ~ipi.write &
            eqAddr(base + _ctxBase + t * _ctxStride + _thrOff),
        _threshold[t].zeroExtend(ipi.dataWidth),
      );

      addRead(
        ipi.en &
            ~ipi.write &
            eqAddr(base + _ctxBase + t * _ctxStride + _claimOff),
        mux(
          _bestValid[t],
          _bestIrq[t],
          Const(0, width: 32),
        ).zeroExtend(ipi.dataWidth),
      );
    }

    ipi.rdata <= rdExpr;
    ipi.valid <= ipi.en;
    ipi.done <= ipi.en;

    final resetValues = <Logic, Logic>{};

    for (var i = 0; i < numIrqs; i++) {
      resetValues[_prio[i]] = Const(
        (i != 0 && knownSet.contains(i)) ? 1 : 0,
        width: 32,
      );
      resetValues[_pending[i]] = Const(0);
      resetValues[_inService[i]] = Const(0);
    }
    for (var t = 0; t < numTargets; t++) {
      resetValues[_threshold[t]] = Const(0, width: 32);
      for (var i = 0; i < numIrqs; i++) {
        resetValues[_enable[t][i]] = Const(
          i != 0 &&
                  config.lines.any((l) => l.target == targets[t] && l.irq == i)
              ? 1
              : 0,
        );
      }
    }

    final isWrite = ipi.en & ipi.write;
    final isRead = ipi.en & ~ipi.write;
    final wdata32 = ipi.wdata.getRange(0, 32);
    final wstrb4 = ipi.wstrb.getRange(0, 4);

    final seq = <Conditional>[];

    for (var i = 1; i < numIrqs; i++) {
      seq.add(If(_known[i] & srcIrqLevel[i], then: [_pending[i] < Const(1)]));
    }

    for (var i = 0; i < numIrqs; i++) {
      final hit = isWrite & eqAddr(base + _prioBase + 4 * i);
      seq.add(
        If(
          hit & _known[i],
          then: [_prio[i] < maskedWrite32(_prio[i], wdata32, wstrb4)],
        ),
      );
    }

    for (var t = 0; t < numTargets; t++) {
      final hit = isRead & eqAddr(base + _ctxBase + t * _ctxStride + _claimOff);
      for (var i = 1; i < numIrqs; i++) {
        seq.add(
          If(
            hit & _bestIrq[t].eq(Const(i, width: 32)),
            then: [_pending[i] < Const(0), _inService[i] < Const(1)],
          ),
        );
      }
    }

    for (var t = 0; t < numTargets; t++) {
      final hit =
          isWrite & eqAddr(base + _ctxBase + t * _ctxStride + _claimOff);
      for (var i = 1; i < numIrqs; i++) {
        seq.add(
          If(
            hit & wdata32.eq(Const(i, width: 32)),
            then: [_inService[i] < Const(0)],
          ),
        );
      }
    }

    Sequential(clk, reset: reset, resetValues: resetValues, seq);
  }
}
