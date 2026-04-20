import 'package:rohd/rohd.dart';

int _log2(int n) {
  var bits = 0;
  var v = n - 1;
  while (v > 0) {
    bits++;
    v >>= 1;
  }
  return bits == 0 ? 1 : bits;
}

/// Load queue for speculative (out-of-order) loads.
///
/// When a load executes ahead of an older store whose address is not yet known,
/// it records itself here. Later, when that store resolves its address, it CAMs
/// this queue: any *younger* load that already executed to an overlapping
/// address speculated wrong and must be replayed. Program age is the position of
/// a ROB tag relative to the ROB head (`(tag - headIdx) mod robDepth`), so a
/// load is younger than the store when its position is greater.
///
/// Entries allocate at load execute and free when the load commits (it is then
/// safe, every older store has committed before it). A flush clears all.
class LoadQueue extends Module {
  final int depth;
  final int xlen;
  final int robTagBits;

  /// No free entry to record another speculative load.
  Logic get full => output('full');

  /// The CAMming store (cam_valid) hit a younger overlapping executed load,
  /// an ordering violation, so the store must trigger a replay.
  Logic get camViolation => output('cam_violation');

  LoadQueue(
    Logic clk,
    Logic reset, {
    required Logic flush,
    // Push: a load executed this cycle, record it.
    required Logic pushValid,
    required Logic pushTag,
    required Logic pushAddr,
    required Logic pushSize,
    // Free: a load committed this cycle, drop its entry (matched by tag).
    required Logic freeValid,
    required Logic freeTag,
    // ROB head index, for age (position) comparison.
    required Logic headIdx,
    // CAM: a store resolved its address this cycle, check for violations.
    required Logic camValid,
    required Logic camTag,
    required Logic camAddr,
    required Logic camSize,
    this.depth = 8,
    this.xlen = 64,
    this.robTagBits = 6,
    super.name = 'load_queue',
  }) : super(definitionName: 'LoadQueue') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    flush = addInput('flush', flush);
    pushValid = addInput('push_valid', pushValid);
    pushTag = addInput('push_tag', pushTag, width: robTagBits);
    pushAddr = addInput('push_addr', pushAddr, width: xlen);
    pushSize = addInput('push_size', pushSize, width: 3);
    freeValid = addInput('free_valid', freeValid);
    freeTag = addInput('free_tag', freeTag, width: robTagBits);
    headIdx = addInput('head_idx', headIdx, width: robTagBits);
    camValid = addInput('cam_valid', camValid);
    camTag = addInput('cam_tag', camTag, width: robTagBits);
    camAddr = addInput('cam_addr', camAddr, width: xlen);
    camSize = addInput('cam_size', camSize, width: 3);

    final slotBits = _log2(depth);

    final eValid = List.generate(depth, (i) => Logic(name: 'lq_valid_$i'));
    final eTag = List.generate(
      depth,
      (i) => Logic(name: 'lq_tag_$i', width: robTagBits),
    );
    final eAddr = List.generate(
      depth,
      (i) => Logic(name: 'lq_addr_$i', width: xlen),
    );
    final eSize = List.generate(
      depth,
      (i) => Logic(name: 'lq_size_$i', width: 3),
    );

    addOutput('full');
    addOutput('cam_violation');

    // First free slot.
    final freeSlot = Logic(name: 'lq_free_slot', width: slotBits);
    final freeFound = Logic(name: 'lq_free_found');
    final slotConds = <Iff>[];
    for (var i = 0; i < depth; i++) {
      final c = [freeSlot < Const(i, width: slotBits), freeFound < 1];
      slotConds.add(i == 0 ? Iff(~eValid[i], c) : ElseIf(~eValid[i], c));
    }
    slotConds.add(Else([freeSlot < 0, freeFound < 0]));
    Combinational([If.block(slotConds)]);
    full <= ~freeFound;

    // CAM: any valid YOUNGER load overlapping the store's byte range?
    final sEnd = (camAddr + camSize.zeroExtend(xlen)).named('lq_cam_send');
    final storePos = (camTag - headIdx).named('lq_cam_spos');
    Logic anyViol = Const(0);
    for (var j = 0; j < depth; j++) {
      final loadPos = (eTag[j] - headIdx);
      final younger = loadPos.gt(storePos);
      final eEnd = (eAddr[j] + eSize[j].zeroExtend(xlen));
      final overlap = camAddr.lt(eEnd) & eAddr[j].lt(sEnd);
      anyViol = anyViol | (eValid[j] & younger & overlap);
    }
    camViolation <= camValid & anyViol;

    Sequential(clk, [
      If(
        reset | flush,
        then: [...List.generate(depth, (i) => eValid[i] < 0)],
        orElse: [
          If(
            pushValid & freeFound,
            then: [
              for (var i = 0; i < depth; i++)
                If(
                  freeSlot.eq(Const(i, width: slotBits)),
                  then: [
                    eValid[i] < 1,
                    eTag[i] < pushTag,
                    eAddr[i] < pushAddr,
                    eSize[i] < pushSize,
                  ],
                ),
            ],
          ),
          // Free the committed load's entry (matched by tag).
          If(
            freeValid,
            then: [
              for (var i = 0; i < depth; i++)
                If(eValid[i] & eTag[i].eq(freeTag), then: [eValid[i] < 0]),
            ],
          ),
        ],
      ),
    ]);
  }
}
