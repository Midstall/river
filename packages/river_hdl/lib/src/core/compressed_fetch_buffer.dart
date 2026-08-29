import 'package:rohd/rohd.dart';
import '../data_port.dart';
import 'instruction_aligner.dart';

/// Superscalar compressed (variable-length) fetch buffer.
///
/// Decouples word-granular memory fetch from instruction-granular dispatch so a
/// dual-issue front-end can extract TWO variable-length instructions per cycle.
/// Aligned words stream into a small word FIFO; a halfword offset (`headOff`)
/// tracks the current PC within the head word; a barrel-shifted 4-halfword
/// window feeds an [InstructionAligner] that resolves the two instructions'
/// boundaries. Dispatch consumes 1 or 2 instructions (`consume0`/`consume1`),
/// advancing headOff/head by their byte lengths. A redirect flushes the buffer
/// and restarts at any 2-byte-aligned PC (mid-word offsets supported).
///
/// This removes the classic dual-fetch `lane1.pc == lane0.pc + 4` assumption, so
/// RV64GC (compressed) can run dual-issue. The read engine is the held-`en`,
/// response-attributed single-outstanding handshake proven in
/// [PrefetchFetchUnit] (see project_hdl_prefetch / project_hdl_interconnect).
class CompressedFetchBuffer extends Module {
  Logic get instr0 => output('instr0');
  Logic get pc0 => output('pc0');
  Logic get valid0 => output('valid0');
  Logic get compressed0 => output('compressed0');
  Logic get instr1 => output('instr1');
  Logic get pc1 => output('pc1');
  Logic get valid1 => output('valid1');
  Logic get compressed1 => output('compressed1');

  /// Asserted with `valid0` when the head instruction could not be fetched
  /// because its translation faulted (the refill returned done AND not valid with
  /// `fault` set). The pipeline runs the slot as a bubble and the exec stage
  /// raises an instruction page fault at [pc0] instead of executing.
  Logic get fetchFault => output('fetch_fault');

  /// FIFO depth in words (power of two >= 4 so a 4-halfword window always spans
  /// available words even at 32-bit data width).
  final int depth;

  CompressedFetchBuffer(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic pc,
    DataPortInterface memRead, {
    Logic? redirect,
    Logic? redirectPc,
    Logic? consume0,
    Logic? consume1,
    Logic? fault,
    this.depth = 4,
    super.name = 'compressed_fetch_buffer',
  }) : super(definitionName: 'CompressedFetchBuffer') {
    assert(
      depth >= 4 && (depth & (depth - 1)) == 0,
      'word FIFO depth must be a power of two >= 4 (got $depth)',
    );
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);
    final w = pc.width;
    pc = addInput('pc', pc, width: w);
    redirect = addInput('redirect', redirect ?? Const(0));
    redirectPc = addInput(
      'redirect_pc',
      redirectPc ?? Const(0, width: w),
      width: w,
    );
    consume0 = addInput('consume0', consume0 ?? Const(0));
    consume1 = addInput('consume1', consume1 ?? Const(0));
    fault = addInput('fault', fault ?? Const(0));

    memRead = memRead.clone()
      ..connectIO(
        this,
        memRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memRead_$og',
      );

    addOutput('instr0', width: 32);
    addOutput('pc0', width: w);
    addOutput('valid0');
    addOutput('compressed0');
    addOutput('instr1', width: 32);
    addOutput('pc1', width: w);
    addOutput('valid1');
    addOutput('compressed1');
    addOutput('fetch_fault');

    final dataW = memRead.data.width;
    final wordBytes = dataW ~/ 8;
    final wordHalves = dataW ~/ 16; // halfwords per word
    final offW = (wordHalves - 1).bitLength; // headOff width
    final ptrBits = (depth - 1).bitLength;
    final alignMask = Const(~(wordBytes - 1), width: w);

    // -- Word FIFO ---------------------------------------------------------
    final wordArr = List.generate(
      depth,
      (i) => Logic(name: 'word_$i', width: dataW),
    );
    final head = Logic(name: 'head', width: ptrBits + 1);
    final tail = Logic(name: 'tail', width: ptrBits + 1);
    final headIdx = head.slice(ptrBits - 1, 0);
    final tailIdx = tail.slice(ptrBits - 1, 0);
    final wordCount = (tail - head).named('word_count'); // words buffered
    final fifoFull = (headIdx.eq(tailIdx) & (head[ptrBits] ^ tail[ptrBits]))
        .named('fifo_full');

    final headOff = Logic(name: 'head_off', width: offW); // halfword in head wd
    final headPc = Logic(name: 'head_pc', width: w); // PC of current head half
    final fetchPc = Logic(name: 'fetch_pc', width: w); // next word to read
    final reading = Logic(name: 'reading');
    final discard = Logic(name: 'discard');
    final started = Logic(name: 'started');
    // Held once the head-word fetch faults, until a redirect flushes the buffer
    // (the exec stage traps and resteers). While set the head slot is presented
    // as a valid bubble carrying fetch_fault.
    final faulted = Logic(name: 'faulted');

    Logic wordAtRel(int rel) {
      // wordArr[(head + rel) mod depth]
      final idx = (head + Const(rel, width: ptrBits + 1)).slice(ptrBits - 1, 0);
      Logic r = wordArr[0];
      for (var i = 1; i < depth; i++) {
        r = mux(idx.eq(Const(i, width: ptrBits)), wordArr[i], r);
      }
      return r;
    }

    // 4-halfword (64-bit) window starting at headOff. Concatenate the first
    // three buffered words (enough to cover headOff+4 halfwords at any width)
    // and barrel-shift right by headOff halfwords.
    final cat = [wordAtRel(2), wordAtRel(1), wordAtRel(0)].swizzle();
    // Shift right by headOff halfwords (headOff*16 bits).
    final shiftAmt = (headOff.zeroExtend(cat.width) << 4).named(
      'win_shift_amt',
    );
    final shifted = (cat >> shiftAmt).named('win_sh');
    final window = shifted.slice(63, 0).named('align_window');

    // Number of valid halfwords from headOff, capped at 4 (the window width).
    // headOff < wordHalves always, so with >= 1 buffered word the subtraction is
    // non-negative; with 0 words there are 0 valid halves (guard the underflow).
    // Zero-extend BEFORE multiplying: wordCount is only ptrBits+1 bits, so a full
    // FIFO (wordCount == depth) times wordHalves would overflow and truncate to 0
    // in wordCount's width, making a full buffer falsely read as empty.
    final log2WHb = (wordHalves - 1).bitLength;
    final totalHalves = (wordCount.zeroExtend(8) << log2WHb).named(
      'total_halves',
    );
    final availHalves = mux(
      wordCount.eq(0),
      Const(0, width: 8),
      totalHalves - headOff.zeroExtend(8),
    ).named('avail_halves');
    final validHalves = mux(
      availHalves.gt(4),
      Const(4, width: 3),
      availHalves.slice(2, 0),
    ).named('valid_halves');

    final aligner = InstructionAligner(window, validHalves, laneCount: 4);

    // A faulting head is a bubble: present a NOP (addi x0,x0,0) so the decoder
    // resolves cleanly in one cycle, valid0 high so it reaches exec, and
    // fetch_fault set so exec raises the instruction page fault at pc0 (headPc,
    // the faulting PC). No second lane on a fault.
    instr0 <= mux(faulted, Const(0x13, width: 32), aligner.instr0);
    pc0 <= headPc;
    valid0 <= (aligner.valid0 | faulted) & enable;
    compressed0 <= mux(faulted, Const(0), aligner.compressed0);
    instr1 <= aligner.instr1;
    // pc1 = headPc + size0*2.
    pc1 <= headPc + (aligner.size0.zeroExtend(w) << 1);
    valid1 <= aligner.valid1 & ~faulted & enable;
    compressed1 <= aligner.compressed1;
    fetchFault <= faulted & enable;

    // -- Consume / advance -------------------------------------------------
    final c0 = (consume0 & aligner.valid0 & enable & ~redirect).named('c0');
    final c1 = (c0 & consume1 & aligner.valid1).named('c1');
    // Halfwords consumed this cycle: size0 (if c0) + size1 (if c1).
    final consumed =
        (mux(c0, aligner.size0.zeroExtend(4), Const(0, width: 4)) +
                mux(c1, aligner.size1.zeroExtend(4), Const(0, width: 4)))
            .named('consumed_halves');
    // New absolute halfword index = headOff + consumed; split into word-advance
    // (>> log2 wordHalves) and new offset (& wordHalves-1). wordHalves is 2^k.
    final log2WH = (wordHalves - 1).bitLength;
    final newOffFull = (headOff.zeroExtend(4) + consumed).named('new_off_full');
    // Max wordsPopped = (maxHeadOff + maxConsumed)/wordHalves <= 2, so 2 bits.
    final wordsPopped = (newOffFull >> log2WH)
        .slice(1, 0)
        .named('words_popped');
    final newHeadOff = (newOffFull & Const(wordHalves - 1, width: 4)).named(
      'new_head_off',
    );

    // -- Read engine (fill the word FIFO; held-en, response-attributed) -----
    final readDone = (memRead.done & memRead.valid).named('read_done');
    // The head-word read faulted (done AND not valid with `fault` set) while the
    // FIFO is empty, so the faulting word IS the head instruction. Buffered valid
    // words ahead of it are consumed first; the read holds at the faulting word
    // (produce stays low) until the FIFO drains, then this catches.
    final faultCatch =
        (reading &
                memRead.done &
                ~memRead.valid &
                fault &
                ~discard &
                ~redirect &
                enable &
                wordCount.eq(0) &
                ~faulted)
            .named('fault_catch');
    final produce =
        (reading & readDone & ~discard & ~redirect & enable & ~fifoFull).named(
          'produce',
        );
    final nFetchPc = mux(
      produce,
      fetchPc + Const(wordBytes, width: w),
      fetchPc,
    ).named('n_fetch_pc');

    Sequential(clk, [
      If(
        reset,
        then: [
          head < 0,
          tail < 0,
          headOff < 0,
          headPc < 0,
          fetchPc < 0,
          reading < 0,
          discard < 0,
          started < 0,
          faulted < 0,
          memRead.en < 0,
          memRead.addr < 0,
        ],
        orElse: [
          If(
            ~enable,
            then: [reading < 0, discard < 0, faulted < 0, memRead.en < 0],
            orElse: [
              If(
                redirect,
                then: [
                  // Flush and resteer to redirectPc (any 2-byte alignment).
                  head < 0,
                  tail < 0,
                  headOff < redirectPc.slice(offW, 1),
                  headPc < redirectPc,
                  fetchPc < (redirectPc & alignMask),
                  reading < 1,
                  discard < 1, // drop the one stale in-flight word
                  faulted < 0, // the trap resteered; the fault is delivered
                  memRead.en < 1,
                  memRead.addr < (redirectPc & alignMask),
                ],
                orElse: [
                  // -- word FIFO push (produce) + pop (consume) --
                  If(
                    produce,
                    then: [
                      for (var i = 0; i < depth; i++)
                        If(
                          tailIdx.eq(Const(i, width: ptrBits)),
                          then: [wordArr[i] < memRead.data],
                        ),
                      tail < tail + 1,
                    ],
                  ),
                  head < head + wordsPopped.zeroExtend(ptrBits + 1),
                  headOff < newHeadOff.slice(offW - 1, 0),
                  headPc < headPc + (consumed.zeroExtend(w) << 1),
                  fetchPc < nFetchPc,
                  reading < 1,
                  // Latch a head-word fetch fault; held until a redirect flushes.
                  If(faultCatch, then: [faulted < 1]),
                  memRead.en < 1,
                  If(
                    ~started,
                    then: [
                      started < 1,
                      headOff < pc.slice(offW, 1),
                      headPc < pc,
                      fetchPc < (pc & alignMask),
                      memRead.addr < (pc & alignMask),
                    ],
                    orElse: [
                      If(
                        discard,
                        then: [
                          discard < ~memRead.done,
                          memRead.addr < (fetchPc & alignMask),
                        ],
                        orElse: [memRead.addr < (nFetchPc & alignMask)],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);
  }
}
