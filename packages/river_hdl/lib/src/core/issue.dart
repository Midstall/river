import 'package:rohd/rohd.dart';

/// Functional unit type classification for dispatch.
enum FuType { alu, memory, branch, csr }

/// Issue queue entry width decomposition.
class IssueEntry {
  final int xlen;
  final int robTagBits;

  const IssueEntry({required this.xlen, this.robTagBits = 7});

  // Packed fields (LSB-first):
  //   robTag       [robTagBits]
  //   psrc1        [7]
  //   psrc2        [7]
  //   pdst         [7]
  //   src1Ready    [1]
  //   src2Ready    [1]
  //   src1Value    [xlen]
  //   src2Value    [xlen]
  //   imm          [xlen]
  //   pc           [xlen]
  //   funct        [5]
  //   fuType       [2]
  //   isStore      [1]
  //   memSize      [3]
  //   branchCond   [3]
  //   isJump       [1]
  //   isJalr       [1]
  //   useImm       [1]
  //   writesRd     [1]
  //   csrOp        [3]
  //   csrAddr      [12]
  //   signExtend   [1]
  //   valid        [1]

  int get width =>
      robTagBits +
      7 +
      7 +
      7 +
      1 +
      1 +
      xlen * 4 +
      5 +
      2 +
      1 +
      3 +
      3 +
      1 +
      1 +
      1 +
      1 +
      3 +
      12 +
      1 +
      1;
}

/// Issue queue with wake-up and select logic for dual-issue dispatch.
///
/// Accepts up to 2 instructions per cycle from the rename stage.
/// Dispatches up to 2 instructions per cycle to functional units when
/// all source operands are ready (via register read or result bypass).
class IssueQueue extends Module {
  /// Number of issue queue entries.
  final int depth;

  /// XLEN of the core.
  final int xlen;

  /// Physical register index width.
  final int physRegBits;

  /// ROB tag width.
  final int robTagBits;

  /// Whether memory ops dispatch strictly in program order (LSQ mode).
  final bool inOrderMem;

  /// Whether loads may speculatively dispatch ahead of not-ready older stores.
  final bool speculativeMem;

  // -- Enqueue output --

  Logic get enqReady => output('enq_ready');

  // -- Dispatch ports (to functional units) --

  /// ALU dispatch slot 0.
  Logic get dispatchAluValid0 => output('dispatch_alu_valid_0');
  Logic get dispatchAluTag0 => output('dispatch_alu_tag_0');
  Logic get dispatchAluSrc10 => output('dispatch_alu_src1_0');
  Logic get dispatchAluSrc20 => output('dispatch_alu_src2_0');
  Logic get dispatchAluImm0 => output('dispatch_alu_imm_0');
  Logic get dispatchAluFunct0 => output('dispatch_alu_funct_0');
  Logic get dispatchAluUseImm0 => output('dispatch_alu_use_imm_0');
  Logic get dispatchAluPc0 => output('dispatch_alu_pc_0');

  /// ALU dispatch slot 1 (dual-issue: second ALU).
  Logic get dispatchAluValid1 => output('dispatch_alu_valid_1');
  Logic get dispatchAluTag1 => output('dispatch_alu_tag_1');
  Logic get dispatchAluSrc11 => output('dispatch_alu_src1_1');
  Logic get dispatchAluSrc21 => output('dispatch_alu_src2_1');
  Logic get dispatchAluImm1 => output('dispatch_alu_imm_1');
  Logic get dispatchAluFunct1 => output('dispatch_alu_funct_1');
  Logic get dispatchAluUseImm1 => output('dispatch_alu_use_imm_1');
  Logic get dispatchAluPc1 => output('dispatch_alu_pc_1');

  /// Memory dispatch.
  Logic get dispatchMemValid => output('dispatch_mem_valid');
  Logic get dispatchMemTag => output('dispatch_mem_tag');
  Logic get dispatchMemSrc1 => output('dispatch_mem_src1');
  Logic get dispatchMemSrc2 => output('dispatch_mem_src2');
  Logic get dispatchMemImm => output('dispatch_mem_imm');
  Logic get dispatchMemIsStore => output('dispatch_mem_is_store');
  Logic get dispatchMemSize => output('dispatch_mem_size');
  Logic get dispatchMemSignExtend => output('dispatch_mem_sign_extend');
  Logic get dispatchMemPc => output('dispatch_mem_pc');

  /// Branch dispatch.
  Logic get dispatchBranchValid => output('dispatch_branch_valid');
  Logic get dispatchBranchTag => output('dispatch_branch_tag');
  Logic get dispatchBranchSrc1 => output('dispatch_branch_src1');
  Logic get dispatchBranchSrc2 => output('dispatch_branch_src2');
  Logic get dispatchBranchImm => output('dispatch_branch_imm');
  Logic get dispatchBranchPc => output('dispatch_branch_pc');
  Logic get dispatchBranchCondition => output('dispatch_branch_condition');
  Logic get dispatchBranchIsJump => output('dispatch_branch_is_jump');
  Logic get dispatchBranchIsJalr => output('dispatch_branch_is_jalr');

  /// CSR dispatch.
  Logic get dispatchCsrValid => output('dispatch_csr_valid');
  Logic get dispatchCsrTag => output('dispatch_csr_tag');
  Logic get dispatchCsrSrc1 => output('dispatch_csr_src1');
  Logic get dispatchCsrImm => output('dispatch_csr_imm');
  Logic get dispatchCsrOp => output('dispatch_csr_op');
  Logic get dispatchCsrAddr => output('dispatch_csr_addr');

  IssueQueue(
    Logic clk,
    Logic reset, {
    // Enqueue slot 0
    required Logic enqValid0,
    required Logic enqTag0,
    required Logic enqPsrc10,
    required Logic enqPsrc20,
    required Logic enqPdst0,
    required Logic enqImm0,
    required Logic enqPc0,
    required Logic enqFunct0,
    required Logic enqFuType0,
    required Logic enqWritesRd0,
    required Logic enqIsStore0,
    required Logic enqMemSize0,
    required Logic enqBranchCond0,
    required Logic enqIsJump0,
    required Logic enqIsJalr0,
    required Logic enqUseImm0,
    required Logic enqCsrOp0,
    required Logic enqCsrAddr0,
    required Logic enqSignExtend0,
    // Enqueue slot 1
    required Logic enqValid1,
    required Logic enqTag1,
    required Logic enqPsrc11,
    required Logic enqPsrc21,
    required Logic enqPdst1,
    required Logic enqImm1,
    required Logic enqPc1,
    required Logic enqFunct1,
    required Logic enqFuType1,
    required Logic enqWritesRd1,
    required Logic enqIsStore1,
    required Logic enqMemSize1,
    required Logic enqBranchCond1,
    required Logic enqIsJump1,
    required Logic enqIsJalr1,
    required Logic enqUseImm1,
    required Logic enqCsrOp1,
    required Logic enqCsrAddr1,
    required Logic enqSignExtend1,
    // Operand values from physical register file
    required Logic enqSrc1Value0,
    required Logic enqSrc2Value0,
    required Logic enqSrc1Ready0,
    required Logic enqSrc2Ready0,
    required Logic enqSrc1Value1,
    required Logic enqSrc2Value1,
    required Logic enqSrc1Ready1,
    required Logic enqSrc2Ready1,
    // Wakeup signals
    required Logic wakeupValid0,
    required Logic wakeupTag0,
    required Logic wakeupValue0,
    required Logic wakeupValid1,
    required Logic wakeupTag1,
    required Logic wakeupValue1,
    // Optional 3rd wakeup port (dual-dispatch: ALU1 and the branch/CSR unit can
    // otherwise complete the same cycle and collide on a shared port, dropping a
    // wakeup → a waiting dependent never fires → deadlock).
    Logic? wakeupValid2,
    Logic? wakeupTag2,
    Logic? wakeupValue2,
    // FU busy signals
    required Logic aluBusy0,
    required Logic aluBusy1,
    required Logic memBusy,
    required Logic branchBusy,
    required Logic csrBusy,
    // Flush
    required Logic flush,
    // When true, memory ops dispatch in program order (oldest ready memory op
    // first), required by the store queue so its entries are always older than
    // any executing load. A store is held when [sqFull].
    this.inOrderMem = false,
    // When true (speculative LSQ), a load may dispatch ahead of a not-ready
    // older store (stores still dispatch in program order; loads are ordered
    // only against older loads). Takes precedence over [inOrderMem].
    this.speculativeMem = false,
    Logic? sqFull,
    this.depth = 16,
    this.xlen = 64,
    this.physRegBits = 7,
    this.robTagBits = 7,
    super.name = 'issue_queue',
  }) : super(definitionName: 'IssueQueue') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    // Enqueue inputs (dual-issue from rename), slot 0
    enqValid0 = addInput('enq_valid_0', enqValid0);
    enqTag0 = addInput('enq_tag_0', enqTag0, width: robTagBits);
    enqPsrc10 = addInput('enq_psrc1_0', enqPsrc10, width: physRegBits);
    enqPsrc20 = addInput('enq_psrc2_0', enqPsrc20, width: physRegBits);
    enqPdst0 = addInput('enq_pdst_0', enqPdst0, width: physRegBits);
    enqImm0 = addInput('enq_imm_0', enqImm0, width: xlen);
    enqPc0 = addInput('enq_pc_0', enqPc0, width: xlen);
    enqFunct0 = addInput('enq_funct_0', enqFunct0, width: 7);
    enqFuType0 = addInput('enq_fu_type_0', enqFuType0, width: 2);
    enqWritesRd0 = addInput('enq_writes_rd_0', enqWritesRd0);
    enqIsStore0 = addInput('enq_is_store_0', enqIsStore0);
    enqMemSize0 = addInput('enq_mem_size_0', enqMemSize0, width: 3);
    enqBranchCond0 = addInput('enq_branch_cond_0', enqBranchCond0, width: 3);
    enqIsJump0 = addInput('enq_is_jump_0', enqIsJump0);
    enqIsJalr0 = addInput('enq_is_jalr_0', enqIsJalr0);
    enqUseImm0 = addInput('enq_use_imm_0', enqUseImm0);
    enqCsrOp0 = addInput('enq_csr_op_0', enqCsrOp0, width: 3);
    enqCsrAddr0 = addInput('enq_csr_addr_0', enqCsrAddr0, width: 12);
    enqSignExtend0 = addInput('enq_sign_extend_0', enqSignExtend0);

    // Enqueue inputs, slot 1
    enqValid1 = addInput('enq_valid_1', enqValid1);
    enqTag1 = addInput('enq_tag_1', enqTag1, width: robTagBits);
    enqPsrc11 = addInput('enq_psrc1_1', enqPsrc11, width: physRegBits);
    enqPsrc21 = addInput('enq_psrc2_1', enqPsrc21, width: physRegBits);
    enqPdst1 = addInput('enq_pdst_1', enqPdst1, width: physRegBits);
    enqImm1 = addInput('enq_imm_1', enqImm1, width: xlen);
    enqPc1 = addInput('enq_pc_1', enqPc1, width: xlen);
    enqFunct1 = addInput('enq_funct_1', enqFunct1, width: 7);
    enqFuType1 = addInput('enq_fu_type_1', enqFuType1, width: 2);
    enqWritesRd1 = addInput('enq_writes_rd_1', enqWritesRd1);
    enqIsStore1 = addInput('enq_is_store_1', enqIsStore1);
    enqMemSize1 = addInput('enq_mem_size_1', enqMemSize1, width: 3);
    enqBranchCond1 = addInput('enq_branch_cond_1', enqBranchCond1, width: 3);
    enqIsJump1 = addInput('enq_is_jump_1', enqIsJump1);
    enqIsJalr1 = addInput('enq_is_jalr_1', enqIsJalr1);
    enqUseImm1 = addInput('enq_use_imm_1', enqUseImm1);
    enqCsrOp1 = addInput('enq_csr_op_1', enqCsrOp1, width: 3);
    enqCsrAddr1 = addInput('enq_csr_addr_1', enqCsrAddr1, width: 12);
    enqSignExtend1 = addInput('enq_sign_extend_1', enqSignExtend1);

    // Operand values from physical register file
    enqSrc1Value0 = addInput('enq_src1_value_0', enqSrc1Value0, width: xlen);
    enqSrc2Value0 = addInput('enq_src2_value_0', enqSrc2Value0, width: xlen);
    enqSrc1Ready0 = addInput('enq_src1_ready_0', enqSrc1Ready0);
    enqSrc2Ready0 = addInput('enq_src2_ready_0', enqSrc2Ready0);

    enqSrc1Value1 = addInput('enq_src1_value_1', enqSrc1Value1, width: xlen);
    enqSrc2Value1 = addInput('enq_src2_value_1', enqSrc2Value1, width: xlen);
    enqSrc1Ready1 = addInput('enq_src1_ready_1', enqSrc1Ready1);
    enqSrc2Ready1 = addInput('enq_src2_ready_1', enqSrc2Ready1);

    // Wake-up broadcast from functional unit results (for in-flight entries)
    wakeupValid0 = addInput('wakeup_valid_0', wakeupValid0);
    wakeupTag0 = addInput('wakeup_tag_0', wakeupTag0, width: physRegBits);
    wakeupValue0 = addInput('wakeup_value_0', wakeupValue0, width: xlen);

    wakeupValid1 = addInput('wakeup_valid_1', wakeupValid1);
    wakeupTag1 = addInput('wakeup_tag_1', wakeupTag1, width: physRegBits);
    wakeupValue1 = addInput('wakeup_value_1', wakeupValue1, width: xlen);
    final wuV2 = addInput('wakeup_valid_2', wakeupValid2 ?? Const(0));
    final wuT2 = addInput(
      'wakeup_tag_2',
      wakeupTag2 ?? Const(0, width: physRegBits),
      width: physRegBits,
    );
    final wuVal2 = addInput(
      'wakeup_value_2',
      wakeupValue2 ?? Const(0, width: xlen),
      width: xlen,
    );

    // FU busy signals
    aluBusy0 = addInput('alu_busy_0', aluBusy0);
    aluBusy1 = addInput('alu_busy_1', aluBusy1);
    memBusy = addInput('mem_busy', memBusy);
    branchBusy = addInput('branch_busy', branchBusy);
    csrBusy = addInput('csr_busy', csrBusy);
    final sqFullIn = addInput('sq_full', sqFull ?? Const(0));

    // Flush
    flush = addInput('flush', flush);

    // Enqueue ready output
    addOutput('enq_ready');

    // Dispatch outputs, ALU slot 0
    addOutput('dispatch_alu_valid_0');
    addOutput('dispatch_alu_tag_0', width: robTagBits);
    addOutput('dispatch_alu_src1_0', width: xlen);
    addOutput('dispatch_alu_src2_0', width: xlen);
    addOutput('dispatch_alu_imm_0', width: xlen);
    addOutput('dispatch_alu_funct_0', width: 7);
    addOutput('dispatch_alu_use_imm_0');
    addOutput('dispatch_alu_pc_0', width: xlen);

    // Dispatch outputs, ALU slot 1
    addOutput('dispatch_alu_valid_1');
    addOutput('dispatch_alu_tag_1', width: robTagBits);
    addOutput('dispatch_alu_src1_1', width: xlen);
    addOutput('dispatch_alu_src2_1', width: xlen);
    addOutput('dispatch_alu_imm_1', width: xlen);
    addOutput('dispatch_alu_funct_1', width: 7);
    addOutput('dispatch_alu_use_imm_1');
    addOutput('dispatch_alu_pc_1', width: xlen);

    // Dispatch outputs, Memory
    addOutput('dispatch_mem_valid');
    addOutput('dispatch_mem_tag', width: robTagBits);
    addOutput('dispatch_mem_src1', width: xlen);
    addOutput('dispatch_mem_src2', width: xlen);
    addOutput('dispatch_mem_imm', width: xlen);
    addOutput('dispatch_mem_is_store');
    addOutput('dispatch_mem_size', width: 3);
    addOutput('dispatch_mem_sign_extend');
    addOutput('dispatch_mem_pc', width: xlen);

    // Dispatch outputs, Branch
    addOutput('dispatch_branch_valid');
    addOutput('dispatch_branch_tag', width: robTagBits);
    addOutput('dispatch_branch_src1', width: xlen);
    addOutput('dispatch_branch_src2', width: xlen);
    addOutput('dispatch_branch_imm', width: xlen);
    addOutput('dispatch_branch_pc', width: xlen);
    addOutput('dispatch_branch_condition', width: 3);
    addOutput('dispatch_branch_is_jump');
    addOutput('dispatch_branch_is_jalr');

    // Dispatch outputs, CSR
    addOutput('dispatch_csr_valid');
    addOutput('dispatch_csr_tag', width: robTagBits);
    addOutput('dispatch_csr_src1', width: xlen);
    addOutput('dispatch_csr_imm', width: xlen);
    addOutput('dispatch_csr_op', width: 3);
    addOutput('dispatch_csr_addr', width: 12);

    // -- Internal storage --
    // Simplified: use per-field arrays instead of packed entries for readability.

    final entryValid = List.generate(depth, (i) => Logic(name: 'iq_valid_$i'));
    final entryTag = List.generate(
      depth,
      (i) => Logic(name: 'iq_tag_$i', width: robTagBits),
    );
    final entryFuType = List.generate(
      depth,
      (i) => Logic(name: 'iq_futype_$i', width: 2),
    );
    final entrySrc1Ready = List.generate(
      depth,
      (i) => Logic(name: 'iq_s1rdy_$i'),
    );
    final entrySrc2Ready = List.generate(
      depth,
      (i) => Logic(name: 'iq_s2rdy_$i'),
    );
    final entrySrc1Value = List.generate(
      depth,
      (i) => Logic(name: 'iq_s1val_$i', width: xlen),
    );
    final entrySrc2Value = List.generate(
      depth,
      (i) => Logic(name: 'iq_s2val_$i', width: xlen),
    );
    final entryPsrc1 = List.generate(
      depth,
      (i) => Logic(name: 'iq_psrc1_$i', width: physRegBits),
    );
    final entryPsrc2 = List.generate(
      depth,
      (i) => Logic(name: 'iq_psrc2_$i', width: physRegBits),
    );
    final entryImm = List.generate(
      depth,
      (i) => Logic(name: 'iq_imm_$i', width: xlen),
    );
    final entryPc = List.generate(
      depth,
      (i) => Logic(name: 'iq_pc_$i', width: xlen),
    );
    final entryFunct = List.generate(
      depth,
      (i) => Logic(name: 'iq_funct_$i', width: 7),
    );
    final entryIsStore = List.generate(
      depth,
      (i) => Logic(name: 'iq_isstore_$i'),
    );
    final entryMemSize = List.generate(
      depth,
      (i) => Logic(name: 'iq_memsize_$i', width: 3),
    );
    final entryBranchCond = List.generate(
      depth,
      (i) => Logic(name: 'iq_brcond_$i', width: 3),
    );
    final entryIsJump = List.generate(
      depth,
      (i) => Logic(name: 'iq_isjump_$i'),
    );
    final entryIsJalr = List.generate(
      depth,
      (i) => Logic(name: 'iq_isjalr_$i'),
    );
    final entryUseImm = List.generate(
      depth,
      (i) => Logic(name: 'iq_useimm_$i'),
    );
    final entryCsrOp = List.generate(
      depth,
      (i) => Logic(name: 'iq_csrop_$i', width: 3),
    );
    final entryCsrAddr = List.generate(
      depth,
      (i) => Logic(name: 'iq_csraddr_$i', width: 12),
    );
    final entrySignExtend = List.generate(
      depth,
      (i) => Logic(name: 'iq_signext_$i'),
    );
    // Per-entry program-order sequence number (LSQ in-order mem dispatch). An
    // 8-bit counter assigned at enqueue; the in-flight window (<= depth) is far
    // below 128, so a signed difference orders any two entries unambiguously.
    final entrySeq = List.generate(
      depth,
      (i) => Logic(name: 'iq_seq_$i', width: 8),
    );
    final seqCtr = Logic(name: 'iq_seq_ctr', width: 8);

    // Count of valid entries
    final count = Logic(name: 'iq_count', width: (depth + 1).bitLength);

    // Ready: can accept 2 entries
    enqReady <= count.lt(Const(depth - 1, width: count.width));

    // Find free slots for enqueue (first two invalid entries)
    final freeSlot0 = Logic(name: 'free_slot_0', width: depth.bitLength);
    final freeSlot1 = Logic(name: 'free_slot_1', width: depth.bitLength);
    final freeFound0 = Logic(name: 'free_found_0');
    final freeFound1 = Logic(name: 'free_found_1');

    // Combinational priority encoder for free slots
    final freeSlotConds0 = <Iff>[];
    final freeSlotConds1 = <Iff>[];

    // Build priority chain for slot 0
    freeSlotConds0.add(
      Iff(~entryValid[0], [
        freeSlot0 < Const(0, width: depth.bitLength),
        freeFound0 < 1,
      ]),
    );
    for (var i = 1; i < depth; i++) {
      freeSlotConds0.add(
        ElseIf(~entryValid[i], [
          freeSlot0 < Const(i, width: depth.bitLength),
          freeFound0 < 1,
        ]),
      );
    }
    freeSlotConds0.add(Else([freeSlot0 < 0, freeFound0 < 0]));

    Combinational([If.block(freeSlotConds0)]);

    // Build priority chain for slot 1 (skip slot 0's pick)
    // This is simplified: in real hardware, would be a proper second encoder
    freeSlotConds1.add(Iff(Const(0), [freeSlot1 < 0, freeFound1 < 0]));
    for (var i = 0; i < depth; i++) {
      freeSlotConds1.add(
        ElseIf(
          ~entryValid[i] & ~freeSlot0.eq(Const(i, width: depth.bitLength)),
          [freeSlot1 < Const(i, width: depth.bitLength), freeFound1 < 1],
        ),
      );
    }
    freeSlotConds1.add(Else([freeSlot1 < 0, freeFound1 < 0]));

    Combinational([If.block(freeSlotConds1)]);

    // -----------------------------------------------------------------------
    // Combinational dispatch: find oldest ready entry per FU type
    // -----------------------------------------------------------------------

    // An entry is ready to dispatch when valid, both sources ready, and FU free
    final entryReady = List.generate(
      depth,
      (i) => (entryValid[i] & entrySrc1Ready[i] & entrySrc2Ready[i]).named(
        'iq_ready_$i',
      ),
    );

    // ALU type = 0
    final aluType = Const(FuType.alu.index, width: 2);
    final memType = Const(FuType.memory.index, width: 2);
    final branchType = Const(FuType.branch.index, width: 2);
    final csrType = Const(FuType.csr.index, width: 2);

    // Dispatch index for each FU (priority encoder: lowest index wins)
    final dispAlu0Idx = Logic(name: 'disp_alu0_idx', width: depth.bitLength);
    final dispAlu0Found = Logic(name: 'disp_alu0_found');
    final dispAlu1Idx = Logic(name: 'disp_alu1_idx', width: depth.bitLength);
    final dispAlu1Found = Logic(name: 'disp_alu1_found');
    final dispMemIdx = Logic(name: 'disp_mem_idx', width: depth.bitLength);
    final dispMemFound = Logic(name: 'disp_mem_found');
    final dispBranchIdx = Logic(
      name: 'disp_branch_idx',
      width: depth.bitLength,
    );
    final dispBranchFound = Logic(name: 'disp_branch_found');
    final dispCsrIdx = Logic(name: 'disp_csr_idx', width: depth.bitLength);
    final dispCsrFound = Logic(name: 'disp_csr_found');

    // Priority encoder for ALU slot 0
    final alu0Conds = <Iff>[];
    for (var i = 0; i < depth; i++) {
      final cond = entryReady[i] & entryFuType[i].eq(aluType) & ~aluBusy0;
      if (i == 0) {
        alu0Conds.add(
          Iff(cond, [
            dispAlu0Idx < Const(i, width: depth.bitLength),
            dispAlu0Found < 1,
          ]),
        );
      } else {
        alu0Conds.add(
          ElseIf(cond, [
            dispAlu0Idx < Const(i, width: depth.bitLength),
            dispAlu0Found < 1,
          ]),
        );
      }
    }
    alu0Conds.add(Else([dispAlu0Idx < 0, dispAlu0Found < 0]));
    Combinational([If.block(alu0Conds)]);

    // Priority encoder for ALU slot 1 (skip ALU0's pick)
    final alu1Conds = <Iff>[];
    alu1Conds.add(Iff(Const(0), [dispAlu1Idx < 0, dispAlu1Found < 0]));
    for (var i = 0; i < depth; i++) {
      final cond =
          entryReady[i] &
          entryFuType[i].eq(aluType) &
          ~aluBusy1 &
          ~dispAlu0Idx.eq(Const(i, width: depth.bitLength));
      alu1Conds.add(
        ElseIf(cond, [
          dispAlu1Idx < Const(i, width: depth.bitLength),
          dispAlu1Found < 1,
        ]),
      );
    }
    alu1Conds.add(Else([dispAlu1Idx < 0, dispAlu1Found < 0]));
    Combinational([If.block(alu1Conds)]);

    // Memory dispatch select.
    if (speculativeMem) {
      // Speculative LSQ: a store is eligible only as the oldest undispatched
      // store (program-order store↔store) and with queue room; a load is
      // eligible as the oldest undispatched load, it may bypass a not-ready
      // older store. Among eligible memory ops, dispatch the oldest.
      final elig = <Logic>[];
      for (var i = 0; i < depth; i++) {
        final isMemI = entryValid[i] & entryFuType[i].eq(memType);
        final isStoreI = isMemI & entryIsStore[i];
        final isLoadI = isMemI & ~entryIsStore[i];
        Logic anyOlderStore = Const(0);
        Logic anyOlderLoad = Const(0);
        for (var j = 0; j < depth; j++) {
          if (j == i) continue;
          final isMemJ = entryValid[j] & entryFuType[j].eq(memType);
          final jOlder = isMemJ & (entrySeq[j] - entrySeq[i])[7];
          anyOlderStore = anyOlderStore | (jOlder & entryIsStore[j]);
          anyOlderLoad = anyOlderLoad | (jOlder & ~entryIsStore[j]);
        }
        final eligStore = isStoreI & ~anyOlderStore & ~sqFullIn;
        final eligLoad = isLoadI & ~anyOlderLoad;
        elig.add(((eligStore | eligLoad) & entryReady[i]).named('iq_melig_$i'));
      }
      final memConds = <Iff>[];
      for (var i = 0; i < depth; i++) {
        Logic anyOlderElig = Const(0);
        for (var j = 0; j < depth; j++) {
          if (j == i) continue;
          anyOlderElig =
              anyOlderElig | (elig[j] & (entrySeq[j] - entrySeq[i])[7]);
        }
        final cond = elig[i] & ~anyOlderElig & ~memBusy;
        memConds.add(
          i == 0
              ? Iff(cond, [
                  dispMemIdx < Const(i, width: depth.bitLength),
                  dispMemFound < 1,
                ])
              : ElseIf(cond, [
                  dispMemIdx < Const(i, width: depth.bitLength),
                  dispMemFound < 1,
                ]),
        );
      }
      memConds.add(Else([dispMemIdx < 0, dispMemFound < 0]));
      Combinational([If.block(memConds)]);
    } else if (!inOrderMem) {
      // Default: priority encoder by entry index (memory ops may reorder).
      final memConds = <Iff>[];
      for (var i = 0; i < depth; i++) {
        final cond = entryReady[i] & entryFuType[i].eq(memType) & ~memBusy;
        if (i == 0) {
          memConds.add(
            Iff(cond, [
              dispMemIdx < Const(i, width: depth.bitLength),
              dispMemFound < 1,
            ]),
          );
        } else {
          memConds.add(
            ElseIf(cond, [
              dispMemIdx < Const(i, width: depth.bitLength),
              dispMemFound < 1,
            ]),
          );
        }
      }
      memConds.add(Else([dispMemIdx < 0, dispMemFound < 0]));
      Combinational([If.block(memConds)]);
    } else {
      // LSQ mode: dispatch the OLDEST memory op (smallest program-order seq),
      // and only when it is ready, a not-ready older memory op blocks younger
      // ones. This keeps the store queue holding strictly older stores than any
      // executing load, and serializes memory in program order. A store is also
      // gated on store-queue room (~sqFull) so it never dispatches with no slot.
      //
      // Per entry: it is the oldest memory op iff no other valid memory entry
      // has an older sequence number. Exactly one valid memory entry satisfies
      // this, so a plain OR over (isOldest & ready & ...) selects it.
      final memConds = <Iff>[];
      for (var i = 0; i < depth; i++) {
        final isMemI = entryValid[i] & entryFuType[i].eq(memType);
        // Is any other valid memory entry older (smaller seq) than entry i?
        Logic anyOlder = Const(0);
        for (var j = 0; j < depth; j++) {
          if (j == i) continue;
          final isMemJ = entryValid[j] & entryFuType[j].eq(memType);
          // j older than i: signed 8-bit (seq[j] - seq[i]) is negative.
          final jOlder = isMemJ & (entrySeq[j] - entrySeq[i])[7];
          anyOlder = anyOlder | jOlder;
        }
        final isOldest = isMemI & ~anyOlder;
        final storeOk = ~entryIsStore[i] | ~sqFullIn;
        final cond = isOldest & entryReady[i] & ~memBusy & storeOk;
        if (i == 0) {
          memConds.add(
            Iff(cond, [
              dispMemIdx < Const(i, width: depth.bitLength),
              dispMemFound < 1,
            ]),
          );
        } else {
          memConds.add(
            ElseIf(cond, [
              dispMemIdx < Const(i, width: depth.bitLength),
              dispMemFound < 1,
            ]),
          );
        }
      }
      memConds.add(Else([dispMemIdx < 0, dispMemFound < 0]));
      Combinational([If.block(memConds)]);
    }

    // Priority encoder for branch
    final branchConds = <Iff>[];
    for (var i = 0; i < depth; i++) {
      final cond = entryReady[i] & entryFuType[i].eq(branchType) & ~branchBusy;
      if (i == 0) {
        branchConds.add(
          Iff(cond, [
            dispBranchIdx < Const(i, width: depth.bitLength),
            dispBranchFound < 1,
          ]),
        );
      } else {
        branchConds.add(
          ElseIf(cond, [
            dispBranchIdx < Const(i, width: depth.bitLength),
            dispBranchFound < 1,
          ]),
        );
      }
    }
    branchConds.add(Else([dispBranchIdx < 0, dispBranchFound < 0]));
    Combinational([If.block(branchConds)]);

    // Priority encoder for CSR
    final csrConds = <Iff>[];
    for (var i = 0; i < depth; i++) {
      final cond = entryReady[i] & entryFuType[i].eq(csrType) & ~csrBusy;
      if (i == 0) {
        csrConds.add(
          Iff(cond, [
            dispCsrIdx < Const(i, width: depth.bitLength),
            dispCsrFound < 1,
          ]),
        );
      } else {
        csrConds.add(
          ElseIf(cond, [
            dispCsrIdx < Const(i, width: depth.bitLength),
            dispCsrFound < 1,
          ]),
        );
      }
    }
    csrConds.add(Else([dispCsrIdx < 0, dispCsrFound < 0]));
    Combinational([If.block(csrConds)]);

    // Helper: mux an entry field by dispatch index
    Logic muxField(List<Logic> field, Logic idx) {
      Logic result = field[0];
      for (var i = 1; i < depth; i++) {
        result = mux(
          idx.eq(Const(i, width: depth.bitLength)),
          field[i],
          result,
        );
      }
      return result;
    }

    // Drive ALU 0 dispatch outputs
    dispatchAluValid0 <= dispAlu0Found;
    output('dispatch_alu_tag_0') <= muxField(entryTag, dispAlu0Idx);
    output('dispatch_alu_src1_0') <= muxField(entrySrc1Value, dispAlu0Idx);
    output('dispatch_alu_src2_0') <= muxField(entrySrc2Value, dispAlu0Idx);
    output('dispatch_alu_imm_0') <= muxField(entryImm, dispAlu0Idx);
    output('dispatch_alu_funct_0') <= muxField(entryFunct, dispAlu0Idx);
    output('dispatch_alu_use_imm_0') <= muxField(entryUseImm, dispAlu0Idx);
    output('dispatch_alu_pc_0') <= muxField(entryPc, dispAlu0Idx);

    // Drive ALU 1 dispatch outputs
    dispatchAluValid1 <= dispAlu1Found;
    output('dispatch_alu_tag_1') <= muxField(entryTag, dispAlu1Idx);
    output('dispatch_alu_src1_1') <= muxField(entrySrc1Value, dispAlu1Idx);
    output('dispatch_alu_src2_1') <= muxField(entrySrc2Value, dispAlu1Idx);
    output('dispatch_alu_imm_1') <= muxField(entryImm, dispAlu1Idx);
    output('dispatch_alu_funct_1') <= muxField(entryFunct, dispAlu1Idx);
    output('dispatch_alu_use_imm_1') <= muxField(entryUseImm, dispAlu1Idx);
    output('dispatch_alu_pc_1') <= muxField(entryPc, dispAlu1Idx);

    // Drive memory dispatch outputs
    dispatchMemValid <= dispMemFound;
    output('dispatch_mem_tag') <= muxField(entryTag, dispMemIdx);
    output('dispatch_mem_src1') <= muxField(entrySrc1Value, dispMemIdx);
    output('dispatch_mem_src2') <= muxField(entrySrc2Value, dispMemIdx);
    output('dispatch_mem_imm') <= muxField(entryImm, dispMemIdx);
    output('dispatch_mem_is_store') <= muxField(entryIsStore, dispMemIdx);
    output('dispatch_mem_size') <= muxField(entryMemSize, dispMemIdx);
    output('dispatch_mem_sign_extend') <= muxField(entrySignExtend, dispMemIdx);
    output('dispatch_mem_pc') <= muxField(entryPc, dispMemIdx);

    // Drive branch dispatch outputs
    dispatchBranchValid <= dispBranchFound;
    output('dispatch_branch_tag') <= muxField(entryTag, dispBranchIdx);
    output('dispatch_branch_src1') <= muxField(entrySrc1Value, dispBranchIdx);
    output('dispatch_branch_src2') <= muxField(entrySrc2Value, dispBranchIdx);
    output('dispatch_branch_imm') <= muxField(entryImm, dispBranchIdx);
    output('dispatch_branch_pc') <= muxField(entryPc, dispBranchIdx);
    output('dispatch_branch_condition') <=
        muxField(entryBranchCond, dispBranchIdx);
    output('dispatch_branch_is_jump') <= muxField(entryIsJump, dispBranchIdx);
    output('dispatch_branch_is_jalr') <= muxField(entryIsJalr, dispBranchIdx);

    // Drive CSR dispatch outputs
    dispatchCsrValid <= dispCsrFound;
    output('dispatch_csr_tag') <= muxField(entryTag, dispCsrIdx);
    output('dispatch_csr_src1') <= muxField(entrySrc1Value, dispCsrIdx);
    output('dispatch_csr_imm') <= muxField(entryImm, dispCsrIdx);
    output('dispatch_csr_op') <= muxField(entryCsrOp, dispCsrIdx);
    output('dispatch_csr_addr') <= muxField(entryCsrAddr, dispCsrIdx);

    // Program-order sequence numbers assigned to enqueuing instructions. Slot 0
    // is older than slot 1; the counter advances by the number enqueued.
    final enq0 = (enqValid0 & freeFound0).named('iq_enq0');
    final enq1 = (enqValid1 & freeFound1).named('iq_enq1');
    final enqSeq0 = seqCtr;
    final enqSeq1 = (seqCtr + enq0.zeroExtend(8)).named('iq_enq_seq1');

    Sequential(clk, [
      If(
        reset | flush,
        then: [
          count < 0,
          seqCtr < 0,
          ...List.generate(depth, (i) => entrySeq[i] < 0),
          ...List.generate(depth, (i) => entryValid[i] < 0),
          ...List.generate(depth, (i) => entryTag[i] < 0),
          ...List.generate(depth, (i) => entryFuType[i] < 0),
          ...List.generate(depth, (i) => entrySrc1Ready[i] < 0),
          ...List.generate(depth, (i) => entrySrc2Ready[i] < 0),
          ...List.generate(depth, (i) => entrySrc1Value[i] < 0),
          ...List.generate(depth, (i) => entrySrc2Value[i] < 0),
          // Reset the remaining payload fields too: the dispatch priority muxes
          // read fields across all slots, so an unwritten slot holding X can
          // propagate into a dispatched valid/condition and corrupt the core.
          ...List.generate(depth, (i) => entryPsrc1[i] < 0),
          ...List.generate(depth, (i) => entryPsrc2[i] < 0),
          ...List.generate(depth, (i) => entryImm[i] < 0),
          ...List.generate(depth, (i) => entryPc[i] < 0),
          ...List.generate(depth, (i) => entryFunct[i] < 0),
          ...List.generate(depth, (i) => entryIsStore[i] < 0),
          ...List.generate(depth, (i) => entryMemSize[i] < 0),
          ...List.generate(depth, (i) => entryBranchCond[i] < 0),
          ...List.generate(depth, (i) => entryIsJump[i] < 0),
          ...List.generate(depth, (i) => entryIsJalr[i] < 0),
          ...List.generate(depth, (i) => entryUseImm[i] < 0),
          ...List.generate(depth, (i) => entryCsrOp[i] < 0),
          ...List.generate(depth, (i) => entryCsrAddr[i] < 0),
          ...List.generate(depth, (i) => entrySignExtend[i] < 0),
        ],
        orElse: [
          // Wake-up: broadcast result to waiting entries
          for (var i = 0; i < depth; i++) ...[
            If(
              entryValid[i] &
                  ~entrySrc1Ready[i] &
                  wakeupValid0 &
                  entryPsrc1[i].eq(wakeupTag0),
              then: [entrySrc1Ready[i] < 1, entrySrc1Value[i] < wakeupValue0],
            ),
            If(
              entryValid[i] &
                  ~entrySrc2Ready[i] &
                  wakeupValid0 &
                  entryPsrc2[i].eq(wakeupTag0),
              then: [entrySrc2Ready[i] < 1, entrySrc2Value[i] < wakeupValue0],
            ),
            If(
              entryValid[i] &
                  ~entrySrc1Ready[i] &
                  wakeupValid1 &
                  entryPsrc1[i].eq(wakeupTag1),
              then: [entrySrc1Ready[i] < 1, entrySrc1Value[i] < wakeupValue1],
            ),
            If(
              entryValid[i] &
                  ~entrySrc2Ready[i] &
                  wakeupValid1 &
                  entryPsrc2[i].eq(wakeupTag1),
              then: [entrySrc2Ready[i] < 1, entrySrc2Value[i] < wakeupValue1],
            ),
            If(
              entryValid[i] &
                  ~entrySrc1Ready[i] &
                  wuV2 &
                  entryPsrc1[i].eq(wuT2),
              then: [entrySrc1Ready[i] < 1, entrySrc1Value[i] < wuVal2],
            ),
            If(
              entryValid[i] &
                  ~entrySrc2Ready[i] &
                  wuV2 &
                  entryPsrc2[i].eq(wuT2),
              then: [entrySrc2Ready[i] < 1, entrySrc2Value[i] < wuVal2],
            ),
          ],

          // Enqueue slot 0
          If(
            enqValid0 & freeFound0,
            then: [
              Case(freeSlot0, [
                for (var i = 0; i < depth; i++)
                  CaseItem(Const(i, width: depth.bitLength), [
                    entryValid[i] < 1,
                    entryTag[i] < enqTag0,
                    entryFuType[i] < enqFuType0,
                    entryPsrc1[i] < enqPsrc10,
                    entryPsrc2[i] < enqPsrc20,
                    entrySrc1Ready[i] < enqSrc1Ready0,
                    entrySrc2Ready[i] < enqSrc2Ready0,
                    entrySrc1Value[i] < enqSrc1Value0,
                    entrySrc2Value[i] < enqSrc2Value0,
                    entryImm[i] < enqImm0,
                    entryPc[i] < enqPc0,
                    entryFunct[i] < enqFunct0,
                    entryIsStore[i] < enqIsStore0,
                    entryMemSize[i] < enqMemSize0,
                    entryBranchCond[i] < enqBranchCond0,
                    entryIsJump[i] < enqIsJump0,
                    entryIsJalr[i] < enqIsJalr0,
                    entryUseImm[i] < enqUseImm0,
                    entryCsrOp[i] < enqCsrOp0,
                    entryCsrAddr[i] < enqCsrAddr0,
                    entrySignExtend[i] < enqSignExtend0,
                    entrySeq[i] < enqSeq0,
                  ]),
              ]),
            ],
          ),

          // Enqueue slot 1
          If(
            enqValid1 & freeFound1,
            then: [
              Case(freeSlot1, [
                for (var i = 0; i < depth; i++)
                  CaseItem(Const(i, width: depth.bitLength), [
                    entryValid[i] < 1,
                    entryTag[i] < enqTag1,
                    entryFuType[i] < enqFuType1,
                    entryPsrc1[i] < enqPsrc11,
                    entryPsrc2[i] < enqPsrc21,
                    entrySrc1Ready[i] < enqSrc1Ready1,
                    entrySrc2Ready[i] < enqSrc2Ready1,
                    entrySrc1Value[i] < enqSrc1Value1,
                    entrySrc2Value[i] < enqSrc2Value1,
                    entryImm[i] < enqImm1,
                    entryPc[i] < enqPc1,
                    entryFunct[i] < enqFunct1,
                    entryIsStore[i] < enqIsStore1,
                    entryMemSize[i] < enqMemSize1,
                    entryBranchCond[i] < enqBranchCond1,
                    entryIsJump[i] < enqIsJump1,
                    entryIsJalr[i] < enqIsJalr1,
                    entryUseImm[i] < enqUseImm1,
                    entryCsrOp[i] < enqCsrOp1,
                    entryCsrAddr[i] < enqCsrAddr1,
                    entrySignExtend[i] < enqSignExtend1,
                    entrySeq[i] < enqSeq1,
                  ]),
              ]),
            ],
          ),

          // Advance the program-order sequence counter past whatever enqueued.
          seqCtr < seqCtr + enq0.zeroExtend(8) + enq1.zeroExtend(8),

          // Invalidate dispatched entries
          for (var i = 0; i < depth; i++) ...[
            If(
              dispAlu0Found & dispAlu0Idx.eq(Const(i, width: depth.bitLength)),
              then: [entryValid[i] < 0],
            ),
            If(
              dispAlu1Found & dispAlu1Idx.eq(Const(i, width: depth.bitLength)),
              then: [entryValid[i] < 0],
            ),
            If(
              dispMemFound & dispMemIdx.eq(Const(i, width: depth.bitLength)),
              then: [entryValid[i] < 0],
            ),
            If(
              dispBranchFound &
                  dispBranchIdx.eq(Const(i, width: depth.bitLength)),
              then: [entryValid[i] < 0],
            ),
            If(
              dispCsrFound & dispCsrIdx.eq(Const(i, width: depth.bitLength)),
              then: [entryValid[i] < 0],
            ),
          ],

          // Occupancy: a SINGLE net update. Enqueue (+) and dispatch (-) can both
          // happen in the same cycle (e.g. when allocation runs at 1/cycle), so
          // scattered `count < count+1` / `count < count-1` conditionals would
          // conflict on `count` (last-write-wins / X) and wedge enqReady. Sum the
          // events and apply the delta once. enq{0,1} and disp*Found are all
          // single-bit fire flags.
          count <
              (count +
                  enq0.zeroExtend(count.width) +
                  enq1.zeroExtend(count.width) -
                  dispAlu0Found.zeroExtend(count.width) -
                  dispAlu1Found.zeroExtend(count.width) -
                  dispMemFound.zeroExtend(count.width) -
                  dispBranchFound.zeroExtend(count.width) -
                  dispCsrFound.zeroExtend(count.width)),
        ],
      ),
    ]);
  }
}
