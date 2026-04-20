import 'package:rohd/rohd.dart';

/// Reorder buffer entry width decomposition.
///
/// Each ROB entry stores:
///   - pc           [xlen bits]
///   - pdst         [physRegBits]
///   - pdstOld      [physRegBits]
///   - rd           [5 bits]
///   - writesRd     [1 bit]
///   - complete     [1 bit]
///   - exception    [1 bit]
///   - causeCode    [6 bits]
///   - result       [xlen bits]
///   - redirects    [1 bit]   (branch/jump that changes control flow)
///   - target       [xlen bits] (redirect target PC)
class RobEntry {
  final int xlen;
  final int physRegBits;

  const RobEntry({required this.xlen, this.physRegBits = 7});

  int get width =>
      xlen + physRegBits * 2 + 5 + 1 + 1 + 1 + 6 + xlen + 1 + xlen + 1 + 1 + 2;

  // Field offsets (packed LSB-first).
  int get pcStart => 0;
  int get pcEnd => xlen - 1;
  int get pdstStart => pcEnd + 1;
  int get pdstEnd => pdstStart + physRegBits - 1;
  int get pdstOldStart => pdstEnd + 1;
  int get pdstOldEnd => pdstOldStart + physRegBits - 1;
  int get rdStart => pdstOldEnd + 1;
  int get rdEnd => rdStart + 4;
  int get writesRdBit => rdEnd + 1;
  int get completeBit => writesRdBit + 1;
  int get exceptionBit => completeBit + 1;
  int get causeStart => exceptionBit + 1;
  int get causeEnd => causeStart + 5;
  int get resultStart => causeEnd + 1;
  int get resultEnd => resultStart + xlen - 1;
  int get redirectsBit => resultEnd + 1;
  int get targetStart => redirectsBit + 1;
  int get targetEnd => targetStart + xlen - 1;
  // Whether this entry is a store. The commit stage uses it to drain the
  // store-queue head in program order (only set when an LSQ is configured).
  int get isStoreBit => targetEnd + 1;
  // Whether this entry is a privileged return (mret/sret) and which level, so
  // the commit stage can restore pc/mode from {m,s}epc / {m,s}status.
  int get isReturnBit => isStoreBit + 1;
  int get returnLevelStart => isReturnBit + 1;
  int get returnLevelEnd => returnLevelStart + 1; // 2 bits
}

/// Reorder buffer for out-of-order commit.
///
/// Supports dual allocation (2 instructions per cycle) and dual commit.
/// The ROB is a circular buffer indexed by [head] and [tail] pointers.
class ReorderBuffer extends Module {
  /// Number of ROB entries (must be power of 2).
  final int depth;

  /// XLEN of the core.
  final int xlen;

  /// Physical register index width.
  final int physRegBits;

  late final RobEntry _entry;

  // -- Allocate outputs --

  /// Allocated ROB tag returned to rename stage.
  Logic get allocTag0 => output('alloc_tag_0');
  Logic get allocTag1 => output('alloc_tag_1');

  /// Whether allocation succeeded (ROB not full).
  Logic get allocReady => output('alloc_ready');

  // -- Commit outputs --

  /// Commit valid: head entry is complete and can retire.
  Logic get commitValid0 => output('commit_valid_0');
  Logic get commitValid1 => output('commit_valid_1');

  /// Committed entry data (for register file writeback / free list).
  Logic get commitPdst0 => output('commit_pdst_0');
  Logic get commitPdstOld0 => output('commit_pdst_old_0');
  Logic get commitRd0 => output('commit_rd_0');
  Logic get commitWritesRd0 => output('commit_writes_rd_0');
  Logic get commitResult0 => output('commit_result_0');
  Logic get commitException0 => output('commit_exception_0');

  /// Whether the committing head instruction redirects control flow (a taken
  /// branch or a jump), and its target PC. Set at completion via complete
  /// port 2 (the branch unit).
  Logic get commitRedirects0 => output('commit_redirects_0');
  Logic get commitTarget0 => output('commit_target_0');
  Logic get commitCause0 => output('commit_cause_0');
  Logic get commitPc0 => output('commit_pc_0');

  /// Whether the committing head instruction is a store (drives the store-queue
  /// drain at commit). Always 0 unless `allocIsStore0/1` are wired.
  Logic get commitIsStore0 => output('commit_is_store_0');
  Logic get commitIsStore1 => output('commit_is_store_1');

  /// Whether the committing entry is a privileged return (mret/sret), and its
  /// level (2-bit: matches RiscVMicroOp privilegeLevel, 3=M/1=S). Always 0
  /// unless `allocIsReturn0/1` are wired.
  Logic get commitIsReturn0 => output('commit_is_return_0');
  Logic get commitIsReturn1 => output('commit_is_return_1');
  Logic get commitReturnLevel0 => output('commit_return_level_0');
  Logic get commitReturnLevel1 => output('commit_return_level_1');

  Logic get commitPdst1 => output('commit_pdst_1');
  Logic get commitPdstOld1 => output('commit_pdst_old_1');
  Logic get commitRd1 => output('commit_rd_1');
  Logic get commitWritesRd1 => output('commit_writes_rd_1');
  Logic get commitResult1 => output('commit_result_1');
  Logic get commitException1 => output('commit_exception_1');
  Logic get commitCause1 => output('commit_cause_1');
  Logic get commitPc1 => output('commit_pc_1');

  // -- Status outputs --

  /// Whether the ROB is empty.
  Logic get empty => output('empty');

  /// The head (commit) pointer, including its wrap bit. Used by the load-store
  /// queues to order entries by program age (position from head).
  Logic get headPtr => output('head_ptr');

  /// Whether the ROB is full.
  Logic get full => output('full');

  ReorderBuffer(
    Logic clk,
    Logic reset, {
    required Logic allocValid0,
    required Logic allocPc0,
    required Logic allocPdst0,
    required Logic allocPdstOld0,
    required Logic allocRd0,
    required Logic allocWritesRd0,
    required Logic allocValid1,
    required Logic allocPc1,
    required Logic allocPdst1,
    required Logic allocPdstOld1,
    required Logic allocRd1,
    required Logic allocWritesRd1,
    // Per-slot store flag (optional; tied to 0 for non-LSQ configs).
    Logic? allocIsStore0,
    Logic? allocIsStore1,
    // Per-slot privileged-return flag + level (optional; tied to 0 otherwise).
    Logic? allocIsReturn0,
    Logic? allocIsReturn1,
    Logic? allocReturnLevel0,
    Logic? allocReturnLevel1,
    required Logic completeValid0,
    required Logic completeTag0,
    required Logic completeResult0,
    required Logic completeException0,
    required Logic completeCause0,
    required Logic completeValid1,
    required Logic completeTag1,
    required Logic completeResult1,
    required Logic completeException1,
    required Logic completeCause1,
    required Logic commitAck0,
    required Logic commitAck1,
    required Logic flush,
    // Complete port 2 (the branch unit): also carries the redirect bit + target
    // PC. Optional so existing instantiations are unaffected.
    Logic? completeValid2,
    Logic? completeTag2,
    Logic? completeResult2,
    Logic? completeException2,
    Logic? completeCause2,
    Logic? completeRedirects2,
    Logic? completeTarget2,
    // Optional redirect on complete port 0 (memory unit): a store→load ordering
    // violation redirects to re-fetch from after the store. Tied off otherwise.
    Logic? completeRedirects0,
    Logic? completeTarget0,
    this.depth = 64,
    this.xlen = 64,
    this.physRegBits = 7,
    super.name = 'reorder_buffer',
  }) : super(definitionName: 'ReorderBuffer') {
    _entry = RobEntry(xlen: xlen, physRegBits: physRegBits);
    final tagBits = _log2(depth);

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    // Allocate inputs
    allocValid0 = addInput('alloc_valid_0', allocValid0);
    allocValid1 = addInput('alloc_valid_1', allocValid1);

    // Allocate data inputs (from rename stage)
    allocPc0 = addInput('alloc_pc_0', allocPc0, width: xlen);
    allocPc1 = addInput('alloc_pc_1', allocPc1, width: xlen);
    allocPdst0 = addInput('alloc_pdst_0', allocPdst0, width: physRegBits);
    allocPdst1 = addInput('alloc_pdst_1', allocPdst1, width: physRegBits);
    allocPdstOld0 = addInput(
      'alloc_pdst_old_0',
      allocPdstOld0,
      width: physRegBits,
    );
    allocPdstOld1 = addInput(
      'alloc_pdst_old_1',
      allocPdstOld1,
      width: physRegBits,
    );
    allocRd0 = addInput('alloc_rd_0', allocRd0, width: 5);
    allocRd1 = addInput('alloc_rd_1', allocRd1, width: 5);
    allocWritesRd0 = addInput('alloc_writes_rd_0', allocWritesRd0);
    allocWritesRd1 = addInput('alloc_writes_rd_1', allocWritesRd1);
    final allocIsStore0In = addInput(
      'alloc_is_store_0',
      allocIsStore0 ?? Const(0),
    );
    final allocIsStore1In = addInput(
      'alloc_is_store_1',
      allocIsStore1 ?? Const(0),
    );
    final allocIsReturn0In = addInput(
      'alloc_is_return_0',
      allocIsReturn0 ?? Const(0),
    );
    final allocIsReturn1In = addInput(
      'alloc_is_return_1',
      allocIsReturn1 ?? Const(0),
    );
    final allocReturnLevel0In = addInput(
      'alloc_return_level_0',
      allocReturnLevel0 ?? Const(0, width: 2),
      width: 2,
    );
    final allocReturnLevel1In = addInput(
      'alloc_return_level_1',
      allocReturnLevel1 ?? Const(0, width: 2),
      width: 2,
    );

    // Allocate outputs
    addOutput('alloc_tag_0', width: tagBits);
    addOutput('alloc_tag_1', width: tagBits);
    addOutput('alloc_ready');

    // Complete inputs
    completeValid0 = addInput('complete_valid_0', completeValid0);
    completeTag0 = addInput('complete_tag_0', completeTag0, width: tagBits);
    completeResult0 = addInput(
      'complete_result_0',
      completeResult0,
      width: xlen,
    );
    completeException0 = addInput('complete_exception_0', completeException0);
    completeCause0 = addInput('complete_cause_0', completeCause0, width: 6);

    completeValid1 = addInput('complete_valid_1', completeValid1);
    completeTag1 = addInput('complete_tag_1', completeTag1, width: tagBits);
    completeResult1 = addInput(
      'complete_result_1',
      completeResult1,
      width: xlen,
    );
    completeException1 = addInput('complete_exception_1', completeException1);
    completeCause1 = addInput('complete_cause_1', completeCause1, width: 6);

    // Complete port 2 (branch unit): result + redirect/target. Tied off when
    // not provided.
    completeValid2 = addInput('complete_valid_2', completeValid2 ?? Const(0));
    completeTag2 = addInput(
      'complete_tag_2',
      completeTag2 ?? Const(0, width: tagBits),
      width: tagBits,
    );
    completeResult2 = addInput(
      'complete_result_2',
      completeResult2 ?? Const(0, width: xlen),
      width: xlen,
    );
    completeException2 = addInput(
      'complete_exception_2',
      completeException2 ?? Const(0),
    );
    completeCause2 = addInput(
      'complete_cause_2',
      completeCause2 ?? Const(0, width: 6),
      width: 6,
    );
    final completeRedirects0In = addInput(
      'complete_redirects_0',
      completeRedirects0 ?? Const(0),
    );
    final completeTarget0In = addInput(
      'complete_target_0',
      completeTarget0 ?? Const(0, width: xlen),
      width: xlen,
    );
    completeRedirects2 = addInput(
      'complete_redirects_2',
      completeRedirects2 ?? Const(0),
    );
    completeTarget2 = addInput(
      'complete_target_2',
      completeTarget2 ?? Const(0, width: xlen),
      width: xlen,
    );

    // Commit outputs
    addOutput('commit_valid_0');
    addOutput('commit_is_store_0');
    addOutput('commit_is_store_1');
    addOutput('commit_is_return_0');
    addOutput('commit_is_return_1');
    addOutput('commit_return_level_0', width: 2);
    addOutput('commit_return_level_1', width: 2);
    addOutput('commit_pdst_0', width: physRegBits);
    addOutput('commit_pdst_old_0', width: physRegBits);
    addOutput('commit_rd_0', width: 5);
    addOutput('commit_writes_rd_0');
    addOutput('commit_result_0', width: xlen);
    addOutput('commit_exception_0');
    addOutput('commit_cause_0', width: 6);
    addOutput('commit_pc_0', width: xlen);
    addOutput('commit_redirects_0');
    addOutput('commit_target_0', width: xlen);

    addOutput('commit_valid_1');
    addOutput('commit_pdst_1', width: physRegBits);
    addOutput('commit_pdst_old_1', width: physRegBits);
    addOutput('commit_rd_1', width: 5);
    addOutput('commit_writes_rd_1');
    addOutput('commit_result_1', width: xlen);
    addOutput('commit_exception_1');
    addOutput('commit_cause_1', width: 6);
    addOutput('commit_pc_1', width: xlen);

    commitAck0 = addInput('commit_ack_0', commitAck0);
    commitAck1 = addInput('commit_ack_1', commitAck1);

    // Flush
    flush = addInput('flush', flush);

    // Status
    addOutput('empty');
    addOutput('full');
    addOutput('head_ptr', width: tagBits + 1);

    // Internal state
    final head = Logic(name: 'head', width: tagBits + 1);
    final tail = Logic(name: 'tail', width: tagBits + 1);
    headPtr <= head;

    // Entry storage: array of packed entry words
    final entries = List.generate(
      depth,
      (i) => Logic(name: 'rob_entry_$i', width: _entry.width),
    );

    // Count logic
    final count = (tail - head).zeroExtend(tagBits + 1);
    final isFull = count.gte(Const(depth - 1, width: tagBits + 1));
    final isEmpty = head.eq(tail);

    empty <= isEmpty;
    full <= isFull;
    allocReady <= ~isFull;

    // Allocate tags are the current tail positions
    allocTag0 <= tail.slice(tagBits - 1, 0);
    allocTag1 <= (tail + 1).slice(tagBits - 1, 0);

    // Commit: expose head entries
    final headIdx = head.slice(tagBits - 1, 0);
    final headIdx1 = (head + 1).slice(tagBits - 1, 0);

    // Mux head entry fields for commit port 0
    final headEntry = _muxEntry(entries, headIdx, tagBits);
    _wireCommitPort(headEntry, '0');

    // Mux head+1 entry fields for commit port 1
    final headEntry1 = _muxEntry(entries, headIdx1, tagBits);
    _wireCommitPort(headEntry1, '1');

    // Head entry is committable when its complete bit is set
    commitValid0 <= headEntry[_entry.completeBit] & ~isEmpty;
    // Slot 1 may retire the next entry only when slot 0 is NOT a redirecting
    // branch: a taken branch at the head makes head+1 a wrong-path instruction,
    // which the redirect-flush will squash. Committing it through slot 1 in the
    // same cycle would wrongly retire the skipped instruction.
    commitValid1 <=
        headEntry1[_entry.completeBit] &
            headEntry[_entry.completeBit] &
            ~headEntry[_entry.redirectsBit] &
            ~isEmpty &
            ~head.eq(tail - 1);

    Sequential(clk, [
      If(
        reset | flush,
        then: [head < 0, tail < 0, ...entries.map((e) => e < 0)],
        orElse: [
          // Allocate: push new entries at tail
          If(
            allocValid0 & allocReady,
            then: [
              ..._packEntry(
                entries,
                tail.slice(tagBits - 1, 0),
                tagBits,
                pc: allocPc0,
                pdst: allocPdst0,
                pdstOld: allocPdstOld0,
                rd: allocRd0,
                writesRd: allocWritesRd0,
                isStore: allocIsStore0In,
                isReturn: allocIsReturn0In,
                returnLevel: allocReturnLevel0In,
              ),
              If(
                allocValid1,
                then: [
                  ..._packEntry(
                    entries,
                    (tail + 1).slice(tagBits - 1, 0),
                    tagBits,
                    pc: allocPc1,
                    pdst: allocPdst1,
                    pdstOld: allocPdstOld1,
                    rd: allocRd1,
                    writesRd: allocWritesRd1,
                    isStore: allocIsStore1In,
                    isReturn: allocIsReturn1In,
                    returnLevel: allocReturnLevel1In,
                  ),
                  tail < tail + 2,
                ],
                orElse: [tail < tail + 1],
              ),
            ],
          ),

          // Complete: mark entries as done, write result
          If(
            completeValid0,
            then: [
              ..._setComplete(
                entries,
                completeTag0,
                tagBits,
                result: completeResult0,
                exception: completeException0,
                cause: completeCause0,
                redirects: completeRedirects0In,
                target: completeTarget0In,
              ),
            ],
          ),
          If(
            completeValid1,
            then: [
              ..._setComplete(
                entries,
                completeTag1,
                tagBits,
                result: completeResult1,
                exception: completeException1,
                cause: completeCause1,
              ),
            ],
          ),
          // Complete port 2: the branch unit, which also records the redirect
          // bit and target PC so the redirect can be applied at commit.
          If(
            completeValid2,
            then: [
              ..._setComplete(
                entries,
                completeTag2,
                tagBits,
                result: completeResult2,
                exception: completeException2,
                cause: completeCause2,
                redirects: completeRedirects2,
                target: completeTarget2,
              ),
            ],
          ),

          // Commit: advance head
          If(
            commitAck0,
            then: [
              If(
                commitAck1,
                then: [head < head + 2],
                orElse: [head < head + 1],
              ),
            ],
          ),
        ],
      ),
    ]);
  }

  /// Mux an entry from the entries array by index.
  Logic _muxEntry(List<Logic> entries, Logic index, int tagBits) {
    Logic result = entries[0];
    for (var i = 1; i < entries.length; i++) {
      result = mux(index.eq(Const(i, width: tagBits)), entries[i], result);
    }
    return result;
  }

  /// Wire commit port outputs from a muxed entry.
  void _wireCommitPort(Logic entry, String suffix) {
    output('commit_pdst_$suffix') <=
        entry.slice(_entry.pdstEnd, _entry.pdstStart);
    output('commit_pdst_old_$suffix') <=
        entry.slice(_entry.pdstOldEnd, _entry.pdstOldStart);
    output('commit_rd_$suffix') <= entry.slice(_entry.rdEnd, _entry.rdStart);
    output('commit_writes_rd_$suffix') <= entry[_entry.writesRdBit];
    output('commit_result_$suffix') <=
        entry.slice(_entry.resultEnd, _entry.resultStart);
    output('commit_exception_$suffix') <= entry[_entry.exceptionBit];
    output('commit_cause_$suffix') <=
        entry.slice(_entry.causeEnd, _entry.causeStart);
    output('commit_pc_$suffix') <= entry.slice(_entry.pcEnd, _entry.pcStart);
    output('commit_is_store_$suffix') <= entry[_entry.isStoreBit];
    output('commit_is_return_$suffix') <= entry[_entry.isReturnBit];
    output('commit_return_level_$suffix') <=
        entry.slice(_entry.returnLevelEnd, _entry.returnLevelStart);
    // Redirect info is only consumed at the head (commit port 0).
    if (suffix == '0') {
      output('commit_redirects_0') <= entry[_entry.redirectsBit];
      output('commit_target_0') <=
          entry.slice(_entry.targetEnd, _entry.targetStart);
    }
  }

  /// Pack an entry into the entries array at the given index.
  List<Conditional> _packEntry(
    List<Logic> entries,
    Logic index,
    int tagBits, {
    required Logic pc,
    required Logic pdst,
    required Logic pdstOld,
    required Logic rd,
    required Logic writesRd,
    required Logic isStore,
    required Logic isReturn,
    required Logic returnLevel,
  }) {
    // Build packed entry value (MSB-first): returnLevel, isReturn, isStore,
    // redirects=0, target=0, complete=0, exception=0, cause=0, result=0.
    final packed = [
      returnLevel.zeroExtend(2), // returnLevel (MSB, 2 bits)
      isReturn.zeroExtend(1), // isReturn
      isStore.zeroExtend(1), // isStore
      Const(0, width: xlen), // target
      Const(0), // redirects
      Const(0, width: xlen), // result
      Const(0, width: 6), // cause
      Const(0), // exception
      Const(0), // complete
      writesRd.zeroExtend(1),
      rd.zeroExtend(5),
      pdstOld.zeroExtend(physRegBits),
      pdst.zeroExtend(physRegBits),
      pc.zeroExtend(xlen),
    ].swizzle();

    return [
      Case(index, [
        for (var i = 0; i < entries.length; i++)
          CaseItem(Const(i, width: tagBits), [entries[i] < packed]),
      ]),
    ];
  }

  /// Set the complete bit and write result/exception into an entry.
  List<Conditional> _setComplete(
    List<Logic> entries,
    Logic tag,
    int tagBits, {
    required Logic result,
    required Logic exception,
    required Logic cause,
    Logic? redirects,
    Logic? target,
  }) {
    return [
      Case(tag, [
        for (var i = 0; i < entries.length; i++)
          CaseItem(Const(i, width: tagBits), [
            // Set complete bit, exception, cause, result, and (for the branch
            // port) the redirect bit + target PC.
            entries[i] <
                entries[i]
                    .withSet(_entry.completeBit, Const(1))
                    .withSet(_entry.exceptionBit, exception)
                    .withSetRange(_entry.causeStart, _entry.causeEnd, cause)
                    .withSetRange(_entry.resultStart, _entry.resultEnd, result)
                    .withSet(_entry.redirectsBit, redirects ?? Const(0))
                    .withSetRange(
                      _entry.targetStart,
                      _entry.targetEnd,
                      target ?? Const(0, width: xlen),
                    ),
          ]),
      ]),
    ];
  }

  static int _log2(int n) {
    assert(n > 0 && (n & (n - 1)) == 0, 'depth must be power of 2');
    int r = 0;
    int v = n;
    while (v > 1) {
      v >>= 1;
      r++;
    }
    return r;
  }
}

/// Extension to set individual bits and ranges in a Logic value.
extension _LogicBitSet on Logic {
  /// Return a new Logic with bits [start..end] set to [value].
  Logic withSetRange(int start, int end, Logic value) {
    final rangeWidth = end - start + 1;
    // Use BigInt: for high fields (e.g. result at bits 60..91) the mask
    // `((1<<width)-1)<<start` overflows a 64-bit Dart int and silently
    // corrupts the field, which previously left committed results garbage.
    final mask = Const(
      ((BigInt.one << rangeWidth) - BigInt.one) << start,
      width: width,
    );
    final cleared = this & ~mask;
    final shifted = value.zeroExtend(width) << start;
    return cleared | (shifted & mask);
  }
}
