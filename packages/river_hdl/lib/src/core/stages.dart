import 'package:harbor/harbor.dart';

/// Pipeline stages for the River OoO dual-issue core.
///
/// The pipeline is split into a front-end (in-order) and back-end (OoO):
///   fetch → decode → rename → issue → [execute / memory / branch / csr] → commit
enum RiverStage with HarborPipelineStage {
  /// Instruction fetch from I-cache / memory.
  fetch,

  /// Instruction decode and register read.
  decode,

  /// Register rename: map architectural → physical via RAT.
  rename,

  /// Issue queue: dispatch to functional units when operands ready.
  issue,

  /// ALU / mul / div execution.
  execute,

  /// Load / store / atomic memory access.
  memory,

  /// Branch resolution and PC redirect.
  branch,

  /// CSR read / write (serialised).
  csr,

  /// Commit: retire from ROB in program order, free physical registers.
  commit,
}

// ---------------------------------------------------------------------------
// Payload constants. Width in bits, carried through pipeline registers.
// ---------------------------------------------------------------------------

/// Program counter of this instruction.
const kPC = HarborPayload('PC', width: 64);

/// Raw 32-bit instruction word (post-decompression).
const kInstruction = HarborPayload('INSTR', width: 32);

/// Whether the original fetch was a compressed (16-bit) instruction.
const kCompressed = HarborPayload('COMPRESSED');

/// Decoded destination register index (architectural, 5 bits).
const kRd = HarborPayload('RD', width: 5);

/// Decoded source register 1 index (architectural, 5 bits).
const kRs1 = HarborPayload('RS1', width: 5);

/// Decoded source register 2 index (architectural, 5 bits).
const kRs2 = HarborPayload('RS2', width: 5);

/// Sign-extended immediate value.
const kImm = HarborPayload('IMM', width: 64);

/// Operation index into the microcode ROM. 12 bits covers the full RV64GC +
/// bit-manip op table (RC1.ma macro needs 11); fitWidth at the decode site keeps
/// it correct for smaller configs too.
const kOpIndex = HarborPayload('OP_INDEX', width: 12);

/// Instruction format type index (R/I/S/B/U/J).
const kFormatType = HarborPayload('FORMAT_TYPE', width: 4);

/// Physical destination register (from rename).
const kPdst = HarborPayload('PDST', width: 7);

/// Physical source register 1 (from rename).
const kPsrc1 = HarborPayload('PSRC1', width: 7);

/// Physical source register 2 (from rename).
const kPsrc2 = HarborPayload('PSRC2', width: 7);

/// Previous physical mapping of rd (for rollback on mis-speculate).
const kPdstOld = HarborPayload('PDST_OLD', width: 7);

/// Reorder buffer tag.
const kRobTag = HarborPayload('ROB_TAG', width: 7);

/// Source operand 1 value (read from physical register file or bypass).
const kSrc1Value = HarborPayload('SRC1_VALUE', width: 64);

/// Source operand 2 value (read from physical register file or bypass).
const kSrc2Value = HarborPayload('SRC2_VALUE', width: 64);

/// ALU / execution result.
const kResult = HarborPayload('RESULT', width: 64);

/// Memory load data.
const kMemData = HarborPayload('MEM_DATA', width: 64);

/// Memory address (computed by AGU).
const kMemAddr = HarborPayload('MEM_ADDR', width: 64);

/// Memory access size in bytes (1/2/4/8).
const kMemSize = HarborPayload('MEM_SIZE', width: 3);

/// Whether this instruction writes a register.
const kWritesRd = HarborPayload('WRITES_RD');

/// Whether this is a memory load.
const kIsLoad = HarborPayload('IS_LOAD');

/// Whether this is a memory store.
const kIsStore = HarborPayload('IS_STORE');

/// Whether this is a branch/jump.
const kIsBranch = HarborPayload('IS_BRANCH');

/// Whether this is a CSR instruction.
const kIsCsr = HarborPayload('IS_CSR');

/// Whether this is a privileged return (mret/sret).
const kIsReturn = HarborPayload('IS_RETURN');

/// Privileged-return level (2-bit: 3=MRET, 1=SRET); meaningful when kIsReturn.
const kReturnLevel = HarborPayload('RETURN_LEVEL', width: 2);

/// Functional unit type (FuType.index: alu=0, memory=1, branch=2, csr=3).
const kFuType = HarborPayload('FU_TYPE', width: 2);

/// ALU operation (RiscVAluFunct.index).
const kAluFunct = HarborPayload('ALU_FUNCT', width: 7);

/// Conditional-branch condition (RISC-V funct3 encoding).
const kBranchCond = HarborPayload('BRANCH_COND', width: 3);

/// Unconditional jump (jal/jalr).
const kIsJump = HarborPayload('IS_JUMP');

/// Register-indirect jump target (jalr).
const kIsJalr = HarborPayload('IS_JALR');

/// The fetched instruction was a 2-byte compressed (RVC) op. Needed so the
/// branch unit forms the JAL/JALR link as PC+2, not PC+4.
const kIsCompressed = HarborPayload('IS_COMPRESSED');

/// ALU second operand is the immediate (I-type).
const kUseImm = HarborPayload('USE_IMM');

/// Sign-extend (vs zero-extend) a load result.
const kSignExtend = HarborPayload('SIGN_EXTEND');

/// Branch target address.
const kBranchTarget = HarborPayload('BRANCH_TARGET', width: 64);

/// Whether the branch was taken.
const kBranchTaken = HarborPayload('BRANCH_TAKEN');

/// Whether this instruction caused a trap.
const kTrap = HarborPayload('TRAP');

/// Trap cause code.
const kTrapCause = HarborPayload('TRAP_CAUSE', width: 6);

/// Trap value.
const kTrapVal = HarborPayload('TRAP_VAL', width: 64);

/// Fence signal.
const kFence = HarborPayload('FENCE');

/// Privilege mode (M=3, S=1, U=0).
const kPrivMode = HarborPayload('PRIV_MODE', width: 2);

// ---------------------------------------------------------------------------
// Dual-dispatch slot-1 payloads. A second instruction flows through the same
// registered decode→rename boundary as slot 0, so every slot-0 decode/rename
// field has a slot-1 twin. kSlot1Valid marks whether slot 1 holds a real
// (fetched+decoded) instruction this cycle. Only used when issueWidth==dual.
// ---------------------------------------------------------------------------
const kSlot1Valid = HarborPayload('SLOT1_VALID');
const kPC1 = HarborPayload('PC_1', width: 64);
const kInstruction1 = HarborPayload('INSTR_1', width: 32);
const kRd1 = HarborPayload('RD_1', width: 5);
const kRs1_1 = HarborPayload('RS1_1', width: 5);
const kRs2_1 = HarborPayload('RS2_1', width: 5);
const kImm1 = HarborPayload('IMM_1', width: 64);
const kOpIndex1 = HarborPayload('OP_INDEX_1', width: 12);
const kWritesRd1 = HarborPayload('WRITES_RD_1');
const kIsLoad1 = HarborPayload('IS_LOAD_1');
const kIsStore1 = HarborPayload('IS_STORE_1');
const kIsBranch1 = HarborPayload('IS_BRANCH_1');
const kIsCsr1 = HarborPayload('IS_CSR_1');
const kIsReturn1 = HarborPayload('IS_RETURN_1');
const kReturnLevel1 = HarborPayload('RETURN_LEVEL_1', width: 2);
const kMemSize1 = HarborPayload('MEM_SIZE_1', width: 3);
const kFuType1 = HarborPayload('FU_TYPE_1', width: 2);
const kAluFunct1 = HarborPayload('ALU_FUNCT_1', width: 7);
const kBranchCond1 = HarborPayload('BRANCH_COND_1', width: 3);
const kIsJump1 = HarborPayload('IS_JUMP_1');
const kIsJalr1 = HarborPayload('IS_JALR_1');
const kIsCompressed1 = HarborPayload('IS_COMPRESSED_1');
const kUseImm1 = HarborPayload('USE_IMM_1');
const kSignExtend1 = HarborPayload('SIGN_EXTEND_1');

// Slot-1 rename results.
const kPdst1 = HarborPayload('PDST_1', width: 7);
const kPsrc1_1 = HarborPayload('PSRC1_1', width: 7);
const kPsrc2_1 = HarborPayload('PSRC2_1', width: 7);
const kPdstOld1 = HarborPayload('PDST_OLD_1', width: 7);
const kRobTag1 = HarborPayload('ROB_TAG_1', width: 7);
