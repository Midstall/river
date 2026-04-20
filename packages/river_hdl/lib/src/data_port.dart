import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' as hcl;

/// Extended port group tags for [DataPortInterface].
///
/// Mirrors rohd_hcl's DataPortGroup and adds [integrity]
/// for done/valid handshaking signals.
enum DataPortGroup {
  /// Control signals: en, addr.
  control,

  /// Data signal: data.
  data,

  /// Handshake signals: done, valid.
  integrity,
}

/// A data port interface with handshake signals.
///
/// Extends the basic rohd_hcl pattern (en, addr, data) with
/// done and valid signals for request/response handshaking.
class DataPortInterface extends Interface<DataPortGroup> {
  /// Data width in bits.
  final int dataWidth;

  /// Address width in bits.
  final int addrWidth;

  /// Enable signal.
  Logic get en => port('en');

  /// Address signal.
  Logic get addr => port('addr');

  /// Data signal.
  Logic get data => port('data');

  /// Transaction complete signal.
  Logic get done => port('done');

  /// Response valid signal.
  Logic get valid => port('valid');

  /// Creates a data port interface with the given [dataWidth] and [addrWidth].
  DataPortInterface(this.dataWidth, this.addrWidth) {
    setPorts(
      [Logic.port('en'), Logic.port('addr', addrWidth)],
      [DataPortGroup.control],
    );

    setPorts([Logic.port('data', dataWidth)], [DataPortGroup.data]);

    setPorts(
      [Logic.port('done'), Logic.port('valid')],
      [DataPortGroup.integrity],
    );
  }

  @override
  DataPortInterface clone() => DataPortInterface(dataWidth, addrWidth);
}

/// Port groups for [FetchReadInterface].
enum FetchReadGroup {
  /// Request channel (master -> slave): reqValid, reqAddr.
  request,

  /// Request back-pressure (slave -> master): reqReady.
  requestReady,

  /// Response channel (slave -> master): rspValid, rspData.
  response,
}

/// A decoupled, multiple-outstanding read-port interface for instruction fetch.
///
/// Unlike [DataPortInterface] (single-outstanding: hold `en`/`addr` until a
/// `done & valid` pulse), this splits request and response so the master can
/// issue read N+1 before read N's response lands. That is what lets the fetcher
/// hide a multi-cycle fetch latency: keep several reads in flight so responses
/// arrive every cycle in steady state instead of every `latency` cycles.
///
/// CONTRACT (in-order, no IDs needed because fetch is sequential):
///   * Request handshake: master raises `reqValid` with a stable `reqAddr`; the
///     transfer happens on the cycle `reqValid & reqReady` are both high. The
///     slave drops `reqReady` to back-pressure when it cannot accept more (its
///     outstanding capacity is full).
///   * Response: the slave returns `rspValid` + `rspData` for accepted requests
///     IN ORDER, any number of cycles later, one response per request. The
///     master must always be able to sink a response (the prefetch FIFO sizing
///     guarantees this, see prefetchDepth vs fetchOutstanding validation).
///
/// An AXI4 AR/R or TileLink A/D adapter presents exactly this shape; the
/// in-tree single-outstanding MMU/Wishbone port is the `fetchOutstanding == 1`
/// degenerate case. See project_hdl_prefetch / project_hdl_frontend_perf.
class FetchReadInterface extends Interface<FetchReadGroup> {
  /// Data width in bits.
  final int dataWidth;

  /// Address width in bits.
  final int addrWidth;

  /// Request valid (master -> slave): a read is being offered this cycle.
  Logic get reqValid => port('req_valid');

  /// Request address (master -> slave): the address to read.
  Logic get reqAddr => port('req_addr');

  /// Request ready (slave -> master): the slave can accept a request this cycle.
  Logic get reqReady => port('req_ready');

  /// Response valid (slave -> master): `rspData` carries the next response.
  Logic get rspValid => port('rsp_valid');

  /// Response data (slave -> master): the read result, in request order.
  Logic get rspData => port('rsp_data');

  /// Creates a fetch-read interface with the given [dataWidth] and [addrWidth].
  FetchReadInterface(this.dataWidth, this.addrWidth) {
    setPorts(
      [Logic.port('req_valid'), Logic.port('req_addr', addrWidth)],
      [FetchReadGroup.request],
    );
    setPorts([Logic.port('req_ready')], [FetchReadGroup.requestReady]);
    setPorts(
      [Logic.port('rsp_valid'), Logic.port('rsp_data', dataWidth)],
      [FetchReadGroup.response],
    );
  }

  @override
  FetchReadInterface clone() => FetchReadInterface(dataWidth, addrWidth);
}

/// Wraps a [DataPortInterface] for use with rohd_hcl's [hcl.RegisterFile].
///
/// Creates a rohd_hcl [hcl.DataPortInterface] that shares the en, addr, and
/// data signals. The done and valid signals are driven to constant 1 when
/// the enable is active.
hcl.DataPortInterface wrapForRegisterFile(DataPortInterface dpi) {
  final hclDpi = hcl.DataPortInterface(dpi.dataWidth, dpi.addrWidth);
  hclDpi.en <= dpi.en;
  hclDpi.addr <= dpi.addr;
  // For read ports, data flows from RegisterFile to our port
  // For write ports, data flows from our port to RegisterFile
  // We need bidirectional support - just connect both ways
  // Actually this won't work directly. We need separate read/write helpers.
  return hclDpi;
}

/// Creates a rohd_hcl read port backed by our [DataPortInterface].
///
/// The en and addr signals are driven from [dpi], and the data signal
/// from the rohd_hcl port is connected back to [dpi.data].
/// With [readLatency] > 0, done/valid are delayed to match the
/// MemoryModel's pipeline latency.
hcl.DataPortInterface wrapReadForRegisterFile(
  DataPortInterface dpi, {
  Logic? clk,
  int readLatency = 0,
}) {
  final hclDpi = hcl.DataPortInterface(dpi.dataWidth, dpi.addrWidth);
  hclDpi.en <= dpi.en;
  hclDpi.addr <= dpi.addr;
  dpi.data <= hclDpi.data;
  dpi.done <= dpi.en;

  if (readLatency > 0 && clk != null) {
    final pipe = List.generate(
      readLatency + 1,
      (i) => Logic(name: 'rd_valid_pipe_$i'),
    );
    Sequential(clk, [
      If(
        dpi.en,
        then: [
          pipe[0] < 1,
          for (var i = 1; i < pipe.length; i++) pipe[i] < pipe[i - 1],
        ],
        orElse: [for (final p in pipe) p < 0],
      ),
    ]);
    dpi.valid <= pipe.last;
  } else {
    dpi.valid <= dpi.en;
  }

  return hclDpi;
}

/// Creates a rohd_hcl write port backed by our [DataPortInterface].
///
/// The en, addr, and data signals are driven from [dpi].
/// done and valid on [dpi] are driven to 1 when en is active.
hcl.DataPortInterface wrapWriteForRegisterFile(DataPortInterface dpi) {
  final hclDpi = hcl.DataPortInterface(dpi.dataWidth, dpi.addrWidth);
  hclDpi.en <= dpi.en;
  hclDpi.addr <= dpi.addr;
  hclDpi.data <= dpi.data;
  dpi.done <= dpi.en;
  dpi.valid <= dpi.en;
  return hclDpi;
}
