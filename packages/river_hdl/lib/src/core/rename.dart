import 'package:rohd/rohd.dart';

/// Register Alias Table (RAT) for register renaming.
///
/// Maps 32 architectural registers → physical register indices.
/// Supports dual-issue rename (2 instructions per cycle) and
/// rollback on flush via a committed RAT snapshot.
class RegisterRenameTable extends Module {
  /// Number of physical registers.
  final int numPhysRegs;

  /// Width of a physical register index.
  int get physRegBits => numPhysRegs.bitLength;

  // -- Rename result ports --

  Logic get psrc1_0 => output('psrc1_0');
  Logic get psrc2_0 => output('psrc2_0');
  Logic get pdst0 => output('pdst_0');
  Logic get pdstOld0 => output('pdst_old_0');

  Logic get psrc1_1 => output('psrc1_1');
  Logic get psrc2_1 => output('psrc2_1');
  Logic get pdst1 => output('pdst_1');
  Logic get pdstOld1 => output('pdst_old_1');

  Logic get ready => output('ready');

  RegisterRenameTable(
    Logic clk,
    Logic reset, {
    required Logic rs1Arch0,
    required Logic rs2Arch0,
    required Logic rdArch0,
    required Logic valid0,
    required Logic writesRd0,
    required Logic rs1Arch1,
    required Logic rs2Arch1,
    required Logic rdArch1,
    required Logic valid1,
    required Logic writesRd1,
    required Logic freeValid0,
    required Logic freeReg0,
    required Logic freeValid1,
    required Logic freeReg1,
    required Logic commitValid0,
    required Logic commitRd0,
    required Logic commitPdst0,
    required Logic commitValid1,
    required Logic commitRd1,
    required Logic commitPdst1,
    required Logic flush,
    this.numPhysRegs = 96,
    super.name = 'register_rename_table',
  }) : super(definitionName: 'RegisterRenameTable') {
    final pBits = physRegBits;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);

    rs1Arch0 = addInput('rs1_arch_0', rs1Arch0, width: 5);
    rs2Arch0 = addInput('rs2_arch_0', rs2Arch0, width: 5);
    rdArch0 = addInput('rd_arch_0', rdArch0, width: 5);
    valid0 = addInput('valid_0', valid0);
    writesRd0 = addInput('writes_rd_0', writesRd0);

    rs1Arch1 = addInput('rs1_arch_1', rs1Arch1, width: 5);
    rs2Arch1 = addInput('rs2_arch_1', rs2Arch1, width: 5);
    rdArch1 = addInput('rd_arch_1', rdArch1, width: 5);
    valid1 = addInput('valid_1', valid1);
    writesRd1 = addInput('writes_rd_1', writesRd1);

    addOutput('psrc1_0', width: pBits);
    addOutput('psrc2_0', width: pBits);
    addOutput('pdst_0', width: pBits);
    addOutput('pdst_old_0', width: pBits);

    addOutput('psrc1_1', width: pBits);
    addOutput('psrc2_1', width: pBits);
    addOutput('pdst_1', width: pBits);
    addOutput('pdst_old_1', width: pBits);

    addOutput('ready');

    freeValid0 = addInput('free_valid_0', freeValid0);
    freeReg0 = addInput('free_reg_0', freeReg0, width: pBits);
    freeValid1 = addInput('free_valid_1', freeValid1);
    freeReg1 = addInput('free_reg_1', freeReg1, width: pBits);

    commitValid0 = addInput('commit_valid_0', commitValid0);
    commitRd0 = addInput('commit_rd_0', commitRd0, width: 5);
    commitPdst0 = addInput('commit_pdst_0', commitPdst0, width: pBits);
    commitValid1 = addInput('commit_valid_1', commitValid1);
    commitRd1 = addInput('commit_rd_1', commitRd1, width: 5);
    commitPdst1 = addInput('commit_pdst_1', commitPdst1, width: pBits);

    flush = addInput('flush', flush);

    // -- Speculative RAT: 32 entries, each holds a physical register index --
    final specRat = List.generate(
      32,
      (i) => Logic(name: 'spec_rat_$i', width: pBits),
    );

    // -- Committed RAT: snapshot for rollback --
    final commitRat = List.generate(
      32,
      (i) => Logic(name: 'commit_rat_$i', width: pBits),
    );

    // -- Free list: circular buffer of available physical registers --
    final freeList = List.generate(
      numPhysRegs,
      (i) => Logic(name: 'free_$i', width: pBits),
    );
    final freeHead = Logic(name: 'free_head', width: pBits);
    final freeTail = Logic(name: 'free_tail', width: pBits);
    final freeCount = Logic(name: 'free_count', width: pBits + 1);
    // Committed allocation pointer: where freeHead would be if only committed
    // (non-speculative) instructions had allocated. On a flush, freeHead rolls
    // back to this so speculatively-allocated physical registers are reclaimed.
    final freeHeadSnap = Logic(name: 'free_head_snap', width: pBits);

    // Ready when at least 2 physical registers are free (dual-issue)
    ready <= freeCount.gte(Const(2, width: pBits + 1));

    // -- Combinational rename lookups --
    psrc1_0 <= _ratLookup(specRat, rs1Arch0, pBits);
    psrc2_0 <= _ratLookup(specRat, rs2Arch0, pBits);
    pdstOld0 <= _ratLookup(specRat, rdArch0, pBits);
    pdst0 <= _freeListLookup(freeList, freeHead, pBits);

    // Slot 1: check for RAW dependency on slot 0's rd
    final slot0WritesRd1Rs1 = valid0 & writesRd0 & rdArch0.eq(rs1Arch1);
    final slot0WritesRd1Rs2 = valid0 & writesRd0 & rdArch0.eq(rs2Arch1);
    final slot0WritesRd1Rd = valid0 & writesRd0 & rdArch0.eq(rdArch1);

    psrc1_1 <=
        mux(slot0WritesRd1Rs1, pdst0, _ratLookup(specRat, rs1Arch1, pBits));
    psrc2_1 <=
        mux(slot0WritesRd1Rs2, pdst0, _ratLookup(specRat, rs2Arch1, pBits));
    pdstOld1 <=
        mux(slot0WritesRd1Rd, pdst0, _ratLookup(specRat, rdArch1, pBits));
    pdst1 <=
        _freeListLookup(freeList, (freeHead + 1).slice(pBits - 1, 0), pBits);

    // -- Free-list / RAT update next-state --
    final readyW = freeCount.gte(Const(2, width: pBits + 1));
    final c0 = (valid0 & writesRd0).named('rename_c0');
    final c1 = (valid1 & writesRd1).named('rename_c1');
    final slot0Renames = (c0 & readyW).named('slot0_renames');
    final slot1Renames = (c1 & readyW).named('slot1_renames');
    // Free registers consumed by speculative rename this cycle (0/1/2),
    // suppressed on flush. Matches the original slot-0-first priority.
    final consumes = mux(
      flush,
      Const(0, width: 2),
      mux(
        slot0Renames,
        mux(c1, Const(2, width: 2), Const(1, width: 2)),
        mux(slot1Renames, Const(1, width: 2), Const(0, width: 2)),
      ),
    ).named('rename_consumes');
    // Committed reg-writers / freed registers this cycle (architectural, the
    // pipeline drives commitValid/freeValid as commitValid & writesRd).
    final commitAllocs =
        (commitValid0.zeroExtend(2) + commitValid1.zeroExtend(2)).named(
          'commit_allocs',
        );
    final commitPushes = (freeValid0.zeroExtend(2) + freeValid1.zeroExtend(2))
        .named('commit_pushes');

    final freeHeadSnapNext = (freeHeadSnap + commitAllocs.zeroExtend(pBits))
        .slice(pBits - 1, 0);
    // On flush, roll freeHead back to the committed allocation pointer so the
    // squashed instructions' physical registers are reclaimed.
    final freeHeadNext = mux(
      flush,
      freeHeadSnapNext,
      (freeHead + consumes.zeroExtend(pBits)).slice(pBits - 1, 0),
    );
    final freeTailNext = (freeTail + commitPushes.zeroExtend(pBits)).slice(
      pBits - 1,
      0,
    );
    // After a flush the machine is back at the committed state, which always
    // has the 32 architectural registers mapped → numPhysRegs-32 free.
    final freeCountNext = mux(
      flush,
      Const(numPhysRegs - 32, width: pBits + 1),
      freeCount -
          consumes.zeroExtend(pBits + 1) +
          commitPushes.zeroExtend(pBits + 1),
    );

    Sequential(clk, [
      If(
        reset,
        then: [
          ...List.generate(32, (i) => specRat[i] < Const(i, width: pBits)),
          ...List.generate(32, (i) => commitRat[i] < Const(i, width: pBits)),
          ...List.generate(
            numPhysRegs,
            (i) =>
                freeList[i] <
                Const(i < numPhysRegs - 32 ? i + 32 : 0, width: pBits),
          ),
          freeHead < 0,
          freeHeadSnap < 0,
          freeTail < Const(numPhysRegs - 32, width: pBits),
          freeCount < Const(numPhysRegs - 32, width: pBits + 1),
        ],
        orElse: [
          // Speculative RAT: update on rename, restore from committed on flush.
          If(
            flush,
            then: [...List.generate(32, (i) => specRat[i] < commitRat[i])],
            orElse: [
              If(
                slot0Renames,
                then: [_ratUpdate(specRat, rdArch0, pdst0, pBits)],
              ),
              If(
                slot1Renames,
                then: [_ratUpdate(specRat, rdArch1, pdst1, pBits)],
              ),
            ],
          ),

          // Free-list return + committed-RAT update are architectural: they run
          // every cycle, including during a flush.
          If(
            freeValid0,
            then: [_freeListPush(freeList, freeTail, freeReg0, pBits)],
          ),
          If(
            freeValid1,
            then: [
              _freeListPush(
                freeList,
                mux(freeValid0, (freeTail + 1).slice(pBits - 1, 0), freeTail),
                freeReg1,
                pBits,
              ),
            ],
          ),
          If(
            commitValid0,
            then: [_ratUpdate(commitRat, commitRd0, commitPdst0, pBits)],
          ),
          If(
            commitValid1,
            then: [_ratUpdate(commitRat, commitRd1, commitPdst1, pBits)],
          ),

          // Pointer registers (single assignment each).
          freeHead < freeHeadNext,
          freeHeadSnap < freeHeadSnapNext,
          freeTail < freeTailNext,
          freeCount < freeCountNext,
        ],
      ),
    ]);
  }

  Logic _ratLookup(List<Logic> rat, Logic archReg, int pBits) {
    Logic result = rat[0];
    for (var i = 1; i < 32; i++) {
      result = mux(archReg.eq(Const(i, width: 5)), rat[i], result);
    }
    return result;
  }

  Logic _freeListLookup(List<Logic> freeList, Logic index, int pBits) {
    Logic result = freeList[0];
    for (var i = 1; i < freeList.length; i++) {
      result = mux(index.eq(Const(i, width: pBits)), freeList[i], result);
    }
    return result;
  }

  Conditional _ratUpdate(
    List<Logic> rat,
    Logic archReg,
    Logic physReg,
    int pBits,
  ) {
    return Case(archReg, [
      for (var i = 0; i < 32; i++)
        CaseItem(Const(i, width: 5), [rat[i] < physReg]),
    ]);
  }

  Conditional _freeListPush(
    List<Logic> freeList,
    Logic index,
    Logic reg,
    int pBits,
  ) {
    return Case(index, [
      for (var i = 0; i < freeList.length; i++)
        CaseItem(Const(i, width: pBits), [freeList[i] < reg]),
    ]);
  }
}
