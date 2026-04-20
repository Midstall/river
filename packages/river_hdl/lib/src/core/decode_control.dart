import 'package:rohd/rohd.dart';
import 'package:harbor/harbor.dart';

import 'issue.dart' show FuType;

/// Single-cycle control signals for an instruction, derived at build time from
/// an operation's microcode.
///
/// The in-order pipeline executes by stepping through
/// [RiscVOperation.microcode] one micro-op at a time. The out-of-order pipeline
/// instead needs every control signal up front so it can rename, enqueue, and
/// dispatch in a single cycle. [decodeControlForOp] collapses the microcode
/// sequence into this flat bundle; a hardware ROM indexed by the decoder's op
/// index then drives the issue queue's `enq*` ports. See
/// project_hdl_ooo_state in memory for how this fits the OoO bring-up.
class DecodeControl {
  /// Which functional unit executes this instruction.
  final FuType fuType;

  /// ALU operation (meaningful when [fuType] is [FuType.alu], and for the
  /// address calculation of memory ops).
  final RiscVAluFunct aluFunct;

  /// Writes an architectural destination register (rd or the link register).
  final bool writesRd;

  final bool isLoad;
  final bool isStore;

  /// Access size for loads/stores; null for non-memory ops.
  final RiscVMemSize? memSize;

  /// Zero-extend (vs sign-extend) a load result.
  final bool memUnsigned;

  /// Condition for conditional branches; null for non-branch ops.
  final RiscVBranchCondition? branchCond;

  /// Unconditional control transfer (jal/jalr).
  final bool isJump;

  /// Register-indirect jump target (jalr), as opposed to PC-relative (jal).
  final bool isJalr;

  /// The ALU's second operand is the immediate (I-type) rather than rs2.
  final bool useImm;

  final bool isCsr;

  /// Privileged return (mret/sret). The ROB carries this so the commit stage
  /// redirects to {m,s}epc and restores the privilege mode.
  final bool isReturn;

  /// Return privilege level (3=MRET, 1=SRET); meaningful when [isReturn].
  final int returnLevel;

  const DecodeControl({
    required this.fuType,
    this.aluFunct = RiscVAluFunct.add,
    this.writesRd = false,
    this.isLoad = false,
    this.isStore = false,
    this.memSize,
    this.memUnsigned = false,
    this.branchCond,
    this.isJump = false,
    this.isJalr = false,
    this.useImm = false,
    this.isCsr = false,
    this.isReturn = false,
    this.returnLevel = 0,
  });

  @override
  String toString() =>
      'DecodeControl($fuType, alu=$aluFunct, writesRd=$writesRd, '
      'load=$isLoad, store=$isStore, branch=$branchCond, jump=$isJump, '
      'jalr=$isJalr, useImm=$useImm, csr=$isCsr)';
}

/// Collapses [op]'s microcode sequence into a flat [DecodeControl] bundle.
///
/// Functional-unit selection is a priority: CSR > memory > branch/jump > ALU
/// (a load still has an ALU address-calc micro-op, but it dispatches to the
/// memory unit).
DecodeControl decodeControlForOp(RiscVOperation op) {
  RiscVAlu? alu;
  RiscVMemLoad? load;
  RiscVMemStore? store;
  RiscVBranch? branch;
  // Every op ends with a RiscVUpdatePc (the implicit pc+=4), so it does not mark
  // a jump. Only jal/jalr write a link register, and that is the jump signal.
  RiscVWriteLinkRegister? link;
  RiscVUpdatePc? pcUpdate;
  var hasCsr = false;
  var writesRd = false;
  // Some compressed ops (c.li, c.lui) write rd directly from the immediate with
  // no ALU micro-op. The in-order microcode engine handles that, but the OoO
  // datapath routes results through the ALU, so it needs useImm set and an add
  // of x0 + imm (the decoder gives these ops rs1 == x0, so add(x0, imm) == imm).
  // Without this the OoO ALU ignores the immediate and writes 0.
  var directImmWrite = false;
  // mret/sret: carried to commit so the OoO commit stage redirects to {m,s}epc
  // and restores the mode (the in-order path handles this in exec.dart).
  RiscVReturnOp? ret;

  for (final m in op.microcode) {
    switch (m) {
      case RiscVReturnOp r:
        ret ??= r;
      case RiscVAlu a:
        alu ??= a;
      case RiscVMemLoad l:
        load ??= l;
        // A load commits its result to rd (no separate RiscVWriteRegister in
        // the microcode), so mark it as writing rd for rename/ROB commit.
        writesRd = true;
      case RiscVMemStore s:
        store ??= s;
      case RiscVBranch b:
        branch ??= b;
      case RiscVUpdatePc u:
        pcUpdate ??= u;
      case RiscVReadCsr _ || RiscVWriteCsr _:
        hasCsr = true;
      case RiscVWriteRegister w when w.dest == RiscVMicroOpField.rd:
        writesRd = true;
        if (w.source == RiscVMicroOpSource.imm) directImmWrite = true;
      case RiscVWriteLinkRegister l:
        link ??= l;
        writesRd = true;
      default:
        break;
    }
  }

  final isJump = link != null;
  final FuType fuType;
  if (hasCsr) {
    fuType = FuType.csr;
  } else if (load != null || store != null) {
    fuType = FuType.memory;
  } else if (branch != null || isJump) {
    fuType = FuType.branch;
  } else {
    fuType = FuType.alu;
  }

  return DecodeControl(
    fuType: fuType,
    aluFunct: alu?.funct ?? RiscVAluFunct.add,
    writesRd: writesRd,
    isLoad: load != null,
    isStore: store != null,
    memSize: load?.size ?? store?.size,
    memUnsigned: load?.unsigned ?? false,
    branchCond: branch?.condition,
    isJump: isJump,
    // jalr computes an absolute target (rs1+imm via the ALU); jal is the
    // PC-relative form. The linking PC update's `absolute` flag distinguishes.
    isJalr: isJump && (pcUpdate?.absolute ?? false),
    useImm: (alu != null && alu.b == RiscVMicroOpField.imm) || directImmWrite,
    isCsr: hasCsr,
    isReturn: ret != null,
    returnLevel: ret?.privilegeLevel ?? 0,
  );
}

/// fu_branch expects the RISC-V funct3 branch encoding, not the
/// [RiscVBranchCondition] declaration order.
int branchCondFunct3(RiscVBranchCondition? c) => switch (c) {
  RiscVBranchCondition.eq => 0,
  RiscVBranchCondition.ne => 1,
  RiscVBranchCondition.lt => 4,
  RiscVBranchCondition.ge => 5,
  RiscVBranchCondition.ltu => 6,
  RiscVBranchCondition.geu => 7,
  null => 0,
};

/// Combinational ROM mapping the decoder's op index to the flat control signals
/// the out-of-order issue queue and functional units consume. Built at
/// elaboration time from [decodeControlForOp] over the operation table, so it
/// carries no runtime decode cost. Outputs use the FU-side encodings:
/// `fuType`=[FuType.index], `aluFunct`=[RiscVAluFunct.index], `memSize`=byte
/// count, `branchCond`=funct3 (see [branchCondFunct3]).
class DecodeControlRom extends Module {
  Logic get fuType => output('fu_type');
  Logic get aluFunct => output('alu_funct');
  Logic get writesRd => output('writes_rd');
  Logic get isLoad => output('is_load');
  Logic get isStore => output('is_store');
  Logic get memSize => output('mem_size');
  Logic get memUnsigned => output('mem_unsigned');
  Logic get branchCond => output('branch_cond');
  Logic get isJump => output('is_jump');
  Logic get isJalr => output('is_jalr');
  Logic get useImm => output('use_imm');
  Logic get isCsr => output('is_csr');
  Logic get isReturn => output('is_return');
  Logic get returnLevel => output('return_level');

  DecodeControlRom(
    Logic index, {
    required Map<int, RiscVOperation> operations,
    super.name = 'decode_control_rom',
  }) {
    index = addInput('index', index, width: index.width);

    addOutput('fu_type', width: 2);
    addOutput('alu_funct', width: 7);
    addOutput('writes_rd');
    addOutput('is_load');
    addOutput('is_store');
    addOutput('mem_size', width: 3);
    addOutput('mem_unsigned');
    addOutput('branch_cond', width: 3);
    addOutput('is_jump');
    addOutput('is_jalr');
    addOutput('use_imm');
    addOutput('is_csr');
    addOutput('is_return');
    addOutput('return_level', width: 2);

    List<Conditional> drive(DecodeControl c) {
      // memSize is the access byte count in 3 bits (1/2/4). dword (8) only
      // appears on RV64 cores, which fu_mem's 3-bit size port does not yet
      // support; clamp so the ROM still elaborates for those configs.
      final sizeBytes = (c.memSize?.bytes ?? 0) <= 4
          ? (c.memSize?.bytes ?? 0)
          : 4;
      return [
        fuType < Const(c.fuType.index, width: 2),
        aluFunct < Const(c.aluFunct.index, width: 7),
        writesRd < Const(c.writesRd ? 1 : 0),
        isLoad < Const(c.isLoad ? 1 : 0),
        isStore < Const(c.isStore ? 1 : 0),
        memSize < Const(sizeBytes, width: 3),
        memUnsigned < Const(c.memUnsigned ? 1 : 0),
        branchCond < Const(branchCondFunct3(c.branchCond), width: 3),
        isJump < Const(c.isJump ? 1 : 0),
        isJalr < Const(c.isJalr ? 1 : 0),
        useImm < Const(c.useImm ? 1 : 0),
        isCsr < Const(c.isCsr ? 1 : 0),
        isReturn < Const(c.isReturn ? 1 : 0),
        returnLevel < Const(c.returnLevel & 0x3, width: 2),
      ];
    }

    Combinational([
      Case(index, [
        for (final e in operations.entries)
          CaseItem(
            Const(e.key, width: index.width),
            drive(decodeControlForOp(e.value)),
          ),
      ], defaultItem: drive(const DecodeControl(fuType: FuType.alu))),
    ]);
  }
}
