import 'package:river/river.dart';

/// The config table for the test matrix: maps (mxlen, microarch, instruction
/// category) to a RiverCoreConfig + label, and gates which microarch x category
/// combinations are actually buildable. List-driven and extensible.

/// Microarchitecture axis.
enum Uarch { inOrder, ooo, oooDual }

String uarchLabel(Uarch u) => switch (u) {
  Uarch.inOrder => 'inorder',
  Uarch.ooo => 'ooo',
  Uarch.oooDual => 'ooo_dual',
};

String mxlenLabel(RiscVMxlen m) => m == RiscVMxlen.rv64 ? 'rv64' : 'rv32';

/// Extensions each instruction category needs beyond the base ISA. The category
/// key is also the directory name (`test/<category>/`). Adding an extension is
/// a new entry here + an entry in the instruction table.
final Map<String, List<RiscVExtension>> categoryExtensions = {
  'base': <RiscVExtension>[],
  'loadstore': <RiscVExtension>[],
  'branch': <RiscVExtension>[],
  'csr': <RiscVExtension>[], // Zicsr is always enabled in matrixConfig

  'm': [rvM],
  'a': [rvA],
  'bitmanip': [rvZba, rvZbb, rvZbs],
  'zicond': [rvZicond],
  'zacas': [rvA, rvZacas],
  // Single-precision F. The fd cells are all .s and now elaborate + pass on
  // BOTH rv32 and rv64 (task #71 coerced the FP read/write ports, the result
  // switch, and the roundSatFpToInt W/L mux to the mxlen width). Double stays
  // its own rv64-only 'd' category.
  'fd': [rvF, rvFExtra],
  // Double-precision (rv64 only - see generator gate). rv64+D elaborates fine.
  'd': [rvF, rvD, rvFExtra, rvDExtra],
  'v': [rvV], // vector (VLEN defaults to 128 in RiverCoreConfig)
};

/// Categories that run ONLY on speculative (OoO/dual) configs. Empty now: the
/// in-order taken-branch path is fixed (#69 - exec.dart branch target was
/// missing `currentPc +` and the lt/ge/ltu/geu condition used the unsigned diff
/// sign), so the branch category runs in-order too without a predictor.
const _speculativeOnlyCategories = <String>{};

/// Categories that run ONLY on the in-order path for now. Reasons per category:
///  - loadstore/a/zacas: the OoO memory FU is incomplete (stores don't drain/
///    commit, AMO writeback returns 0, sign-ext loads don't sign-extend - see
///    project_hdl_ooo_state / project_hdl_lsq).
///  (csr now runs on OoO too - #70 fixed: the CsrUnit op-decode + the zimm
///  plumbing were wrong; csrrw/csrrs/csrrc/csrrwi all pass on OoO.)
///  - fd: the OoO core is INTEGER-ONLY (no FP functional unit); F/D execute
///    only on the in-order path (project_hdl_fpu).
/// Flip a category out the moment its OoO path lands - the matrix then
/// validates it immediately.
const _inOrderOnlyCategories = {
  'loadstore',
  'a',
  'zacas',
  'fd',
  'd',
  'v', // vector uses vector loads/stores (OoO mem FU incomplete) + in-order path
};

/// Whether (microarch, category) is a buildable + runnable matrix cell-set.
bool microarchSupports(Uarch u, String category) {
  if (u == Uarch.inOrder) return !_speculativeOnlyCategories.contains(category);
  return !_inOrderOnlyCategories.contains(category);
}

/// Build the config for (mxlen, microarch, category): base ISA + the category's
/// extensions, on the requested mxlen and pipeline personality.
RiverCoreConfig matrixConfig(
  RiscVMxlen mxlen,
  Uarch u,
  String category, {
  int? regfileReadLatency,
  MicrocodeMode microcodeMode = MicrocodeMode.none,
}) {
  final base = mxlen == RiscVMxlen.rv64
      ? <RiscVExtension>[rv64i, rv32i]
      : <RiscVExtension>[rv32i];
  return RiverCoreConfig(
    regfileReadLatency: regfileReadLatency,
    microcodeMode: microcodeMode,
    clock: HarborClockConfig(
      name: 'sysclk',
      rate: HarborFixedClockRate(48000000),
    ),
    mxlen: mxlen,
    extensions: [
      ...base,
      rvZicsr,
      rvZifencei,
      ...categoryExtensions[category]!,
    ],
    interrupts: const [],
    mmu: HarborMmuConfig(
      mxlen: mxlen,
      pagingModes: const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    type: RiverCoreType.general,
    executionMode: u == Uarch.inOrder
        ? ExecutionMode.inOrder
        : ExecutionMode.outOfOrder,
    issueWidth: u == Uarch.oooDual ? IssueWidth.dual : IssueWidth.single,
    speculativeFetch: u != Uarch.inOrder,
    // A predictor is required for the taken-branch redirect path to resolve
    // (with none, a taken branch wedges - see task #69). btfn is the validated
    // predictor (core_bpred_test). The config rejects a predictor without
    // speculativeFetch, so in-order stays predictor-less (and branch-free in
    // the matrix until #69 is resolved).
    branchPredictor: u == Uarch.inOrder
        ? BranchPredictor.none
        : BranchPredictor.btfn,
  );
}
