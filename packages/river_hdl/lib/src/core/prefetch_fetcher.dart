import 'package:rohd/rohd.dart';
import '../data_port.dart';

/// Pipelined prefetch fetcher (non-compressed): fetches AHEAD into a 2-deep
/// instruction FIFO so per-instruction fetch latency overlaps the downstream
/// decode/rename/alloc instead of serialising with it. Drop-in compatible with
/// [FetchUnit]'s outputs (done/valid/result/pcOut/compressed) and the
/// speculative controls (advance/redirect/redirectPc/stride).
///
/// READ-PORT CONTRACT (interconnect-NEUTRAL, this is the only thing the engine
/// assumes, so any interconnect adapter that honours it works: the in-tree
/// MMU/Wishbone fetch port does, and an AXI/TileLink adapter presenting the same
/// [DataPortInterface] would too):
///   * Request: drive `en` high with a stable `addr`; the read is single-
///     outstanding (one address in flight at a time).
///   * Response: the port asserts `done & valid` together for the data of the
///     CURRENT `addr`. The engine captures `data` the cycle it sees that, it
///     does NOT assume `valid` stays asserted (the real MMU pulses it for one
///     cycle; see mmu.dart). It also does NOT assume any particular latency: the
///     pulse may arrive any number of cycles after the request (back-pressure
///     while the bus is busy is fine, `en`/`addr` are simply held).
///   * Exactly one response per request; in order.
///   This is validated by the pulse-port portability tests (latency sweep +
///   redirect) in prefetch_fetcher_test.dart, independent of any interconnect.
///   (NOTE: rohd_hcl's wrapReadForRegisterFile drives `valid` as a level pipe
///   keyed to `en` continuity, which does NOT honour the contract above except
///   at latency 0, it is a test artifact, not a real interconnect.)
///
/// CORRECTNESS RULE (the trap the naive early-deliver fell into): never have
/// two bus reads overlapping. Exactly one read is issued at a time; its address
/// is held until the response is consumed, so the response always belongs to
/// the request, no mis-attribution. The prefetch win comes from doing the NEXT
/// read while the current instruction is held in the FIFO (overlapping the
/// consumer's latency), not from overlapping bus reads. On a redirect with a
/// read in flight, the stale response is drained (`discard`) before the
/// redirected read is issued, exactly like [FetchUnit]'s discardResp. See
/// project_hdl_prefetch.
///
/// NON-COMPRESSED, fixed `stride` (single-issue). Compressed and dual-issue
/// variable-stride support are later increments.
class PrefetchFetchUnit extends Module {
  /// Instruction-FIFO depth (power of two >= 2). Deeper buffers more fetched-
  /// ahead instructions, so it hides longer/burstier fetch stalls (e.g. icache
  /// line-fill misses), the consumer drains the buffer while the next line
  /// fills. Default 2 (prefetch-one-ahead).
  final int depth;

  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get compressed => output('compressed');
  Logic get result => output('result');
  Logic get pcOut => output('pc_out');

  PrefetchFetchUnit(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic pc,
    DataPortInterface memRead, {
    Logic? advance,
    Logic? redirect,
    Logic? redirectPc,
    Logic? stride,
    this.depth = 2,
    super.name = 'river_prefetch_fetch_unit',
  }) : super(definitionName: 'PrefetchFetchUnit') {
    assert(
      depth >= 2 && (depth & (depth - 1)) == 0,
      'prefetch FIFO depth must be a power of two >= 2 (got $depth)',
    );
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);
    final w = pc.width;
    pc = addInput('pc', pc, width: w);
    advance = addInput('advance', advance ?? Const(0));
    redirect = addInput('redirect', redirect ?? Const(0));
    redirectPc = addInput(
      'redirect_pc',
      redirectPc ?? Const(0, width: w),
      width: w,
    );

    memRead = memRead.clone()
      ..connectIO(
        this,
        memRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memRead_$og',
      );

    addOutput('done');
    addOutput('valid');
    addOutput('compressed');
    addOutput('result', width: 32);
    addOutput('pc_out', width: w);

    final dataW = memRead.data.width;
    final wordBytes = dataW ~/ 8;
    final instrPerWord = dataW ~/ 32; // 1 (32-bit mem) or 2 (64-bit mem)
    final alignMask = Const(~(wordBytes - 1), width: w);
    // The default self-sequencing step is one (non-compressed) instruction.
    final strideIn = stride != null
        ? addInput('stride', stride, width: w)
        : Const(4, width: w);

    // -- N-deep instruction FIFO (circular buffer). The head entry is delivered;
    //    `produce` pushes at the tail, `consume` pops the head. ----------------
    final ptrBits = (depth - 1).bitLength;
    final resArr = List.generate(
      depth,
      (i) => Logic(name: 'fifo_res_$i', width: 32),
    );
    final pcArr = List.generate(
      depth,
      (i) => Logic(name: 'fifo_pc_$i', width: w),
    );
    final head = Logic(name: 'fifo_head', width: ptrBits + 1);
    final tail = Logic(name: 'fifo_tail', width: ptrBits + 1);
    final headIdx = head.slice(ptrBits - 1, 0);
    final tailIdx = tail.slice(ptrBits - 1, 0);
    final fifoEmpty = head.eq(tail).named('fifoEmpty');
    final fifoFull = (headIdx.eq(tailIdx) & (head[ptrBits] ^ tail[ptrBits]))
        .named('fifoFull');
    Logic muxByIdx(List<Logic> arr, Logic idx) {
      Logic r = arr[0];
      for (var i = 1; i < depth; i++) {
        r = mux(idx.eq(Const(i, width: ptrBits)), arr[i], r);
      }
      return r;
    }

    final headRes = muxByIdx(resArr, headIdx).named('headRes');
    final headPc = muxByIdx(pcArr, headIdx).named('headPc');

    final fetchPc = Logic(
      name: 'fetch_pc',
      width: w,
    ); // PC of the in-flight read
    // Bus handshake, modelled on FetchUnit (proven against the real MMU/Wishbone
    // fetch port): hold `en` high continuously and keep `addr` stable until the
    // response (`done & valid`) lands; the bus drops `valid` on an address change
    // and re-asserts it when the new word is ready, so responses attribute to
    // their request without toggling `en`. `discard` drops the one stale response
    // that may still be in flight for the pre-redirect address (FetchUnit's
    // discardResp). See project_hdl_prefetch.
    final reading = Logic(name: 'reading'); // en held, a read is in flight
    final discard = Logic(name: 'discard'); // drop the next (stale) response
    final started = Logic(name: 'started'); // first real PC latched post-reset

    // Extract the 32-bit instruction at `fetchPc` from a memory word.
    Logic instrOf(Logic data) {
      if (instrPerWord == 1) return data.slice(31, 0);
      // 64-bit mem: select the 32-bit half by fetchPc[2].
      final chunks = [
        for (var i = 0; i < instrPerWord; i++) data.slice(32 * i + 31, 32 * i),
      ];
      final selBits = (instrPerWord - 1).bitLength; // 1 for 2/word
      final sel = fetchPc.slice(selBits + 1, 2);
      var r = chunks[0];
      for (var i = 1; i < instrPerWord; i++) {
        r = mux(sel.eq(i), chunks[i], r);
      }
      return r;
    }

    final readDone = (memRead.done & memRead.valid).named('readDone');
    final consume = (advance & ~fifoEmpty & enable & ~redirect).named(
      'consume',
    );
    // Room for a newly fetched instruction after this cycle's pop: the FIFO is
    // not full, or a consume frees a slot.
    final preRoom = (~fifoFull | consume).named('preRoom');
    // A genuine instruction arrived this cycle (not a stale/discarded response,
    // not redirecting) and there is room to buffer it.
    final produce =
        (reading & readDone & ~discard & ~redirect & enable & preRoom).named(
          'produce',
        );

    final fetched = instrOf(memRead.data).named('fetchedInstr');

    final nFetchPc = mux(
      produce,
      (fetchPc + strideIn),
      fetchPc,
    ).named('nFetchPc');

    // Outputs: deliver the FIFO head.
    done <= ~fifoEmpty & enable;
    valid <= ~fifoEmpty & enable;
    result <= headRes;
    pcOut <= headPc;
    compressed <= Const(0);

    Sequential(clk, [
      If(
        reset,
        then: [
          head < 0,
          tail < 0,
          // Initialise to 0 (not `pc`): currentPc may be X during reset, and
          // capturing it here would self-sequence X forever. The first real PC
          // is latched the first cycle after reset (see `started`), matching
          // FetchUnit which resets its addr/pcLatch to 0.
          fetchPc < 0,
          started < 0,
          reading < 0,
          discard < 0,
          memRead.en < 0,
          memRead.addr < 0,
        ],
        orElse: [
          If(
            ~enable,
            then: [reading < 0, discard < 0, memRead.en < 0],
            orElse: [
              If(
                redirect,
                then: [
                  // Squash the buffer and resteer. Hold en and point at
                  // redirectPc; a read for the pre-redirect address may still be
                  // in flight, so flag its one response for discard.
                  head < 0,
                  tail < 0,
                  fetchPc < redirectPc,
                  reading < 1,
                  discard < 1,
                  memRead.en < 1,
                  memRead.addr < (redirectPc & alignMask),
                ],
                orElse: [
                  // FIFO update: pop the head on consume, push the fetched word
                  // at the tail on produce (independent pointers).
                  If(consume, then: [head < head + 1]),
                  If(
                    produce,
                    then: [
                      for (var i = 0; i < depth; i++)
                        If(
                          tailIdx.eq(Const(i, width: ptrBits)),
                          then: [resArr[i] < fetched, pcArr[i] < fetchPc],
                        ),
                      tail < tail + 1,
                    ],
                  ),
                  reading < 1,
                  memRead.en < 1,
                  If(
                    ~started,
                    then: [
                      // First cycle after reset: latch the real start PC (now
                      // that currentPc is valid) and issue its read.
                      started < 1,
                      fetchPc < pc,
                      memRead.addr < (pc & alignMask),
                    ],
                    orElse: [
                      fetchPc < nFetchPc,
                      If(
                        discard,
                        then: [
                          // Drop the one stale (pre-redirect) response, then hold
                          // the redirected address for the real read.
                          discard < ~memRead.done,
                          memRead.addr < (fetchPc & alignMask),
                        ],
                        orElse: [
                          // On capture, advance to the next sequential read; else
                          // hold the current read address until its response lands.
                          memRead.addr < (nFetchPc & alignMask),
                        ],
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
