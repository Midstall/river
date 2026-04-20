import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' as hcl;
import '../data_port.dart';

/// Synthesizable multiple-outstanding instruction memory presenting a
/// [FetchReadInterface] slave. Storage is a rohd_hcl [hcl.RegisterFile] (the
/// library handles address decode, so there is no hand-rolled per-entry mux),
/// ROM-initialised via `resetValue` so every word is defined (never X, a fast
/// fetcher speculatively reads past the program, and an X there would poison the
/// core). A registered-read pipeline of depth [readLatency] models a fixed-
/// latency on-chip RAM and makes the port multiple-outstanding (a new read
/// accepted every cycle, responses in order `readLatency` cycles later).
///
/// NOTE: a RegisterFile is flip-flop storage with a combinational read; it is
/// not a dedicated BRAM block (which needs a vendor macro with registered read
/// and init-file contents). This module is the sim/benchmark + simple-TCM model.
/// The real River core EXPOSES the [FetchReadInterface] port; a SoC attaches its
/// own memory (vendor BRAM, DRAM controller, AXI-read bridge). See
/// project_hdl_prefetch / project_hdl_frontend_perf.
class PipelinedFetchMemory extends Module {
  /// Number of words of storage (each `dataWidth` bits). Power of two.
  final int words;

  /// Registered-read latency in cycles (>= 1). 1 models a standard BRAM.
  final int readLatency;

  PipelinedFetchMemory(
    Logic clk,
    Logic reset,
    FetchReadInterface port, {
    Logic? writeEn,
    Logic? writeAddr,
    Logic? writeData,
    List<int> initWords = const [],
    this.words = 4096,
    this.readLatency = 1,
    super.name = 'river_pipelined_fetch_memory',
  }) : super(definitionName: 'PipelinedFetchMemory') {
    assert(
      words >= 2 && (words & (words - 1)) == 0,
      'words must be a power of two >= 2 (got $words)',
    );
    assert(readLatency >= 1, 'readLatency must be >= 1 (got $readLatency)');

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final aw = port.addrWidth;
    final dw = port.dataWidth;
    final byteShift = (dw ~/ 8).bitLength - 1; // 2 for 32-bit, 3 for 64-bit
    final idxBits = (words - 1).bitLength;

    port = port.clone()
      ..connectIO(
        this,
        port,
        inputTags: {FetchReadGroup.request},
        outputTags: {FetchReadGroup.requestReady, FetchReadGroup.response},
        uniquify: (og) => 'port_$og',
      );
    writeEn = addInput('write_en', writeEn ?? Const(0));
    writeAddr = addInput(
      'write_addr',
      writeAddr ?? Const(0, width: aw),
      width: aw,
    );
    writeData = addInput(
      'write_data',
      writeData ?? Const(0, width: dw),
      width: dw,
    );

    Logic wordIndex(Logic addr) =>
        addr.slice(idxBits + byteShift - 1, byteShift);

    // ROM-initialised register file: address decode handled by the library; the
    // resetValue map loads the program (every other entry defaults to 0).
    final wrPort = hcl.DataPortInterface(dw, idxBits);
    wrPort.en <= writeEn;
    wrPort.addr <= wordIndex(writeAddr);
    wrPort.data <= writeData;
    final rdPort = hcl.DataPortInterface(dw, idxBits);
    rdPort.en <= Const(1); // BRAM reads every cycle
    rdPort.addr <= wordIndex(port.reqAddr);
    hcl.RegisterFile(
      clk,
      reset,
      [wrPort],
      [rdPort],
      numEntries: words,
      resetValue: {for (var i = 0; i < initWords.length; i++) i: initWords[i]},
    );
    final rdData = rdPort.data.named('rdData'); // combinational read

    // BRAM accepts one read per cycle; reqReady always high.
    port.reqReady <= Const(1);
    final accept = port.reqValid.named('accept');

    // Registered-read pipeline: shift {valid, data} `readLatency` cycles so the
    // response lands aligned to its data, in order, multiple-outstanding.
    final validPipe = List.generate(readLatency, (i) => Logic(name: 'rv_$i'));
    final dataPipe = List.generate(
      readLatency,
      (i) => Logic(name: 'rd_$i', width: dw),
    );
    port.rspValid <= validPipe[readLatency - 1];
    port.rspData <= dataPipe[readLatency - 1];

    Sequential(clk, [
      If(
        reset,
        then: [for (final v in validPipe) v < 0],
        orElse: [
          validPipe[0] < accept,
          dataPipe[0] < rdData,
          for (var i = 1; i < readLatency; i++) ...[
            validPipe[i] < validPipe[i - 1],
            dataPipe[i] < dataPipe[i - 1],
          ],
        ],
      ),
    ]);
  }
}
