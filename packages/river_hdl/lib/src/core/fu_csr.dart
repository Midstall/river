import 'package:rohd/rohd.dart';
import '../data_port.dart';

/// CSR functional unit.
///
/// Handles CSR read/write/set/clear operations.
/// Serialised: only one CSR op in flight at a time (no OoO for CSRs).
/// Multi-cycle: cycle 1 reads CSR, cycle 2 writes new value.
class CsrUnit extends Module {
  final int xlen;

  Logic get resultValid => output('result_valid');
  Logic get resultTag => output('result_tag');
  Logic get resultData => output('result_data');
  Logic get resultException => output('result_exception');
  Logic get resultCause => output('result_cause');
  Logic get busy => output('busy');

  CsrUnit(
    Logic clk,
    Logic reset,
    DataPortInterface csrRead,
    DataPortInterface csrWrite, {
    required Logic issueValid,
    required Logic issueTag,
    required Logic issueSrc1,
    required Logic issueImm,
    required Logic issueOp,
    required Logic issueCsrAddr,
    required Logic flush,
    this.xlen = 64,
    int robTagBits = 7,
    super.name = 'csr_unit',
  }) : super(definitionName: 'CsrUnit') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    // Issue interface
    issueValid = addInput('issue_valid', issueValid);
    issueTag = addInput('issue_tag', issueTag, width: robTagBits);
    issueSrc1 = addInput('issue_src1', issueSrc1, width: xlen);
    issueImm = addInput('issue_imm', issueImm, width: xlen);
    issueOp = addInput('issue_op', issueOp, width: 3);
    issueCsrAddr = addInput('issue_csr_addr', issueCsrAddr, width: 12);

    // Flush
    flush = addInput('flush', flush);

    // CSR port connections
    csrRead = csrRead.clone()
      ..connectIO(
        this,
        csrRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'csrRead_$og',
      );

    csrWrite = csrWrite.clone()
      ..connectIO(
        this,
        csrWrite,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'csrWrite_$og',
      );

    // Result interface
    addOutput('result_valid');
    addOutput('result_tag', width: robTagBits);
    addOutput('result_data', width: xlen);
    addOutput('result_exception');
    addOutput('result_cause', width: 6);
    addOutput('busy');

    // FSM: IDLE → READ → WRITE → DONE
    final stateIdle = Const(0, width: 2);
    final stateRead = Const(1, width: 2);
    final stateWrite = Const(2, width: 2);

    final state = Logic(name: 'csr_state', width: 2);
    final savedTag = Logic(name: 'saved_tag', width: robTagBits);
    final savedOp = Logic(name: 'saved_op', width: 3);
    final savedSrc = Logic(name: 'saved_src', width: xlen);
    final savedAddr = Logic(name: 'saved_addr', width: 12);
    final readValue = Logic(name: 'read_value', width: xlen);

    // Computed new CSR value (combinational; valid in stateRead where csrRead.data
    // holds the old value). Mirrors the write-value Case below.
    final newCsrVal = Logic(name: 'new_csr_val', width: xlen);
    Combinational([
      Case(
        savedOp.slice(1, 0),
        [
          CaseItem(Const(1, width: 2), [newCsrVal < savedSrc]), // RW
          CaseItem(Const(2, width: 2), [
            newCsrVal < (csrRead.data | savedSrc), // RS
          ]),
          CaseItem(Const(3, width: 2), [
            newCsrVal < (csrRead.data & ~savedSrc), // RC
          ]),
        ],
        defaultItem: [newCsrVal < savedSrc],
      ),
    ]);
    // A SET/CLEAR (RS/RC, funct3[1]=1) write that does not change the CSR is
    // suppressed entirely (no frontdoor write, no legality check) - this is how
    // csrrs/csrrc rs1=x0 (and csrr*i uimm=0) read a READ-ONLY CSR without taking
    // a write-to-RO illegal trap. csrrw (RW, funct3[1]=0) must ALWAYS write per
    // spec, even when the value is unchanged, so it is never suppressed.
    final writeIsNoOp = (savedOp[1] & newCsrVal.eq(csrRead.data)).named(
      'csrWriteNoOp',
    );

    Sequential(clk, [
      If(
        reset | flush,
        then: [
          state < stateIdle,
          savedTag < 0,
          savedOp < 0,
          savedSrc < 0,
          savedAddr < 0,
          readValue < 0,
          resultValid < 0,
          resultTag < 0,
          resultData < 0,
          resultException < 0,
          resultCause < 0,
          busy < 0,
          csrRead.en < 0,
          csrRead.addr < 0,
          csrWrite.en < 0,
          csrWrite.addr < 0,
          csrWrite.data < 0,
        ],
        orElse: [
          Case(
            state,
            [
              // IDLE
              CaseItem(stateIdle, [
                resultValid < 0,
                If(
                  issueValid,
                  then: [
                    state < stateRead,
                    savedTag < issueTag,
                    savedOp < issueOp,
                    // Immediate variants are csrrwi/csrrsi/csrrci (funct3 5/6/7),
                    // distinguished by BIT 2 - not funct3>=3, which wrongly
                    // flagged csrrc (funct3 3, a register form).
                    savedSrc <
                        mux(issueOp[2], issueImm.zeroExtend(xlen), issueSrc1),
                    savedAddr < issueCsrAddr,
                    busy < 1,
                    // Start CSR read
                    csrRead.en < 1,
                    csrRead.addr < issueCsrAddr,
                    csrWrite.en < 0,
                  ],
                  orElse: [busy < 0, csrRead.en < 0, csrWrite.en < 0],
                ),
              ]),
              // READ: wait for CSR read response
              CaseItem(stateRead, [
                If(
                  csrRead.done,
                  then: [
                    If(
                      csrRead.valid,
                      then: [
                        readValue < csrRead.data,
                        csrRead.en < 0,
                        If(
                          writeIsNoOp,
                          // No actual write (csrrs/csrrc x0, csrr*i 0, or any
                          // value-preserving write): skip stateWrite so a
                          // read-only CSR is not hit with a write-to-RO trap.
                          // Complete now with the read value as rd.
                          then: [
                            state < stateIdle,
                            busy < 0,
                            csrWrite.en < 0,
                            resultValid < 1,
                            resultTag < savedTag,
                            resultData < csrRead.data,
                            resultException < 0,
                            resultCause < 0,
                          ],
                          orElse: [
                            state < stateWrite,
                            csrWrite.en < 1,
                            csrWrite.addr < savedAddr,
                            csrWrite.data < newCsrVal,
                          ],
                        ),
                      ],
                      orElse: [
                        // CSR read failed: illegal CSR
                        state < stateIdle,
                        busy < 0,
                        csrRead.en < 0,
                        csrWrite.en < 0,
                        resultValid < 1,
                        resultTag < savedTag,
                        resultData < 0,
                        resultException < 1,
                        resultCause < Const(2, width: 6), // illegal instruction
                      ],
                    ),
                  ],
                ),
              ]),
              // WRITE: wait for CSR write response
              CaseItem(stateWrite, [
                If(
                  csrWrite.done,
                  then: [
                    state < stateIdle,
                    busy < 0,
                    csrWrite.en < 0,
                    resultValid < 1,
                    resultTag < savedTag,
                    resultData < readValue,
                    resultException < 0,
                    resultCause < 0,
                  ],
                ),
              ]),
            ],
            defaultItem: [state < stateIdle],
          ),
        ],
      ),
    ]);
  }
}
