import 'package:rohd/rohd.dart';

/// Load/store functional unit.
///
/// Handles memory loads, stores, and atomic operations.
/// Multi-cycle: issues address on cycle 1, waits for memory response.
/// Connects to the bus fabric via Wishbone master port.
///
/// With a load-store queue configured ([lsqStores] true), stores do NOT drive
/// the bus here, they push their address/data into the store queue (via the
/// `store_fill_*` outputs) and complete in one cycle; the architectural write
/// happens later at commit. Loads can also be held: while [loadStall] is high
/// (an older store has not yet drained) an accepted load waits before issuing
/// its bus read, so it observes the older store's value.
class MemoryUnit extends Module {
  final int xlen;

  /// Whether stores are routed into a store queue instead of the bus.
  final bool lsqStores;

  Logic get resultValid => output('result_valid');
  Logic get resultTag => output('result_tag');
  Logic get resultData => output('result_data');
  Logic get resultException => output('result_exception');
  Logic get resultCause => output('result_cause');
  Logic get busy => output('busy');

  // Speculative LSQ: a store that violated load ordering (a younger load already
  // read its address) redirects to re-fetch from after the store.
  Logic get resultRedirect => output('result_redirect');
  Logic get resultTarget => output('result_target');
  // The completing op's access info, for the load-queue (push on a load) and
  // the store-queue CAM.
  Logic get resultIsStore => output('result_is_store');
  Logic get resultAddr => output('result_addr');
  Logic get resultSize => output('result_size');

  // Store-queue fill (only meaningful when [lsqStores]). Asserted the cycle a
  // store is accepted; carries the address/data/size to push into the queue.
  Logic get storeFillValid => output('store_fill_valid');
  Logic get storeFillTag => output('store_fill_tag');
  Logic get storeFillAddr => output('store_fill_addr');
  Logic get storeFillData => output('store_fill_data');
  Logic get storeFillSize => output('store_fill_size');

  // Wishbone master port signals
  Logic get wbCyc => output('wb_cyc');
  Logic get wbStb => output('wb_stb');
  Logic get wbWe => output('wb_we');
  Logic get wbAdr => output('wb_adr');
  Logic get wbDatMosi => output('wb_dat_mosi');
  Logic get wbSel => output('wb_sel');

  /// Access byte count (1/2/4/8) of the in-flight request, for consumers that
  /// pack a sized store data word.
  Logic get wbSize => output('wb_size');

  MemoryUnit(
    Logic clk,
    Logic reset, {
    required Logic issueValid,
    required Logic issueTag,
    required Logic issueSrc1,
    required Logic issueSrc2,
    required Logic issueImm,
    required Logic issueIsStore,
    required Logic issueSize,
    required Logic issueSignExtend,
    required Logic flush,
    required Logic wbAck,
    required Logic wbDatMiso,
    required Logic wbErr,
    // High when an accepted load must wait for the store queue to drain before
    // reading the bus. Tied to 0 when no LSQ is configured.
    Logic? loadStall,
    // Store→load forwarding (forwarding mode): when an accepted load's address
    // is satisfied by an in-queue store, take the value directly and skip the
    // bus. Tied to 0 when forwarding is not configured.
    Logic? fwdHit,
    Logic? fwdData,
    // The dispatching op's PC (for the store-violation replay target) and a
    // store→load ordering violation flag from the load queue (speculative mode).
    Logic? issuePc,
    Logic? camViolation,
    // MMU page-fault for the in-flight access (dport `done & ~valid`). When high
    // during the bus request the access traps with a load/store page fault
    // instead of completing or hanging. [memFaultGuest] selects the guest
    // (G-stage) page-fault cause. Both tie to 0 when no MMU faults are wired.
    Logic? memFault,
    Logic? memFaultGuest,
    this.lsqStores = false,
    this.xlen = 64,
    int robTagBits = 7,
    super.name = 'memory_unit',
  }) : super(definitionName: 'MemoryUnit') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    // Issue interface
    issueValid = addInput('issue_valid', issueValid);
    issueTag = addInput('issue_tag', issueTag, width: robTagBits);
    issueSrc1 = addInput('issue_src1', issueSrc1, width: xlen);
    issueSrc2 = addInput('issue_src2', issueSrc2, width: xlen);
    issueImm = addInput('issue_imm', issueImm, width: xlen);
    issueIsStore = addInput('issue_is_store', issueIsStore);
    issueSize = addInput('issue_size', issueSize, width: 3); // bytes: 1,2,4,8
    issueSignExtend = addInput('issue_sign_extend', issueSignExtend);
    loadStall = addInput('load_stall', loadStall ?? Const(0));
    fwdHit = addInput('fwd_hit', fwdHit ?? Const(0));
    fwdData = addInput(
      'fwd_data',
      fwdData ?? Const(0, width: xlen),
      width: xlen,
    );
    issuePc = addInput(
      'issue_pc',
      issuePc ?? Const(0, width: xlen),
      width: xlen,
    );
    camViolation = addInput('cam_violation', camViolation ?? Const(0));
    memFault = addInput('mem_fault', memFault ?? Const(0));
    memFaultGuest = addInput('mem_fault_guest', memFaultGuest ?? Const(0));

    // Flush
    flush = addInput('flush', flush);

    // Wishbone slave response (from bus fabric)
    wbAck = addInput('wb_ack', wbAck);
    wbDatMiso = addInput('wb_dat_miso', wbDatMiso, width: xlen);
    wbErr = addInput('wb_err', wbErr);

    // Result interface
    addOutput('result_valid');
    addOutput('result_tag', width: robTagBits);
    addOutput('result_data', width: xlen);
    addOutput('result_exception');
    addOutput('result_cause', width: 6);
    addOutput('busy');
    addOutput('result_redirect');
    addOutput('result_target', width: xlen);
    addOutput('result_is_store');
    addOutput('result_addr', width: xlen);
    addOutput('result_size', width: 3);

    // Store-queue fill outputs
    addOutput('store_fill_valid');
    addOutput('store_fill_tag', width: robTagBits);
    addOutput('store_fill_addr', width: xlen);
    addOutput('store_fill_data', width: xlen);
    addOutput('store_fill_size', width: 3);

    // Wishbone master outputs
    addOutput('wb_cyc');
    addOutput('wb_stb');
    addOutput('wb_we');
    addOutput('wb_adr', width: xlen);
    addOutput('wb_dat_mosi', width: xlen);
    addOutput('wb_sel', width: xlen ~/ 8);
    addOutput('wb_size', width: 3);

    // Address generation
    final effectiveAddr = (issueSrc1 + issueImm).named('effective_addr');

    // Byte select mask from a size in bytes.
    Logic selFromSize(Logic size) {
      final sel = Logic(name: 'sel_tmp', width: xlen ~/ 8);
      Combinational([
        Case(
          size,
          [
            CaseItem(Const(1, width: 3), [sel < Const(0x01, width: xlen ~/ 8)]),
            CaseItem(Const(2, width: 3), [sel < Const(0x03, width: xlen ~/ 8)]),
            CaseItem(Const(4, width: 3), [sel < Const(0x0F, width: xlen ~/ 8)]),
            CaseItem(Const(8, width: 3), [sel < Const(0xFF, width: xlen ~/ 8)]),
          ],
          defaultItem: [sel < Const(0x0F, width: xlen ~/ 8)],
        ),
      ]);
      return sel;
    }

    final byteSel = selFromSize(issueSize).named('byte_sel');

    // FSM states
    final stateIdle = Const(0, width: 3);
    final stateRequest = Const(1, width: 3);
    final stateWait = Const(2, width: 3); // load waiting for the SQ to drain
    final stateStoreDone = Const(3, width: 3); // LSQ store: complete next cycle
    final stateForward = Const(
      4,
      width: 3,
    ); // forwarded load: complete next cyc

    final state = Logic(name: 'mem_state', width: 3);
    final savedTag = Logic(name: 'saved_tag', width: robTagBits);
    final savedIsStore = Logic(name: 'saved_is_store');
    final savedSize = Logic(name: 'saved_size', width: 3);
    final savedSignExtend = Logic(name: 'saved_sign_extend');
    final savedAddr = Logic(name: 'saved_addr', width: xlen);
    final savedSel = Logic(name: 'saved_sel', width: xlen ~/ 8);
    final savedFwdData = Logic(name: 'saved_fwd_data', width: xlen);
    final savedPc = Logic(name: 'saved_pc', width: xlen);
    final savedViolation = Logic(name: 'saved_violation');

    // Combinational result info (valid alongside result_valid for the LSQ).
    output('result_is_store') <= savedIsStore;
    output('result_addr') <= savedAddr;
    output('result_size') <= savedSize;

    // An LSQ store accepted this cycle (pushed into the queue, no bus access).
    final isLsqStore = issueIsStore & (lsqStores ? Const(1) : Const(0));
    final acceptLsqStore = issueValid & isLsqStore;
    // A load whose value is forwarded from the store queue (no bus access).
    final acceptForward = issueValid & ~issueIsStore & fwdHit;
    // A load that must wait for the store queue before reading the bus.
    final acceptWaitLoad = issueValid & ~issueIsStore & loadStall;

    // Store-fill: expose the pushed store's fields the cycle it is accepted.
    storeFillValid <= state.eq(stateIdle) & acceptLsqStore;
    storeFillTag <= issueTag;
    storeFillAddr <= effectiveAddr;
    storeFillData <= issueSrc2;
    storeFillSize <= issueSize;

    Sequential(clk, [
      If(
        reset | flush,
        then: [
          state < stateIdle,
          savedTag < 0,
          savedIsStore < 0,
          savedSize < 0,
          savedSignExtend < 0,
          savedAddr < 0,
          savedSel < 0,
          savedFwdData < 0,
          savedPc < 0,
          savedViolation < 0,
          resultValid < 0,
          resultTag < 0,
          resultData < 0,
          resultException < 0,
          resultCause < 0,
          resultRedirect < 0,
          resultTarget < 0,
          busy < 0,
          wbCyc < 0,
          wbStb < 0,
          wbWe < 0,
          wbAdr < 0,
          wbDatMosi < 0,
          wbSel < 0,
        ],
        orElse: [
          Case(
            state,
            [
              // IDLE: accept new request
              CaseItem(stateIdle, [
                resultValid < 0,
                resultRedirect < 0,
                If(
                  issueValid,
                  then: [
                    savedTag < issueTag,
                    savedIsStore < issueIsStore,
                    savedSize < issueSize,
                    savedSignExtend < issueSignExtend,
                    savedAddr < effectiveAddr,
                    savedSel < byteSel,
                    savedPc < issuePc,
                    savedViolation < camViolation,
                    busy < 1,
                    If(
                      acceptLsqStore,
                      // LSQ store: pushed to the queue (combinationally), no bus
                      // cycle; complete next cycle.
                      then: [state < stateStoreDone, wbCyc < 0, wbStb < 0],
                      orElse: [
                        If(
                          acceptForward,
                          // Load satisfied by an in-queue store: forward, no bus.
                          then: [
                            state < stateForward,
                            savedFwdData < fwdData,
                            wbCyc < 0,
                            wbStb < 0,
                          ],
                          orElse: [
                            If(
                              acceptWaitLoad,
                              // Load blocked by an undrained store: hold, no bus yet.
                              then: [state < stateWait, wbCyc < 0, wbStb < 0],
                              orElse: [
                                // Load (clear) or legacy store: start the bus cycle.
                                state < stateRequest,
                                wbCyc < 1,
                                wbStb < 1,
                                wbWe < issueIsStore,
                                wbAdr < effectiveAddr,
                                wbDatMosi < issueSrc2,
                                wbSel < byteSel,
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                  orElse: [busy < 0, wbCyc < 0, wbStb < 0],
                ),
              ]),
              // STORE_DONE: LSQ store retires its execution (no bus). If it
              // violated load ordering, redirect to re-fetch from after it.
              CaseItem(stateStoreDone, [
                state < stateIdle,
                busy < 0,
                resultValid < 1,
                resultTag < savedTag,
                resultData < 0,
                resultException < 0,
                resultCause < 0,
                resultRedirect < savedViolation,
                resultTarget < (savedPc + Const(4, width: xlen)),
              ]),
              // FORWARD: load completes with the store-queue-forwarded value.
              CaseItem(stateForward, [
                state < stateIdle,
                busy < 0,
                resultValid < 1,
                resultTag < savedTag,
                resultData < savedFwdData,
                resultException < 0,
                resultCause < 0,
              ]),
              // WAIT: load held until the store queue drains.
              CaseItem(stateWait, [
                If(
                  ~loadStall,
                  then: [
                    // SQ drained: now issue the bus read from saved fields.
                    state < stateRequest,
                    wbCyc < 1,
                    wbStb < 1,
                    wbWe < 0,
                    wbAdr < savedAddr,
                    wbDatMosi < 0,
                    wbSel < savedSel,
                  ],
                ),
              ]),
              // REQUEST: waiting for ack
              CaseItem(stateRequest, [
                If(
                  wbAck,
                  then: [
                    state < stateIdle,
                    busy < 0,
                    wbCyc < 0,
                    wbStb < 0,
                    resultValid < 1,
                    resultTag < savedTag,
                    resultException < 0,
                    resultCause < 0,
                    If(
                      savedIsStore,
                      then: [resultData < 0],
                      orElse: [
                        // Load: extract and sign-extend based on size
                        resultData < wbDatMiso,
                      ],
                    ),
                  ],
                  orElse: [
                    If(
                      memFault,
                      then: [
                        // MMU page fault (dport done & ~valid). Guest (G-stage)
                        // = store 23 / load 21; single-stage = store 15 / 13.
                        state < stateIdle,
                        busy < 0,
                        wbCyc < 0,
                        wbStb < 0,
                        resultValid < 1,
                        resultTag < savedTag,
                        resultData < 0,
                        resultException < 1,
                        resultCause <
                            mux(
                              memFaultGuest,
                              mux(
                                savedIsStore,
                                Const(23, width: 6),
                                Const(21, width: 6),
                              ),
                              mux(
                                savedIsStore,
                                Const(15, width: 6),
                                Const(13, width: 6),
                              ),
                            ),
                      ],
                      orElse: [
                        If(
                          wbErr,
                          then: [
                            // Bus error → access fault
                            state < stateIdle,
                            busy < 0,
                            wbCyc < 0,
                            wbStb < 0,
                            resultValid < 1,
                            resultTag < savedTag,
                            resultData < 0,
                            resultException < 1,
                            // Load access fault = 5, Store access fault = 7
                            resultCause <
                                mux(
                                  savedIsStore,
                                  Const(7, width: 6),
                                  Const(5, width: 6),
                                ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ]),
            ],
            defaultItem: [state < stateIdle, busy < 0],
          ),
        ],
      ),
    ]);

    // Expose the in-flight access byte count (held in savedSize during REQUEST).
    output('wb_size') <= savedSize;
  }
}
