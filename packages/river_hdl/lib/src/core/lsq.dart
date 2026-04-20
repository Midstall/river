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

/// Store queue: a FIFO of executed stores awaiting (and undergoing) their write
/// to memory.
///
/// A store pushes an entry here when it *executes* (address + data known), well
/// before it commits. Three pointers carve the queue into regions:
///
/// ```
///   head ............ commitPtr ............ tail
///   |  committed,    |  speculative        |
///   |  draining      |  (not yet retired)  |
/// ```
///
/// * `tail` advances on push (a store executed).
/// * `commitPtr` advances when a store retires (`commitValid`), the store is
///   now architectural and its write may go to memory.
/// * `head` advances on `popValid` (a memory write completed).
///
/// Entries in `[head, commitPtr)` are committed and drain to memory in program
/// order *in the background*, the store does NOT stall commit waiting for its
/// write, so several stores can be in flight at once. A load waits until the
/// whole queue is empty (every older store has reached memory). A flush drops
/// only the speculative tail (`tail <- commitPtr`); committed entries are
/// architectural and keep draining.
class StoreQueue extends Module {
  final int depth;
  final int xlen;
  final int robTagBits;

  /// No entries in flight (committed or speculative).
  Logic get empty => output('empty');

  /// No room to push another store (execute must stall).
  Logic get full => output('full');

  /// The head (oldest) entry is committed and ready to write to memory.
  Logic get headDrainable => output('head_drainable');
  Logic get headAddr => output('head_addr');
  Logic get headData => output('head_data');
  Logic get headSize => output('head_size');
  Logic get headTag => output('head_tag');

  /// Store→load forwarding for the address/size on `fwd_query_*`:
  /// * `fwdHit`, the youngest store overlapping the query EXACTLY matches its
  ///   address and size; `fwdData` carries its value (forward it, skip the bus).
  /// * `fwdStall`, the youngest overlapping store only partially covers the load
  ///   (different size or a misaligned overlap); the load must wait for the
  ///   queue to drain that store before reading the bus.
  /// * neither, no store overlaps the load; it may read the bus immediately.
  Logic get fwdHit => output('fwd_hit');
  Logic get fwdData => output('fwd_data');
  Logic get fwdStall => output('fwd_stall');

  StoreQueue(
    Logic clk,
    Logic reset, {
    required Logic flush,
    // Push (a store executed this cycle): append addr/data/size at the tail.
    required Logic pushValid,
    required Logic pushTag,
    required Logic pushAddr,
    required Logic pushData,
    required Logic pushSize,
    // A store retired this cycle: advance the commit pointer so the oldest
    // speculative entry becomes architectural (drainable).
    required Logic commitValid,
    // A SECOND store retired the same cycle (dual-commit of two stores). When
    // high alongside `commitValid`, the commit pointer advances by two. Because
    // memory dispatches in program order and dual-commit is in-order, the two
    // retiring stores are always the two oldest speculative entries, so jumping
    // the pointer by two is always correct. Tied off (single store/cycle) when
    // not driven. This lets the pipeline commit store pairs without throttling
    // them through one slot, so the queue makes no assumption about the rate at
    // which stores arrive at commit. See project_hdl_frontend_perf.
    Logic? commitValid2,
    // The head store's memory write completed this cycle: remove the head.
    required Logic popValid,
    // Forwarding query (a load's effective address + byte size). Combinational.
    required Logic fwdQueryAddr,
    required Logic fwdQuerySize,
    this.depth = 8,
    this.xlen = 64,
    this.robTagBits = 6,
    super.name = 'store_queue',
  }) : super(definitionName: 'StoreQueue') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    flush = addInput('flush', flush);
    pushValid = addInput('push_valid', pushValid);
    pushTag = addInput('push_tag', pushTag, width: robTagBits);
    pushAddr = addInput('push_addr', pushAddr, width: xlen);
    pushData = addInput('push_data', pushData, width: xlen);
    pushSize = addInput('push_size', pushSize, width: 3);
    commitValid = addInput('commit_valid', commitValid);
    commitValid2 = addInput('commit_valid2', commitValid2 ?? Const(0));
    popValid = addInput('pop_valid', popValid);
    fwdQueryAddr = addInput('fwd_query_addr', fwdQueryAddr, width: xlen);
    fwdQuerySize = addInput('fwd_query_size', fwdQuerySize, width: 3);

    final ptrBits = _log2(depth);

    // Circular-buffer pointers. The extra MSB disambiguates full from empty.
    final head = Logic(name: 'sq_head', width: ptrBits + 1);
    final commitPtr = Logic(name: 'sq_commit', width: ptrBits + 1);
    final tail = Logic(name: 'sq_tail', width: ptrBits + 1);

    final entryTag = List.generate(
      depth,
      (i) => Logic(name: 'sq_tag_$i', width: robTagBits),
    );
    final entryAddr = List.generate(
      depth,
      (i) => Logic(name: 'sq_addr_$i', width: xlen),
    );
    final entryData = List.generate(
      depth,
      (i) => Logic(name: 'sq_data_$i', width: xlen),
    );
    final entrySize = List.generate(
      depth,
      (i) => Logic(name: 'sq_size_$i', width: 3),
    );

    final headIdx = head.slice(ptrBits - 1, 0);
    final tailIdx = tail.slice(ptrBits - 1, 0);
    final isEmpty = head.eq(tail);
    final isFull = headIdx.eq(tailIdx) & (head[ptrBits] ^ tail[ptrBits]);
    // A committed-but-not-drained entry exists when head has not caught up to
    // the commit pointer.
    final hasCommitted = ~head.eq(commitPtr);

    addOutput('empty');
    addOutput('full');
    addOutput('head_drainable');
    addOutput('head_addr', width: xlen);
    addOutput('head_data', width: xlen);
    addOutput('head_size', width: 3);
    addOutput('head_tag', width: robTagBits);
    addOutput('fwd_hit');
    addOutput('fwd_data', width: xlen);
    addOutput('fwd_stall');

    Logic muxByIdx(List<Logic> arr, Logic idx) {
      Logic result = arr[0];
      for (var i = 1; i < depth; i++) {
        result = mux(idx.eq(Const(i, width: ptrBits)), arr[i], result);
      }
      return result;
    }

    empty <= isEmpty;
    full <= isFull;
    headDrainable <= hasCommitted;
    headAddr <= muxByIdx(entryAddr, headIdx);
    headData <= muxByIdx(entryData, headIdx);
    headSize <= muxByIdx(entrySize, headIdx);
    headTag <= muxByIdx(entryTag, headIdx);

    // -- Store→load forwarding --------------------------------------------
    // Every live entry is an OLDER store (memory dispatches in program order),
    // so the load forwards from the youngest entry whose byte range overlaps it.
    // pos = distance from head (0 = oldest); larger pos = younger.
    final liveCount = (tail - head).named('sq_live_count');
    final qEnd = (fwdQueryAddr + fwdQuerySize.zeroExtend(xlen)).named(
      'fwd_q_end',
    );
    final pos = <Logic>[];
    final liveOverlap = <Logic>[];
    final exact = <Logic>[];
    for (var j = 0; j < depth; j++) {
      final posj = (Const(j, width: ptrBits) - headIdx).named('sq_pos_$j');
      final livej = posj.zeroExtend(ptrBits + 1).lt(liveCount);
      final sEndj = (entryAddr[j] + entrySize[j].zeroExtend(xlen));
      final overlapj = fwdQueryAddr.lt(sEndj) & entryAddr[j].lt(qEnd);
      pos.add(posj);
      liveOverlap.add((livej & overlapj).named('sq_lov_$j'));
      exact.add(entryAddr[j].eq(fwdQueryAddr) & entrySize[j].eq(fwdQuerySize));
    }
    Logic fwdDataAcc = Const(0, width: xlen);
    Logic fwdExactAcc = Const(0);
    Logic anyOverlap = Const(0);
    for (var j = 0; j < depth; j++) {
      Logic anyYounger = Const(0);
      for (var k = 0; k < depth; k++) {
        if (k == j) continue;
        anyYounger = anyYounger | (liveOverlap[k] & pos[k].gt(pos[j]));
      }
      final isYoungest = liveOverlap[j] & ~anyYounger;
      fwdDataAcc = mux(isYoungest, entryData[j], fwdDataAcc);
      fwdExactAcc = fwdExactAcc | (isYoungest & exact[j]);
      anyOverlap = anyOverlap | liveOverlap[j];
    }
    fwdHit <= fwdExactAcc;
    fwdData <= fwdDataAcc;
    fwdStall <= anyOverlap & ~fwdExactAcc;

    Sequential(clk, [
      If(
        reset,
        then: [head < 0, commitPtr < 0, tail < 0],
        orElse: [
          If(
            flush,
            // Drop the speculative tail; committed entries keep draining.
            then: [tail < commitPtr],
            orElse: [
              If(
                pushValid,
                then: [
                  for (var i = 0; i < depth; i++)
                    If(
                      tailIdx.eq(Const(i, width: ptrBits)),
                      then: [
                        entryTag[i] < pushTag,
                        entryAddr[i] < pushAddr,
                        entryData[i] < pushData,
                        entrySize[i] < pushSize,
                      ],
                    ),
                  tail < tail + 1,
                ],
              ),
              // Advance by the number of stores retiring this cycle (0/1/2).
              commitPtr <
                  commitPtr +
                      (commitValid.zeroExtend(ptrBits + 1) +
                          commitValid2.zeroExtend(ptrBits + 1)),
            ],
          ),
          // A pop can retire a committed entry even on a flush cycle (the
          // draining store is architectural and unaffected by the squash).
          If(popValid, then: [head < head + 1]),
        ],
      ),
    ]);
  }
}
