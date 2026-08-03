import 'package:rohd/rohd.dart';

import 'alu_ops.dart';

/// Branch functional unit.
///
/// Resolves conditional branches (BEQ, BNE, BLT, BGE, BLTU, BGEU)
/// and jumps (JAL, JALR). Single-cycle resolution.
/// Produces a redirect signal when a branch is mispredicted.
class BranchUnit extends Module {
  final int xlen;

  Logic get resultValid => output('result_valid');
  Logic get resultTag => output('result_tag');
  Logic get resultData => output('result_data');
  Logic get resultException => output('result_exception');
  Logic get resultCause => output('result_cause');

  /// Whether a redirect (misprediction recovery) is needed.
  Logic get redirect => output('redirect');

  /// The corrected PC after branch resolution.
  Logic get redirectPc => output('redirect_pc');

  Logic get busy => output('busy');

  BranchUnit(
    Logic clk,
    Logic reset, {
    required Logic issueValid,
    required Logic issueTag,
    required Logic issueSrc1,
    required Logic issueSrc2,
    required Logic issueImm,
    required Logic issuePc,
    required Logic issueCondition,
    required Logic issueIsJump,
    required Logic issueIsJalr,
    required Logic issueIsCompressed,
    required Logic issuePredictedTaken,
    required Logic flush,
    this.xlen = 64,
    int robTagBits = 7,
    super.name = 'branch_unit',
  }) : super(definitionName: 'BranchUnit') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    // Issue interface
    issueValid = addInput('issue_valid', issueValid);
    issueTag = addInput('issue_tag', issueTag, width: robTagBits);
    issueSrc1 = addInput('issue_src1', issueSrc1, width: xlen);
    issueSrc2 = addInput('issue_src2', issueSrc2, width: xlen);
    issueImm = addInput('issue_imm', issueImm, width: xlen);
    issuePc = addInput('issue_pc', issuePc, width: xlen);

    /// Branch condition (funct3 encoding):
    ///   0=BEQ, 1=BNE, 4=BLT, 5=BGE, 6=BLTU, 7=BGEU
    issueCondition = addInput('issue_condition', issueCondition, width: 3);

    /// Whether this is an unconditional jump (JAL/JALR).
    issueIsJump = addInput('issue_is_jump', issueIsJump);

    /// Whether this is JALR (target = rs1 + imm, not pc + imm).
    issueIsJalr = addInput('issue_is_jalr', issueIsJalr);

    /// Whether the branch/jump instruction was a 2-byte compressed (RVC) op, so
    /// the link (return) address is PC+2 rather than PC+4.
    issueIsCompressed = addInput('issue_is_compressed', issueIsCompressed);

    /// Predicted taken (from front-end, for detecting mispredictions).
    issuePredictedTaken = addInput(
      'issue_predicted_taken',
      issuePredictedTaken,
    );

    // Flush
    flush = addInput('flush', flush);

    // Result interface
    addOutput('result_valid');
    addOutput('result_tag', width: robTagBits);
    addOutput('result_data', width: xlen); // link address for JAL/JALR
    addOutput('result_exception');
    addOutput('result_cause', width: 6);
    addOutput('redirect');
    addOutput('redirect_pc', width: xlen);
    addOutput('busy');

    // Branch condition evaluation (combinational)
    final branchTaken = Logic(name: 'branch_taken');

    Combinational([
      Case(
        issueCondition,
        [
          CaseItem(Const(0, width: 3), [
            // BEQ
            branchTaken < issueSrc1.eq(issueSrc2),
          ]),
          CaseItem(Const(1, width: 3), [
            // BNE
            branchTaken < issueSrc1.neq(issueSrc2),
          ]),
          CaseItem(Const(4, width: 3), [
            // BLT (signed): .lt is unsigned, so use the signed-compare helper.
            branchTaken < bmSignedLt(issueSrc1, issueSrc2, xlen),
          ]),
          CaseItem(Const(5, width: 3), [
            // BGE (signed): not-less-than (signed).
            branchTaken < ~bmSignedLt(issueSrc1, issueSrc2, xlen),
          ]),
          CaseItem(Const(6, width: 3), [
            // BLTU (unsigned)
            branchTaken < issueSrc1.lt(issueSrc2),
          ]),
          CaseItem(Const(7, width: 3), [
            // BGEU (unsigned)
            branchTaken < issueSrc1.gte(issueSrc2),
          ]),
        ],
        defaultItem: [branchTaken < Const(0)],
      ),
    ]);

    // Target computation
    final branchTarget = mux(
      issueIsJalr,
      issueSrc1 + issueImm,
      issuePc + issueImm,
    ).named('branch_target');

    // Next sequential PC (for not-taken branches and link address). The link
    // (rd = return address) must be PC + instruction length: 2 for a compressed
    // call (c.jalr), 4 for full-width. A fixed +4 returned two bytes past a
    // c.jalr, corrupting every function-pointer/vtable call.
    final nextPc =
        (issuePc +
                mux(
                  issueIsCompressed,
                  Const(2, width: xlen),
                  Const(4, width: xlen),
                ))
            .named('next_pc');

    // Actual taken: unconditional jumps are always taken
    final actualTaken = (issueIsJump | branchTaken).named('actual_taken');

    // Misprediction detection
    final mispredicted = (actualTaken ^ issuePredictedTaken).named(
      'mispredicted',
    );

    // Single-cycle: all branch ops complete immediately
    Sequential(clk, [
      If(
        reset,
        then: [
          resultValid < 0,
          resultTag < 0,
          resultData < 0,
          resultException < 0,
          resultCause < 0,
          redirect < 0,
          redirectPc < 0,
          busy < 0,
        ],
        orElse: [
          If(
            issueValid,
            then: [
              resultValid < 1,
              resultTag < issueTag,
              // Link address for JAL/JALR (rd = PC+4)
              resultData < nextPc,
              resultException < 0,
              resultCause < 0,
              redirect < mispredicted,
              redirectPc < mux(actualTaken, branchTarget, nextPc),
              busy < 0,
            ],
            orElse: [resultValid < 0, redirect < 0, busy < 0],
          ),
        ],
      ),
    ]);
  }
}
