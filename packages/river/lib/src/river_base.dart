import 'package:harbor/harbor.dart';

enum IcsVersion { v1 }

enum RiverCoreType {
  mcu(hasCsrs: true),
  general(hasCsrs: true);

  const RiverCoreType({required this.hasCsrs});

  final bool hasCsrs;
}

enum MicrocodePipelineMode { inParallel, standalone, none }

enum MicrocodeMode {
  none(),
  parallelDecode(
    onDecoder: MicrocodePipelineMode.inParallel,
    onExec: MicrocodePipelineMode.standalone,
  ),
  parallelExec(
    onDecoder: MicrocodePipelineMode.standalone,
    onExec: MicrocodePipelineMode.inParallel,
  ),
  fullParallel(
    onDecoder: MicrocodePipelineMode.inParallel,
    onExec: MicrocodePipelineMode.inParallel,
  ),
  full(
    onDecoder: MicrocodePipelineMode.standalone,
    onExec: MicrocodePipelineMode.standalone,
  );

  const MicrocodeMode({
    this.onDecoder = MicrocodePipelineMode.none,
    this.onExec = MicrocodePipelineMode.none,
  });

  final MicrocodePipelineMode onDecoder;
  final MicrocodePipelineMode onExec;
}

enum ExecutionMode { inOrder, outOfOrder }

/// Number of instructions the front-end issues per cycle. `dual` requires
/// [ExecutionMode.outOfOrder]: only the OoO backend's ROB and issue queue are
/// built 2-wide.
enum IssueWidth {
  single(1),
  dual(2);

  final int lanes;
  const IssueWidth(this.lanes);
}

/// Branch-prediction scheme for the speculative OoO front-end. A predicted-taken
/// branch redirects fetch at rename, so only a misprediction (caught at execute)
/// flushes. `none` is the baseline: predict not-taken, redirect at commit.
enum BranchPredictor {
  /// No prediction: every taken branch/jump redirects at commit (a full flush).
  none,

  /// Static backward-taken / forward-not-taken: conditional branches with a
  /// negative displacement (loop back-edges) are predicted taken; forward ones
  /// not-taken. JAL is always taken. No stored state. Cheap, good for loops.
  btfn,

  /// Bimodal: a table of 2-bit saturating counters indexed by branch PC,
  /// updated at branch resolution. Learns per-branch bias.
  bimodal,
}

/// Load-store queue scheme for the OoO core. `none` writes stores to the bus at
/// execute (out of program order, a memory-ordering gap). Each non-`none` level
/// buffers stores and drains them in program order at commit, adding more
/// aggressive load handling on top.
enum LoadStoreQueue {
  /// No queue: a store drives the bus as soon as it issues from the IQ (current
  /// behavior, kept for back-compat). Loads read the bus directly.
  none,

  /// Buffer stores; the architectural write happens at commit, in program order.
  /// A load that has any older store still in flight stalls until it drains, no
  /// forwarding. Fixes store ordering with the least machinery.
  storeQueue,

  /// As [storeQueue], plus store→load forwarding: a load takes its value from the
  /// youngest older store to the same address when that store's data is ready.
  /// Loads issue conservatively, they stall only when an older store's address
  /// is still unknown (can't be disambiguated), never speculating past it.
  forwarding,

  /// As [forwarding], but loads issue speculatively even past unknown-address
  /// stores. A load queue records executed loads; when an older store later
  /// resolves its address and aliases a younger already-executed load, that load
  /// (and everything younger) is squashed and replayed via the ROB redirect path.
  speculative,
}

enum PrivilegeMode {
  machine(3),
  supervisor(1),
  user(0);

  const PrivilegeMode(this.id);

  final int id;

  static PrivilegeMode? find(int id) {
    for (final mode in PrivilegeMode.values) {
      if (mode.id == id) return mode;
    }
    return null;
  }
}

enum Trap {
  instructionMisaligned(0, false),
  instructionAccessFault(1, false),
  illegal(2, false),
  breakpoint(3, false),
  misalignedLoad(4, false),
  loadAccess(5, false),
  misalignedStore(6, false),
  storeAccess(7, false),
  ecallU(8, false),
  ecallS(9, false),
  ecallVS(10, false),
  ecallM(11, false),
  instructionPageFault(12, false),
  loadPageFault(13, false),
  storePageFault(15, false),
  // Hypervisor (H) extension synchronous causes.
  instructionGuestPageFault(20, false),
  loadGuestPageFault(21, false),
  virtualInstruction(22, false),
  storeGuestPageFault(23, false),
  userSoftware(0, true),
  supervisorSoftware(1, true),
  machineSoftware(3, true),
  userTimer(4, true),
  supervisorTimer(5, true),
  machineTimer(7, true),
  userExternal(8, true),
  supervisorExternal(9, true),
  machineExternal(11, true);

  final int causeCode;
  final bool interrupt;

  const Trap(this.causeCode, this.interrupt);

  int cause(int xlen) => (interrupt ? (1 << (xlen - 1)) : 0) | causeCode;
}

class InterruptLine {
  final int irq;
  final String source;
  final String target;

  const InterruptLine({
    required this.irq,
    required this.source,
    required this.target,
  });

  @override
  String toString() =>
      'InterruptLine(irq: $irq, source: $source, target: $target)';
}

class InterruptController {
  final String name;
  final int baseAddr;
  final List<InterruptLine> lines;

  const InterruptController({
    required this.name,
    required this.baseAddr,
    required this.lines,
  });

  @override
  String toString() =>
      'InterruptController(name: $name, baseAddr: $baseAddr, lines: $lines)';
}

/// River's allocated RISC-V architecture ID (`marchid`), from the official
/// registry: https://github.com/riscv/riscv-isa-manual/blob/main/marchid.md
/// (River, entry 49). This is the default [RiverCoreConfig.archId].
const int riverArchId = 49;

class RiverCoreConfig {
  final int vendorId;

  /// RISC-V `marchid` value. Defaults to [riverArchId] (River's registered
  /// architecture ID); override only for a non-River derivative.
  final int archId;
  final int impId;
  final int hartId;
  final int resetVector;
  final RiscVMxlen mxlen;
  final HarborClockConfig clock;
  final List<RiscVExtension> extensions;
  final List<InterruptController> interrupts;
  final HarborMmuConfig mmu;
  final MicrocodeMode microcodeMode;

  /// Number of microcode-decode LANES: how many decode-pattern ROM entries the
  /// dynamic decoder reads + compares against the instruction PER CYCLE. The
  /// decoder's pattern search is O(patterns/lanes) cycles, so `lanes` trades a
  /// few comparators of area for a proportionally shorter decode (the pattern
  /// scan is the dominant per-instruction cost on the microcode datapath). 1 =
  /// the plain one-per-cycle linear scan. Larger cores set more lanes; the ROM
  /// stays ROM-driven and runtime-patchable either way. No effect unless
  /// [microcodeMode] uses a standalone (ROM-scanning) decoder.
  final int microcodeDecodeLanes;

  final ExecutionMode executionMode;
  final IssueWidth issueWidth;

  /// Number of instructions retired (committed) per cycle. Independent of
  /// [issueWidth] so a config can enable dual-commit (a second register write
  /// port draining backlog after a multi-cycle op) without dual-dispatch, or
  /// vice versa. Defaults to [issueWidth]. Dual commit requires OoO.
  final IssueWidth commitWidth;

  /// Depth of the per-bank register-file write buffer. 0 (the default) means no
  /// buffer: a same-bank commit collision stalls the younger write one cycle.
  /// A depth >0 absorbs collisions into a FIFO (drained one/cycle, with read
  /// bypass) so commit doesn't stall until the buffer fills. Only meaningful
  /// when [commitWidth] is dual (a single write port never collides).
  final int writeBufferDepth;

  /// Register-file read latency in cycles, or null to derive from the target
  /// (1 for an ECP5 posedge-EBR build, 0 otherwise). A registered full-cycle
  /// read keeps the regfile off the combinational ALU path so timing closes on
  /// FPGAs with block-RAM register files, at the cost of one cycle per operand
  /// read (the operand-read handshake absorbs it). Set explicitly to exercise
  /// the +1 read pipeline in simulation with the flop register file (the EBR is
  /// a blackbox with no sim model).
  final int? regfileReadLatency;

  /// Whether the OoO front-end fetches speculatively. False (default) is
  /// lockstep: the fetch PC advances only at commit, one instruction in flight
  /// end-to-end (no overlap, dual-issue cannot fire). True advances fetch every
  /// cycle, with ROB/IQ overlap and branch/exception redirect + flush. Requires
  /// the OoO backend.
  final bool speculativeFetch;

  /// Use the pipelined PREFETCH fetcher: fetches one instruction ahead into a
  /// buffer so fetch latency overlaps decode/rename/alloc. Single-issue,
  /// non-compressed, speculative OoO only for now. Default false (classic
  /// FetchUnit).
  final bool prefetchFetch;

  /// Prefetch instruction-FIFO depth (power of two >= 2). A deeper buffer hides
  /// longer/burstier fetch stalls (e.g. icache line-fill misses): the consumer
  /// drains the buffer while the next line fills. Only meaningful with
  /// prefetchFetch=true. Default 2 (prefetch-one-ahead).
  final int prefetchDepth;

  /// Maximum instruction-fetch reads kept in flight at once (>= 1). Hides fetch
  /// latency: responses arrive every cycle in steady state instead of every
  /// `latency` cycles, keeping the prefetch FIFO full. 1 (default) is classic
  /// single-outstanding. Only meaningful with prefetchFetch=true, and only speeds
  /// up when the downstream fetch port services multiple outstanding reads.
  final int fetchOutstanding;

  /// Branch-prediction scheme (speculative OoO front-end only). Cuts the
  /// per-branch redirect/flush penalty to just mispredictions.
  final BranchPredictor branchPredictor;

  /// Load-store queue scheme (OoO only). `none` (default) keeps the legacy
  /// store-at-execute path; the other levels buffer stores and drain them in
  /// program order at commit. See [LoadStoreQueue].
  final LoadStoreQueue loadStoreQueue;

  /// Reorder-buffer depth (entries). Must be a power of two. Defaults to 64.
  final int robDepth;

  /// Store-queue depth (entries), used when [loadStoreQueue] != none. Must be a
  /// power of two. Defaults to 8.
  final int storeQueueDepth;

  /// Load-queue depth (entries), used when [loadStoreQueue] == speculative. Must
  /// be a power of two. Defaults to 8.
  final int loadQueueDepth;

  final HarborL1CacheConfig? l1cache;
  final bool hasSupervisor;
  final bool hasUser;
  final RiverCoreType type;
  final IcsVersion? icsVersion;
  final int threads;

  /// Vector register width in bits (the V extension's VLEN). Only meaningful
  /// when the V extension is present; 128 is the RVA23 minimum.
  final int vlen;

  RiverCoreConfig({
    this.vendorId = 0,
    this.archId = riverArchId,
    this.impId = 0,
    this.hartId = 0,
    this.resetVector = 0,
    required this.clock,
    required this.mxlen,
    required this.extensions,
    required this.interrupts,
    required this.mmu,
    this.microcodeMode = MicrocodeMode.none,
    this.microcodeDecodeLanes = 1,
    this.executionMode = ExecutionMode.inOrder,
    this.issueWidth = IssueWidth.single,
    IssueWidth? commitWidth,
    this.writeBufferDepth = 0,
    this.regfileReadLatency,
    this.speculativeFetch = false,
    this.prefetchFetch = false,
    this.prefetchDepth = 2,
    this.fetchOutstanding = 1,
    this.branchPredictor = BranchPredictor.none,
    this.loadStoreQueue = LoadStoreQueue.none,
    this.robDepth = 64,
    this.storeQueueDepth = 8,
    this.loadQueueDepth = 8,
    this.l1cache,
    this.hasSupervisor = true,
    this.hasUser = true,
    required this.type,
    this.icsVersion,
    this.threads = 1,
    this.vlen = 128,
  }) : commitWidth = commitWidth ?? issueWidth {
    // VLEN must be a power of two and at least 128 (the RVA23 minimum) so that
    // configs always produce spec builds.
    if (vlen < 128 || (vlen & (vlen - 1)) != 0) {
      throw ArgumentError('vlen must be a power of two >= 128 (got $vlen).');
    }
    // Dual-issue requires the OoO backend (only the ROB / issue queue are
    // built 2-wide). An in-order dual-issue front-end is not supported.
    if (issueWidth == IssueWidth.dual &&
        executionMode != ExecutionMode.outOfOrder) {
      throw ArgumentError(
        'issueWidth=$issueWidth requires executionMode=outOfOrder '
        '(got executionMode=$executionMode).',
      );
    }
    // Dual-DISPATCH (two fetch/decode/rename lanes) needs the speculative
    // front-end (lane coordination relies on self-sequencing fetch + redirect).
    // Compressed instructions are supported: CompressedFetchBuffer aligns the
    // two lanes from one stream window (lane 1 at lane 0 + size0, not fixed +4).
    if (issueWidth == IssueWidth.dual && !speculativeFetch) {
      throw ArgumentError('issueWidth=dual requires speculativeFetch=true.');
    }
    // Branch prediction redirects the fetch stream speculatively, which only the
    // speculative OoO front-end supports.
    if (branchPredictor != BranchPredictor.none && !speculativeFetch) {
      throw ArgumentError(
        'branchPredictor=$branchPredictor requires speculativeFetch=true.',
      );
    }
    // The load-store queue (buffering stores until commit, forwarding, replay)
    // is built only on the OoO backend, and only the speculative front-end has
    // out-of-order memory to manage, lockstep executes one memory op at a time,
    // already in program order.
    if (loadStoreQueue != LoadStoreQueue.none &&
        executionMode != ExecutionMode.outOfOrder) {
      throw ArgumentError(
        'loadStoreQueue=$loadStoreQueue requires executionMode=outOfOrder '
        '(got executionMode=$executionMode).',
      );
    }
    if (loadStoreQueue != LoadStoreQueue.none && !speculativeFetch) {
      throw ArgumentError(
        'loadStoreQueue=$loadStoreQueue requires speculativeFetch=true.',
      );
    }
    // The prefetch fetcher self-sequences (needs the speculative front-end) and
    // currently supports only single-issue, fixed-width (non-compressed) fetch.
    if (prefetchFetch && !speculativeFetch) {
      throw ArgumentError('prefetchFetch=true requires speculativeFetch=true.');
    }
    if (prefetchFetch && issueWidth == IssueWidth.dual) {
      throw ArgumentError(
        'prefetchFetch=true does not yet support issueWidth=dual.',
      );
    }
    if (prefetchFetch && extensions.any((e) => e.name == 'C')) {
      throw ArgumentError(
        'prefetchFetch=true does not yet support the compressed (C) extension.',
      );
    }
    if (prefetchDepth < 2 || (prefetchDepth & (prefetchDepth - 1)) != 0) {
      throw ArgumentError(
        'prefetchDepth must be a power of two >= 2 (got $prefetchDepth).',
      );
    }
    if (fetchOutstanding < 1) {
      throw ArgumentError(
        'fetchOutstanding must be >= 1 (got $fetchOutstanding).',
      );
    }
    if (fetchOutstanding > 1 && !prefetchFetch) {
      throw ArgumentError('fetchOutstanding > 1 requires prefetchFetch=true.');
    }
    // The prefetch FIFO must hold every in-flight response plus one delivered
    // entry, so it cannot be smaller than fetchOutstanding + 1.
    if (fetchOutstanding > 1 && prefetchDepth < fetchOutstanding + 1) {
      throw ArgumentError(
        'prefetchDepth ($prefetchDepth) must be >= fetchOutstanding + 1 '
        '(${fetchOutstanding + 1}) when fetchOutstanding > 1, so every '
        'outstanding response can be buffered.',
      );
    }
    // Queue depths must be powers of two (the head/tail pointers wrap with a
    // simple mask).
    if (robDepth < 2 || (robDepth & (robDepth - 1)) != 0) {
      throw ArgumentError(
        'robDepth must be a power of two >= 2 (got $robDepth).',
      );
    }
    if (storeQueueDepth < 2 || (storeQueueDepth & (storeQueueDepth - 1)) != 0) {
      throw ArgumentError(
        'storeQueueDepth must be a power of two >= 2 (got $storeQueueDepth).',
      );
    }
    if (loadQueueDepth < 2 || (loadQueueDepth & (loadQueueDepth - 1)) != 0) {
      throw ArgumentError(
        'loadQueueDepth must be a power of two >= 2 (got $loadQueueDepth).',
      );
    }
    // Dual-commit (a second register write port + the OoO commit stage's
    // slot-1 path) is likewise only built for the OoO backend.
    if (commitWidth == IssueWidth.dual &&
        executionMode != ExecutionMode.outOfOrder) {
      throw ArgumentError(
        'commitWidth=$commitWidth requires executionMode=outOfOrder '
        '(got executionMode=$executionMode).',
      );
    }
    if (writeBufferDepth < 0) {
      throw ArgumentError(
        'writeBufferDepth must be >= 0 (got $writeBufferDepth).',
      );
    }
    if (speculativeFetch && executionMode != ExecutionMode.outOfOrder) {
      throw ArgumentError(
        'speculativeFetch requires executionMode=outOfOrder '
        '(got executionMode=$executionMode).',
      );
    }
    if (threads < 1) {
      throw ArgumentError('threads must be >= 1 (got $threads).');
    }
    // The Hypervisor extension virtualizes supervisor mode, so it cannot be
    // present without supervisor support.
    if (hasHypervisor && !hasSupervisor) {
      throw ArgumentError('the H extension requires hasSupervisor=true.');
    }
  }

  /// Instructions dispatched (renamed/allocated) per cycle.
  int get dispatchLanes => issueWidth.lanes;

  /// Read-only value of the `rpipelinecap` vendor CSR (0x7C4): a feature-
  /// discovery bitmap derived purely from this config, so software can probe
  /// what the build contains before toggling [rpipelinectl]. Computed the same
  /// way in the emulator and the HDL (both read this getter) so it stays in
  /// parity. Bit layout:
  ///   [0] out-of-order   [1] dual-issue        [2] speculative fetch
  ///   [3] branch predictor present             [4] load-store queue present
  ///   [5] store->load forwarding               [6] speculative LSQ (v4 bypass)
  ///   [7] instruction cache                    [8] paging (MMU) present
  int get rpipelineCap {
    var v = 0;
    if (executionMode == ExecutionMode.outOfOrder) v |= 1 << 0;
    if (issueWidth == IssueWidth.dual) v |= 1 << 1;
    if (speculativeFetch) v |= 1 << 2;
    if (branchPredictor != BranchPredictor.none) v |= 1 << 3;
    if (loadStoreQueue != LoadStoreQueue.none) v |= 1 << 4;
    if (loadStoreQueue == LoadStoreQueue.forwarding ||
        loadStoreQueue == LoadStoreQueue.speculative) {
      v |= 1 << 5;
    }
    if (loadStoreQueue == LoadStoreQueue.speculative) v |= 1 << 6;
    if (l1cache != null) v |= 1 << 7;
    if (mmu.hasPaging) v |= 1 << 8;
    return v;
  }

  /// Instructions committed (retired) per cycle; drives the number of register
  /// write ports.
  int get commitLanes => commitWidth.lanes;

  /// Whether the Vector (V) extension is configured.
  bool get hasVector => extensions.any((e) => e.name == 'V');

  /// Whether the Hypervisor (H) extension is configured. Derived from the
  /// extension set so a config that omits [rvH] has zero hypervisor overhead.
  /// H builds on supervisor mode (validated in the constructor).
  bool get hasHypervisor => extensions.any((e) => e.name == 'H');

  /// Whether the machine-level state-enable extension (Smstateen) is configured,
  /// which provides the mstateen/sstateen/hstateen CSRs.
  bool get hasStateen => extensions.any((e) => e.name == 'Smstateen');

  /// Whether the core carries CSR hardware. Derived from the ISA: the CSR
  /// file exists when Zicsr (or the privileged architecture, which implies
  /// it) is in the extension set, gated by the core type's capability. A
  /// tier without Zicsr (the nano) gets no CSR file at all, which is worth
  /// roughly an eighth of its area.
  bool get hasCsrs =>
      type.hasCsrs &&
      (extensions.contains(rvZicsr) || extensions.contains(rvPriv));

  RiscVIsaConfig get isa => RiscVIsaConfig(
    mxlen: mxlen,
    extensions: extensions,
    hasSupervisor: hasSupervisor,
    hasUser: hasUser,
    pagingModes: mmu.pagingModes,
  );

  @override
  String toString() =>
      'RiverCoreConfig(vendorId: $vendorId, archId: $archId, hartId: $hartId,'
      ' resetVector: $resetVector, clock: $clock, isa: ${isa.implementsString},'
      ' interrupts: $interrupts, mmu: $mmu, microcodeMode: $microcodeMode,'
      ' executionMode: $executionMode, issueWidth: $issueWidth,'
      ' commitWidth: $commitWidth,'
      ' l1Cache: $l1cache, type: $type,'
      ' icsVersion: $icsVersion, threads: $threads)';
}

class RiverPortMap {
  final String name;
  final List<int> pins;
  final Map<String, String> devices;
  final bool isOutput;

  int get width => pins.length.bitLength;

  const RiverPortMap(
    this.name,
    this.pins,
    this.devices, {
    this.isOutput = false,
  });

  @override
  String toString() =>
      'RiverPortMap($name, pins: $pins, devices: $devices, isOutput: $isOutput)';
}

class RiverDeviceField {
  final String name;
  final int width;

  const RiverDeviceField({required this.name, required this.width});
}

class RiverDeviceAccessor {
  final String path;
  final Map<String, RiverDeviceField> fields;
  final Map<String, int> _fieldOffsets;

  const RiverDeviceAccessor({
    required this.path,
    required this.fields,
    Map<String, int> fieldOffsets = const {},
  }) : _fieldOffsets = fieldOffsets;

  int? fieldAddress(String name) => _fieldOffsets[name];
}

class RiverDevice {
  final String name;
  final String compatible;
  final String module;
  final BusAddressRange? range;
  final List<int> interrupts;
  final int? clockFrequency;
  final HarborClockConfig? clock;
  final List<RiverPortMap> ports;
  final RiverDeviceAccessor? accessor;

  const RiverDevice({
    required this.name,
    required this.compatible,
    this.module = '',
    this.range,
    this.interrupts = const [],
    this.clockFrequency,
    this.clock,
    this.ports = const [],
    this.accessor,
  });

  @override
  String toString() =>
      'RiverDevice(name: $name, compatible: $compatible, range: $range,'
      ' interrupts: $interrupts)';
}

class RiverSoCConfig {
  final List<RiverDevice> devices;
  final List<RiverCoreConfig> cores;
  final WishboneConfig busConfig;
  final List<HarborClockConfig> clocks;
  final List<RiverPortMap> ports;

  const RiverSoCConfig({
    this.devices = const [],
    this.cores = const [],
    this.busConfig = const WishboneConfig(
      addressWidth: 32,
      dataWidth: 32,
      selWidth: 4,
    ),
    this.clocks = const [],
    this.ports = const [],
  });

  RiverCoreConfig? getCore(int hartId) {
    for (final core in cores) {
      if (core.hartId == hartId) return core;
    }
    return null;
  }

  RiverDevice? getDevice(String name) {
    for (final dev in devices) {
      if (dev.name == name) return dev;
    }
    return null;
  }

  @override
  String toString() =>
      'RiverSoCConfig(devices: $devices, cores: $cores, clocks: $clocks,'
      ' ports: $ports)';
}
