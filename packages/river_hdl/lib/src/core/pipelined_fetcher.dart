import 'package:rohd/rohd.dart';
import '../data_port.dart';

/// Multiple-outstanding prefetch fetcher (non-compressed). Unlike
/// [PrefetchFetchUnit] (single read in flight: hold `addr` until the response),
/// this keeps up to `maxOutstanding` reads in flight over a decoupled
/// [FetchReadInterface], so responses arrive every cycle in steady state instead
/// of every `latency` cycles. That is what hides a multi-cycle fetch latency:
/// the icache answers a hit combinationally, so pipelining the REQUESTS (issue
/// addr N+1 before N responds) delivers ~1 instr/cycle on hot code where the
/// single-outstanding engine sagged toward 1/latency.
///
/// Drop-in compatible OUTPUTS with [PrefetchFetchUnit]/[FetchUnit]
/// (done/valid/result/pcOut/compressed) and the same speculative controls
/// (advance/redirect/redirectPc/stride), so it slots into the same pipeline
/// hookup behind a config flag.
///
/// IN-ORDER design (fetch is sequential, so no response IDs needed):
///   * Request: drive `reqValid` with `reqAddr`; the issue lands on
///     `reqValid & reqReady`. We only raise `reqValid` when there is buffer room
///     for the eventual response, so a response can always be sunk.
///   * Response: `rspValid`/`rspData` come back IN ORDER, one per accepted
///     request. We track the in-flight request PCs in a small queue so each
///     response is paired with its PC (needed for the 64-bit-word half-select).
///   * Redirect: flush the instruction FIFO and the in-flight PC queue, then
///     DRAIN the responses still owed for the pre-redirect requests via a
///     `discard` counter (the multi-outstanding generalisation of
///     [PrefetchFetchUnit]'s single `discard` bit) before delivering the
///     resteered stream.
///
/// `maxOutstanding == 1` reduces this to the single-outstanding behaviour, so it
/// is a strict superset. See project_hdl_prefetch / project_hdl_frontend_perf.
class PipelinedFetchUnit extends Module {
  /// Instruction-FIFO depth (power of two). Must be >= `maxOutstanding + 1` so
  /// every in-flight response has a landing slot AND one entry can be delivered.
  final int depth;

  /// Maximum reads in flight (>= 1). Higher hides more fetch latency at the cost
  /// of a bigger in-flight PC queue. The `fetchOutstanding` config knob.
  final int maxOutstanding;

  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get compressed => output('compressed');
  Logic get result => output('result');
  Logic get pcOut => output('pc_out');

  PipelinedFetchUnit(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic pc,
    FetchReadInterface fetchRead, {
    Logic? advance,
    Logic? redirect,
    Logic? redirectPc,
    Logic? stride,
    this.depth = 4,
    this.maxOutstanding = 2,
    super.name = 'river_pipelined_fetch_unit',
  }) : super(definitionName: 'PipelinedFetchUnit') {
    assert(
      depth >= 2 && (depth & (depth - 1)) == 0,
      'instruction FIFO depth must be a power of two >= 2 (got $depth)',
    );
    assert(
      maxOutstanding >= 1,
      'maxOutstanding must be >= 1 (got $maxOutstanding)',
    );
    assert(
      depth >= maxOutstanding + 1,
      'depth ($depth) must be >= maxOutstanding + 1 ($maxOutstanding + 1)',
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

    fetchRead = fetchRead.clone()
      ..connectIO(
        this,
        fetchRead,
        // Master view: we drive the request, we read ready + response.
        outputTags: {FetchReadGroup.request},
        inputTags: {FetchReadGroup.requestReady, FetchReadGroup.response},
        uniquify: (og) => 'fetchRead_$og',
      );

    final dataW = fetchRead.dataWidth;
    final wordBytes = dataW ~/ 8;
    final instrPerWord = dataW ~/ 32;
    final alignMask = Const(~(wordBytes - 1), width: w);
    final strideIn = stride != null
        ? addInput('stride', stride, width: w)
        : Const(4, width: w);

    addOutput('done');
    addOutput('valid');
    addOutput('compressed');
    addOutput('result', width: 32);
    addOutput('pc_out', width: w);

    // ---- Generic power-of-two circular FIFO helpers -------------------------
    ({
      Logic head,
      Logic tail,
      Logic headIdx,
      Logic tailIdx,
      Logic empty,
      Logic full,
      Logic count,
      Logic Function(List<Logic>) headOf,
    })
    fifo(int d, String tag) {
      final pb = (d - 1).bitLength;
      final head = Logic(name: '${tag}_head', width: pb + 1);
      final tail = Logic(name: '${tag}_tail', width: pb + 1);
      final hi = head.slice(pb - 1, 0);
      final ti = tail.slice(pb - 1, 0);
      final empty = head.eq(tail).named('${tag}Empty');
      final full = (hi.eq(ti) & (head[pb] ^ tail[pb])).named('${tag}Full');
      final count = (tail - head).named('${tag}Count');
      Logic headOf(List<Logic> arr) {
        Logic r = arr[0];
        for (var i = 1; i < d; i++) {
          r = mux(hi.eq(Const(i, width: pb)), arr[i], r);
        }
        return r;
      }

      return (
        head: head,
        tail: tail,
        headIdx: hi,
        tailIdx: ti,
        empty: empty,
        full: full,
        count: count,
        headOf: headOf,
      );
    }

    // Instruction FIFO (delivered to the consumer): {result, pc}.
    final if_ = fifo(depth, 'ififo');
    final resArr = List.generate(
      depth,
      (i) => Logic(name: 'res_$i', width: 32),
    );
    final pcArr = List.generate(depth, (i) => Logic(name: 'ipc_$i', width: w));

    // In-flight request-PC queue: the PCs of accepted-but-unanswered requests,
    // so each in-order response can be paired with its PC.
    final reqQDepth =
        1 << (maxOutstanding).bitLength; // >= maxOutstanding+1 slots
    final rq = fifo(reqQDepth, 'reqq');
    final reqPcArr = List.generate(
      reqQDepth,
      (i) => Logic(name: 'reqpc_$i', width: w),
    );

    // Match the in-flight counter's pointer width so the redirect-drain
    // arithmetic (discard + inflight) needs no re-extension.
    final discardW = (reqQDepth - 1).bitLength + 1;
    final discard = Logic(name: 'discard', width: discardW);
    final started = Logic(name: 'started');
    final fetchPc = Logic(name: 'fetch_pc', width: w);

    // The PC of the request we would issue this cycle (pc until the first real
    // PC is latched, matching FetchUnit's reset-to-0 then latch-currentPc).
    final curReqPc = mux(started, fetchPc, pc).named('curReqPc');

    // Issue when there is room for the eventual response (in-flight + buffered
    // entries must not exceed depth) and we are under the outstanding cap.
    final inflight = rq.count.named('inflight');
    final room = (if_.count.zeroExtend(w) + inflight.zeroExtend(w))
        .lt(depth)
        .named('room');
    final underCap = inflight.lt(maxOutstanding).named('underCap');
    // reqValid must NOT depend on reqReady (avoids a valid<-ready combo loop).
    final wantIssue = (room & underCap & enable & ~redirect).named('wantIssue');
    final accept = (wantIssue & fetchRead.reqReady).named('accept');

    fetchRead.reqValid <= wantIssue;
    fetchRead.reqAddr <= (curReqPc & alignMask);

    // Response handling: in-order; drop while draining stale (pre-redirect) ones.
    final rsp = fetchRead.rspValid.named('rsp');
    final draining = discard.gt(0).named('draining');
    final realRsp = (rsp & ~draining).named('realRsp');
    final dropRsp = (rsp & draining).named('dropRsp');

    // Extract the 32-bit instruction at the head request PC from a memory word.
    // Latency-0 (combinational memory, e.g. an icache hit): the response lands
    // the same cycle its request is accepted, before the PC is registered into
    // the queue, so forward `curReqPc` when the queue is empty and an accept
    // coincides. For latency >= 1 the queue is non-empty on a response, so the
    // registered head PC is used.
    final rspPcRaw = rq.headOf(reqPcArr).named('rspPcRaw');
    final rspPc = mux(rq.empty & accept, curReqPc, rspPcRaw).named('rspPc');
    Logic instrOf(Logic data, Logic atPc) {
      if (instrPerWord == 1) return data.slice(31, 0);
      final chunks = [
        for (var i = 0; i < instrPerWord; i++) data.slice(32 * i + 31, 32 * i),
      ];
      final selBits = (instrPerWord - 1).bitLength;
      final sel = atPc.slice(selBits + 1, 2);
      var r = chunks[0];
      for (var i = 1; i < instrPerWord; i++) {
        r = mux(sel.eq(i), chunks[i], r);
      }
      return r;
    }

    final fetched = instrOf(fetchRead.rspData, rspPc).named('fetchedInstr');

    final consume = (advance & ~if_.empty & enable & ~redirect).named(
      'consume',
    );

    // Outputs: deliver the instruction FIFO head.
    done <= ~if_.empty & enable;
    valid <= ~if_.empty & enable;
    result <= if_.headOf(resArr);
    pcOut <= if_.headOf(pcArr);
    compressed <= Const(0);

    Sequential(clk, [
      If(
        reset,
        then: [
          if_.head < 0,
          if_.tail < 0,
          rq.head < 0,
          rq.tail < 0,
          discard < 0,
          started < 0,
          fetchPc < 0,
        ],
        orElse: [
          If(
            ~enable,
            then: [],
            orElse: [
              If(
                redirect,
                then: [
                  // Flush buffers and the in-flight PC queue; the responses owed
                  // for those in-flight requests must still be drained.
                  if_.head < 0,
                  if_.tail < 0,
                  rq.head < 0,
                  rq.tail < 0,
                  // Add the just-flushed in-flight requests to the drain count
                  // (a same-cycle response is consumed by the +1/-1 below).
                  discard < (discard + inflight - rsp.zeroExtend(discardW)),
                  started < 1,
                  fetchPc < redirectPc,
                ],
                orElse: [
                  started < 1,
                  // Drain a stale response if one arrived.
                  If(dropRsp, then: [discard < discard - 1]),
                  // Pop the instruction FIFO head on consume.
                  If(consume, then: [if_.head < if_.head + 1]),
                  // A real response lands: pop its PC, push the instruction.
                  If(
                    realRsp,
                    then: [
                      for (var i = 0; i < depth; i++)
                        If(
                          if_.tailIdx.eq(
                            Const(i, width: (depth - 1).bitLength),
                          ),
                          then: [resArr[i] < fetched, pcArr[i] < rspPc],
                        ),
                      if_.tail < if_.tail + 1,
                      rq.head < rq.head + 1,
                    ],
                  ),
                  // An accepted request: record its PC, bump the fetch PC.
                  If(
                    accept,
                    then: [
                      for (var i = 0; i < reqQDepth; i++)
                        If(
                          rq.tailIdx.eq(
                            Const(i, width: (reqQDepth - 1).bitLength),
                          ),
                          then: [reqPcArr[i] < curReqPc],
                        ),
                      rq.tail < rq.tail + 1,
                      fetchPc < (curReqPc + strideIn),
                    ],
                    orElse: [
                      // Latch the first real PC even if it was not accepted yet.
                      If(~started, then: [fetchPc < pc]),
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
