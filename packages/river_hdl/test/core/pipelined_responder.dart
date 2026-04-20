import 'package:rohd/rohd.dart';
import 'package:river_hdl/river_hdl.dart';

/// Behavioral pipelined memory that honours [FetchReadInterface] from the SLAVE
/// side: fixed `latency`-cycle, in-order reads with up to `maxOutstanding`
/// requests in flight. This is the representative multiple-outstanding read port
/// the single-outstanding test models could not provide, so the multi-outstanding
/// fetch engine can be exercised against a real pipelined memory.
///
/// `mem` maps byte address -> 32-bit word; unmapped reads return 0. Responses
/// come back exactly `latency` cycles after acceptance, one per accepted request,
/// in order. `reqReady` deasserts while `maxOutstanding` requests are in flight,
/// which is how back-pressure is exercised (set `maxOutstanding < latency`).
class PipelinedReadResponder extends Module {
  PipelinedReadResponder(
    Logic clk,
    Logic reset,
    FetchReadInterface port,
    Map<int, int> mem, {
    int latency = 4,
    int maxOutstanding = 8,
    super.name = 'pipelined_read_responder',
  }) : super(definitionName: 'PipelinedReadResponder') {
    assert(latency >= 0, 'latency must be >= 0');
    assert(maxOutstanding >= 1, 'maxOutstanding must be >= 1');
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final aw = port.addrWidth;
    final dw = port.dataWidth;

    port = port.clone()
      ..connectIO(
        this,
        port,
        // Slave view: request is an input; ready + response are outputs.
        inputTags: {FetchReadGroup.request},
        outputTags: {FetchReadGroup.requestReady, FetchReadGroup.response},
        uniquify: (og) => 'port_$og',
      );

    Logic wordOf(Logic addr) {
      Logic r = Const(0, width: dw);
      for (final e in mem.entries) {
        r = mux(addr.eq(Const(e.key, width: aw)), Const(e.value, width: dw), r);
      }
      return r;
    }

    final cntW = (maxOutstanding + 2).bitLength;
    final inflight = Logic(name: 'inflight', width: cntW);
    final reqReady = inflight.lt(maxOutstanding).named('reqReadyInt');
    final accept = (port.reqValid & reqReady).named('accept');
    port.reqReady <= reqReady;

    if (latency == 0) {
      // Same-cycle response: nothing is ever in flight.
      port.rspValid <= accept;
      port.rspData <= wordOf(port.reqAddr);
      Sequential(clk, [inflight < 0]);
    } else {
      final validPipe = List.generate(latency, (i) => Logic(name: 'vp_$i'));
      final addrPipe = List.generate(
        latency,
        (i) => Logic(name: 'ap_$i', width: aw),
      );
      final retire = validPipe[latency - 1];
      port.rspValid <= retire;
      port.rspData <= wordOf(addrPipe[latency - 1]);

      Sequential(clk, [
        If(
          reset,
          then: [
            inflight < 0,
            for (final v in validPipe) v < 0,
            for (final a in addrPipe) a < 0,
          ],
          orElse: [
            // Shift the {valid, addr} pipe; inject the accepted request at stage 0.
            validPipe[0] < accept,
            addrPipe[0] < port.reqAddr,
            for (var i = 1; i < latency; i++) ...[
              validPipe[i] < validPipe[i - 1],
              addrPipe[i] < addrPipe[i - 1],
            ],
            // One accept enters, one retire leaves: net update the counter.
            inflight <
                (inflight + accept.zeroExtend(cntW) - retire.zeroExtend(cntW)),
          ],
        ),
      ]);
    }
  }
}
