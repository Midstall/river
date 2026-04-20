import 'package:rohd/rohd.dart';
import 'package:harbor/harbor.dart' hide PrivilegeMode;
import 'alu_ops.dart';

/// ALU functional unit.
///
/// Combinational ALU with 1-cycle latency for basic operations.
/// Mul/div use a multi-cycle state machine.
/// Supports dual instantiation for 2-wide issue.
class AluUnit extends Module {
  final int xlen;

  /// Cycles from issue to result for mul/div (>= 2). Their datapath is held
  /// between operand and result registers across this window, a clean
  /// multi-cycle path for ASIC timing closure (constrain it in SDC).
  final int mulDivLatency;

  Logic get resultValid => output('result_valid');
  Logic get resultTag => output('result_tag');
  Logic get resultData => output('result_data');
  Logic get resultException => output('result_exception');
  Logic get resultCause => output('result_cause');
  Logic get busy => output('busy');

  AluUnit(
    Logic clk,
    Logic reset, {
    required Logic issueValid,
    required Logic issueTag,
    required Logic issueSrc1,
    required Logic issueSrc2,
    required Logic issueImm,
    required Logic issueFunct,
    required Logic issueUseImm,
    required Logic issuePc,
    required Logic flush,
    this.xlen = 64,
    int robTagBits = 7,
    this.mulDivLatency = 4,
    super.name = 'alu_unit',
  }) : assert(mulDivLatency >= 2, 'mul/div multi-cycle latency must be >= 2'),
       super(definitionName: 'AluUnit') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    // Issue interface
    issueValid = addInput('issue_valid', issueValid);
    issueTag = addInput('issue_tag', issueTag, width: robTagBits);
    issueSrc1 = addInput('issue_src1', issueSrc1, width: xlen);
    issueSrc2 = addInput('issue_src2', issueSrc2, width: xlen);
    issueImm = addInput('issue_imm', issueImm, width: xlen);
    issueFunct = addInput('issue_funct', issueFunct, width: 7);
    issueUseImm = addInput('issue_use_imm', issueUseImm);
    issuePc = addInput('issue_pc', issuePc, width: xlen);

    // Flush
    flush = addInput('flush', flush);

    // Result interface
    addOutput('result_valid');
    addOutput('result_tag', width: robTagBits);
    addOutput('result_data', width: xlen);
    addOutput('result_exception');
    addOutput('result_cause', width: 6);
    addOutput('busy');

    final operand2 = mux(issueUseImm, issueImm, issueSrc2);

    // Single-cycle ALU operations
    final aluResult = Logic(name: 'alu_result', width: xlen);

    // Single-cycle ALU op set, matching the in-order ALU (exec.dart) so both
    // datapaths agree. funct is 7 bits (RiscVAluFunct has >32 values).
    // Bitmanip uses the shared alu_ops helpers. The mul/div family is NOT in
    // this Case: it executes on the latched multi-cycle path below.
    CaseItem ci(RiscVAluFunct f, Logic result) =>
        CaseItem(Const(f.index, width: 7), [aluResult < result]);
    final mask = Const(xlen - 1, width: xlen);
    Logic bit1(Logic shamt) => Const(1, width: xlen) << (shamt & mask);

    Combinational([
      Case(
        issueFunct,
        [
          ci(RiscVAluFunct.add, issueSrc1 + operand2),
          ci(RiscVAluFunct.sub, issueSrc1 - operand2),
          ci(RiscVAluFunct.and_, issueSrc1 & operand2),
          ci(RiscVAluFunct.or_, issueSrc1 | operand2),
          ci(RiscVAluFunct.xor_, issueSrc1 ^ operand2),
          ci(RiscVAluFunct.sll, issueSrc1 << operand2.slice(5, 0)),
          ci(RiscVAluFunct.srl, issueSrc1 >>> operand2.slice(5, 0)),
          ci(RiscVAluFunct.sra, issueSrc1 >> operand2.slice(5, 0)),
          ci(
            RiscVAluFunct.slt,
            bmSignedLt(issueSrc1, operand2, xlen).zeroExtend(xlen),
          ),
          ci(RiscVAluFunct.sltu, issueSrc1.lt(operand2).zeroExtend(xlen)),
          // 32-bit word variants
          ci(
            RiscVAluFunct.addw,
            (issueSrc1 + operand2).slice(31, 0).signExtend(xlen),
          ),
          ci(
            RiscVAluFunct.subw,
            (issueSrc1 - operand2).slice(31, 0).signExtend(xlen),
          ),
          ci(
            RiscVAluFunct.sllw,
            (issueSrc1.slice(31, 0) << operand2.slice(4, 0)).signExtend(xlen),
          ),
          ci(
            RiscVAluFunct.srlw,
            (issueSrc1.slice(31, 0) >>> operand2.slice(4, 0)).signExtend(xlen),
          ),
          ci(
            RiscVAluFunct.sraw,
            (issueSrc1.slice(31, 0) >> operand2.slice(4, 0)).signExtend(xlen),
          ),
          // M extension (mul/div) is handled by the multi-cycle path below,
          // not this single-cycle Case, so its heavy datapath is registered.
          // Zbb logical-with-negate + extends
          ci(RiscVAluFunct.andn, issueSrc1 & ~operand2),
          ci(RiscVAluFunct.orn, issueSrc1 | ~operand2),
          ci(RiscVAluFunct.xnor, ~(issueSrc1 ^ operand2)),
          ci(RiscVAluFunct.sextb, issueSrc1.slice(7, 0).signExtend(xlen)),
          ci(RiscVAluFunct.sexth, issueSrc1.slice(15, 0).signExtend(xlen)),
          ci(RiscVAluFunct.zexth, issueSrc1.slice(15, 0).zeroExtend(xlen)),
          ci(RiscVAluFunct.zextb, issueSrc1.slice(7, 0).zeroExtend(xlen)),
          ci(RiscVAluFunct.zextw, issueSrc1.slice(31, 0).zeroExtend(xlen)),
          ci(RiscVAluFunct.notOp, ~issueSrc1),
          // Zbb min/max
          ci(
            RiscVAluFunct.minOp,
            mux(bmSignedLt(issueSrc1, operand2, xlen), issueSrc1, operand2),
          ),
          ci(
            RiscVAluFunct.maxOp,
            mux(bmSignedLt(issueSrc1, operand2, xlen), operand2, issueSrc1),
          ),
          ci(
            RiscVAluFunct.minuOp,
            mux(issueSrc1.lt(operand2), issueSrc1, operand2),
          ),
          ci(
            RiscVAluFunct.maxuOp,
            mux(issueSrc1.lt(operand2), operand2, issueSrc1),
          ),
          // Zbb rotates
          ci(RiscVAluFunct.rol, bmRotl(issueSrc1, operand2, xlen)),
          ci(RiscVAluFunct.ror, bmRotr(issueSrc1, operand2, xlen)),
          ci(
            RiscVAluFunct.rolw,
            bmRotl(
              issueSrc1.slice(31, 0),
              operand2.slice(31, 0),
              32,
            ).signExtend(xlen),
          ),
          ci(
            RiscVAluFunct.rorw,
            bmRotr(
              issueSrc1.slice(31, 0),
              operand2.slice(31, 0),
              32,
            ).signExtend(xlen),
          ),
          // Zbb counts
          ci(RiscVAluFunct.clz, bmClz(issueSrc1, xlen)),
          ci(RiscVAluFunct.ctz, bmCtz(issueSrc1, xlen)),
          ci(RiscVAluFunct.cpop, bmPopcount(issueSrc1, xlen)),
          ci(
            RiscVAluFunct.clzw,
            bmClz(issueSrc1.slice(31, 0), 32).zeroExtend(xlen),
          ),
          ci(
            RiscVAluFunct.ctzw,
            bmCtz(issueSrc1.slice(31, 0), 32).zeroExtend(xlen),
          ),
          ci(
            RiscVAluFunct.cpopw,
            bmPopcount(issueSrc1.slice(31, 0), 32).zeroExtend(xlen),
          ),
          // Zbb byte ops
          ci(RiscVAluFunct.orcb, bmOrcb(issueSrc1, xlen)),
          ci(RiscVAluFunct.rev8, bmRev8(issueSrc1, xlen)),
          // Zba shift-add (and unsigned-word forms)
          ci(RiscVAluFunct.sh1add, (issueSrc1 << 1) + operand2),
          ci(RiscVAluFunct.sh2add, (issueSrc1 << 2) + operand2),
          ci(RiscVAluFunct.sh3add, (issueSrc1 << 3) + operand2),
          ci(
            RiscVAluFunct.adduw,
            issueSrc1.slice(31, 0).zeroExtend(xlen) + operand2,
          ),
          ci(
            RiscVAluFunct.sh1adduw,
            (issueSrc1.slice(31, 0).zeroExtend(xlen) << 1) + operand2,
          ),
          ci(
            RiscVAluFunct.sh2adduw,
            (issueSrc1.slice(31, 0).zeroExtend(xlen) << 2) + operand2,
          ),
          ci(
            RiscVAluFunct.sh3adduw,
            (issueSrc1.slice(31, 0).zeroExtend(xlen) << 3) + operand2,
          ),
          // Zbs single-bit
          ci(RiscVAluFunct.bset, issueSrc1 | bit1(operand2)),
          ci(RiscVAluFunct.bclr, issueSrc1 & ~bit1(operand2)),
          ci(RiscVAluFunct.binv, issueSrc1 ^ bit1(operand2)),
          ci(
            RiscVAluFunct.bext,
            (issueSrc1 >>> (operand2 & mask)) & Const(1, width: xlen),
          ),
          // Zicond
          ci(
            RiscVAluFunct.czeroEqz,
            mux(
              operand2.eq(Const(0, width: xlen)),
              Const(0, width: xlen),
              issueSrc1,
            ),
          ),
          ci(
            RiscVAluFunct.czeroNez,
            mux(
              operand2.eq(Const(0, width: xlen)),
              issueSrc1,
              Const(0, width: xlen),
            ),
          ),
        ],
        defaultItem: [aluResult < Const(0, width: xlen)],
      ),
    ]);

    // mul/div: multi-cycle, functionally exact.
    // mul/div are combinationally heavy (a 2*XLEN product / XLEN-wide divide).
    // Instead of completing them in the single-cycle path, latch the operands,
    // raise `busy` (the scheduler then holds off issuing to this unit), and
    // present the result after `mulDivLatency` cycles. The heavy datapath then
    // lives only between the latched-operand and result registers - a clean
    // multi-cycle path to constrain in SDC. Products come from the shared
    // BmMulSet and div/rem from the bmDiv*/bmRem* helpers, the same engines
    // the in-order ALU uses, so both datapaths are functionally exact.
    const mdOps = [
      RiscVAluFunct.mul, RiscVAluFunct.mulw, RiscVAluFunct.mulh,
      RiscVAluFunct.mulhsu, RiscVAluFunct.mulhu, //
      RiscVAluFunct.div, RiscVAluFunct.divu, RiscVAluFunct.divw,
      RiscVAluFunct.divuw, RiscVAluFunct.rem, RiscVAluFunct.remu,
      RiscVAluFunct.remw, RiscVAluFunct.remuw,
    ];
    final isMulDiv = mdOps
        .map((f) => issueFunct.eq(Const(f.index, width: 7)))
        .reduce((a, b) => a | b);

    // Latched operands + control for the in-flight mul/div.
    final mdSrc1 = Logic(name: 'md_src1', width: xlen);
    final mdSrc2 = Logic(name: 'md_src2', width: xlen);
    final mdFunct = Logic(name: 'md_funct', width: 7);
    final mdTag = Logic(name: 'md_tag', width: robTagBits);
    final mdActive = Logic(name: 'md_active');
    final cntBits = mulDivLatency.bitLength;
    final mdCount = Logic(name: 'md_count', width: cntBits);

    // Combinational mul/div result from the LATCHED operands. The whole mul
    // family shares one multiplier (see BmMulSet for the identity).
    final mdResult = Logic(name: 'md_result', width: xlen);
    final mdMul = BmMulSet(mdSrc1, mdSrc2, xlen);
    CaseItem ciMd(RiscVAluFunct f, Logic result) =>
        CaseItem(Const(f.index, width: 7), [mdResult < result]);
    Combinational([
      Case(
        mdFunct,
        [
          ciMd(RiscVAluFunct.mul, mdMul.low),
          ciMd(RiscVAluFunct.mulw, mdMul.low.slice(31, 0).signExtend(xlen)),
          ciMd(RiscVAluFunct.mulh, mdMul.highSS),
          ciMd(RiscVAluFunct.mulhsu, mdMul.highSU),
          ciMd(RiscVAluFunct.mulhu, mdMul.highUU),
          ciMd(RiscVAluFunct.div, bmDivS(mdSrc1, mdSrc2, xlen)),
          ciMd(RiscVAluFunct.divu, bmDivU(mdSrc1, mdSrc2, xlen)),
          ciMd(
            RiscVAluFunct.divw,
            bmDivS(
              mdSrc1.slice(31, 0),
              mdSrc2.slice(31, 0),
              32,
            ).signExtend(xlen),
          ),
          ciMd(
            RiscVAluFunct.divuw,
            bmDivU(
              mdSrc1.slice(31, 0),
              mdSrc2.slice(31, 0),
              32,
            ).signExtend(xlen),
          ),
          ciMd(RiscVAluFunct.rem, bmRemS(mdSrc1, mdSrc2, xlen)),
          ciMd(RiscVAluFunct.remu, bmRemU(mdSrc1, mdSrc2, xlen)),
          ciMd(
            RiscVAluFunct.remw,
            bmRemS(
              mdSrc1.slice(31, 0),
              mdSrc2.slice(31, 0),
              32,
            ).signExtend(xlen),
          ),
          ciMd(
            RiscVAluFunct.remuw,
            bmRemU(
              mdSrc1.slice(31, 0),
              mdSrc2.slice(31, 0),
              32,
            ).signExtend(xlen),
          ),
        ],
        defaultItem: [mdResult < Const(0, width: xlen)],
      ),
    ]);

    // Count is loaded with latency-1 at issue and completes when it reaches 1,
    // so result_valid rises exactly `mulDivLatency` cycles after issue.
    final mdLoad = Const(mulDivLatency - 1, width: cntBits);
    final one = Const(1, width: cntBits);

    Sequential(clk, [
      If(
        reset | flush,
        then: [
          resultValid < 0,
          resultTag < 0,
          resultData < 0,
          resultException < 0,
          resultCause < 0,
          busy < 0,
          mdActive < 0,
          mdCount < 0,
          mdSrc1 < 0,
          mdSrc2 < 0,
          mdFunct < 0,
          mdTag < 0,
        ],
        orElse: [
          If(
            mdActive,
            then: [
              // In-flight mul/div: count down, complete when it reaches 1.
              If(
                mdCount.eq(one),
                then: [
                  resultValid < 1,
                  resultTag < mdTag,
                  resultData < mdResult,
                  resultException < 0,
                  resultCause < 0,
                  mdActive < 0,
                  busy < 0,
                ],
                orElse: [mdCount < mdCount - one, resultValid < 0, busy < 1],
              ),
            ],
            orElse: [
              If(
                issueValid & isMulDiv,
                then: [
                  // Start a multi-cycle mul/div: latch operands, raise busy.
                  mdActive < 1,
                  busy < 1,
                  mdCount < mdLoad,
                  mdTag < issueTag,
                  mdFunct < issueFunct,
                  mdSrc1 < issueSrc1,
                  mdSrc2 < operand2,
                  resultValid < 0,
                ],
                orElse: [
                  If(
                    issueValid,
                    then: [
                      // Single-cycle ALU op.
                      resultValid < 1,
                      resultTag < issueTag,
                      resultData < aluResult,
                      resultException < 0,
                      resultCause < 0,
                      busy < 0,
                    ],
                    orElse: [
                      resultValid < 0,
                      resultTag < 0,
                      resultData < 0,
                      busy < 0,
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
