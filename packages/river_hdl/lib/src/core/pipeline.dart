import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:riscv/riscv.dart';

import 'decoder.dart';
import 'exec.dart';
import 'fetcher.dart';

class RiverPipeline extends Module {
  final Microcode microcode;
  final Mxlen mxlen;

  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get nextSp => output('nextSp');
  Logic get nextPc => output('nextPc');
  Logic get nextMode => output('nextMode');
  Logic get trap => output('trap');
  Logic get trapCause => output('trapCause');
  Logic get trapTval => output('trapTval');
  Logic get fence => output('fence');
  Logic get interruptHold => output('interruptHold');
  Logic get counter => output('counter');

  late final FetchUnit fetcher;

  RiverPipeline(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic currentSp,
    Logic currentPc,
    Logic currentMode,
    DataPortInterface? csrRead,
    DataPortInterface? csrWrite,
    DataPortInterface memFetchRead,
    DataPortInterface memExecRead,
    DataPortInterface memWrite,
    DataPortInterface rs1Read,
    DataPortInterface rs2Read,
    DataPortInterface rdWrite,
    DataPortInterface? microcodeDecodeRead,
    DataPortInterface? microcodeExecRead, {
    bool useMixedDecoders = false,
    bool useMixedExecution = false,
    bool hasSupervisor = false,
    bool hasUser = false,
    bool hasCompressed = false,
    required this.microcode,
    required this.mxlen,
    Logic? mideleg,
    Logic? medeleg,
    Logic? mtvec,
    Logic? stvec,
    int counterWidth = 32,
    List<String> staticInstructions = const [],
    super.name = 'river_pipeline',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);

    currentSp = addInput('currentSp', currentSp, width: mxlen.size);
    currentPc = addInput('currentPc', currentPc, width: mxlen.size);
    currentMode = addInput('currentMode', currentMode, width: 3);

    if (csrRead != null) {
      csrRead = csrRead!.clone()
        ..connectIO(
          this,
          csrRead!,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'csrRead_$og',
        );
    }

    if (csrWrite != null) {
      csrWrite = csrWrite!.clone()
        ..connectIO(
          this,
          csrWrite!,
          outputTags: {DataPortGroup.control, DataPortGroup.data},
          inputTags: {DataPortGroup.integrity},
          uniquify: (og) => 'csrWrite_$og',
        );
    }

    memFetchRead = memFetchRead.clone()
      ..connectIO(
        this,
        memFetchRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memFetchRead_$og',
      );
    memExecRead = memExecRead.clone()
      ..connectIO(
        this,
        memExecRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memExecRead_$og',
      );
    memWrite = memWrite.clone()
      ..connectIO(
        this,
        memWrite,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'memWrite_$og',
      );

    rs1Read = rs1Read.clone()
      ..connectIO(
        this,
        rs1Read,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'rs1Read_$og',
      );
    rs2Read = rs2Read.clone()
      ..connectIO(
        this,
        rs2Read,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'rs2Read_$og',
      );
    rdWrite = rdWrite.clone()
      ..connectIO(
        this,
        rdWrite,
        outputTags: {DataPortGroup.control, DataPortGroup.data},
        inputTags: {DataPortGroup.integrity},
        uniquify: (og) => 'rdWrite_$og',
      );

    if (microcodeDecodeRead != null) {
      microcodeDecodeRead = microcodeDecodeRead!.clone()
        ..connectIO(
          this,
          microcodeDecodeRead!,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'microcodeDecodeRead_$og',
        );
    }

    if (microcodeExecRead != null) {
      microcodeExecRead = microcodeExecRead!.clone()
        ..connectIO(
          this,
          microcodeExecRead!,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'microcodeExecRead_$og',
        );
    }

    if (mideleg != null)
      mideleg = addInput('mideleg', mideleg, width: mxlen.size);
    if (medeleg != null)
      medeleg = addInput('medeleg', medeleg, width: mxlen.size);
    if (mtvec != null) mtvec = addInput('mtvec', mtvec, width: mxlen.size);
    if (stvec != null) stvec = addInput('stvec', stvec, width: mxlen.size);

    addOutput('done');
    addOutput('valid');
    addOutput('nextSp', width: mxlen.size);
    addOutput('nextPc', width: mxlen.size);
    addOutput('nextMode', width: 3);
    addOutput('trap');
    addOutput('trapCause', width: 6);
    addOutput('trapTval', width: mxlen.size);
    addOutput('fence');
    addOutput('interruptHold');
    addOutput('counter', width: counterWidth);

    fetcher = FetchUnit(
      clk,
      reset,
      enable,
      currentPc,
      memFetchRead,
      hasCompressed: hasCompressed,
    );

    final decoder0 = microcodeDecodeRead != null
        ? DynamicInstructionDecoder(
            clk,
            reset,
            fetcher.done & fetcher.valid,
            fetcher.result,
            microcodeDecodeRead!,
            microcode: microcode,
            mxlen: mxlen,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
          )
        : StaticInstructionDecoder(
            clk,
            reset,
            fetcher.done & fetcher.valid,
            fetcher.result,
            microcode: microcode,
            mxlen: mxlen,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
          );

    final decoder1 = (useMixedDecoders && microcodeDecodeRead != null)
        ? StaticInstructionDecoder(
            clk,
            reset,
            fetcher.done & fetcher.valid,
            fetcher.result,
            microcode: microcode,
            mxlen: mxlen,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
          )
        : null;

    final decodeIndex = decoder1 != null
        ? mux(decoder0.done & decoder0.valid, decoder0.index, decoder1!.index)
        : decoder0.index;
    final decodeInstrTypeMap = decoder1 != null
        ? decoder0.instrTypeMap.map(
            (name, value) => MapEntry(
              name,
              mux(
                decoder0.done & decoder0.valid,
                value,
                decoder1!.instrTypeMap[name]!,
              ).named(name),
            ),
          )
        : decoder0.instrTypeMap;

    final decodeFields = decoder1 != null
        ? decoder0.fields.map(
            (name, value) => MapEntry(
              name,
              mux(
                decoder0.done & decoder0.valid,
                value,
                decoder1!.fields[name]!,
              ).named(name),
            ),
          )
        : decoder0.fields;

    final decodeDone = decoder1 != null
        ? (decoder0.done | decoder1!.done)
        : decoder0.done;
    final decodeValid = decoder1 != null
        ? (decoder0.valid | decoder1!.valid)
        : decoder0.valid;

    final readyExecution =
        (fetcher.valid & fetcher.done & decodeValid & decodeDone).named(
          'readyExecution',
        );

    final memExecRead0 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(mxlen.size, mxlen.size)
        : memExecRead;

    final memExecRead1 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(mxlen.size, mxlen.size)
        : null;

    final memWrite0 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(7 + mxlen.size, mxlen.size)
        : memWrite;
    final memWrite1 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(7 + mxlen.size, mxlen.size)
        : null;

    final csrRead0 =
        (useMixedExecution && microcodeExecRead != null && csrRead != null)
        ? DataPortInterface(mxlen.size, 12)
        : csrRead;
    final csrWrite0 =
        (useMixedExecution && microcodeExecRead != null && csrWrite != null)
        ? DataPortInterface(mxlen.size, 12)
        : csrWrite;

    final csrRead1 =
        (useMixedExecution && microcodeExecRead != null && csrRead != null)
        ? DataPortInterface(mxlen.size, 12)
        : null;
    final csrWrite1 =
        (useMixedExecution && microcodeExecRead != null && csrWrite != null)
        ? DataPortInterface(mxlen.size, 12)
        : null;

    final rs1Read0 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(mxlen.size, 5)
        : rs1Read;
    final rs1Read1 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(mxlen.size, 5)
        : null;

    final rs2Read0 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(mxlen.size, 5)
        : rs2Read;
    final rs2Read1 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(mxlen.size, 5)
        : null;

    final rdWrite0 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(mxlen.size, 5)
        : rdWrite;
    final rdWrite1 = (useMixedExecution && microcodeExecRead != null)
        ? DataPortInterface(mxlen.size, 5)
        : null;

    final exec0 = microcodeExecRead != null
        ? DynamicExecutionUnit(
            clk,
            reset,
            readyExecution,
            currentSp,
            currentPc,
            currentMode,
            decodeIndex,
            decodeInstrTypeMap,
            decodeFields,
            csrRead0,
            csrWrite0,
            memExecRead0,
            memWrite0,
            rs1Read0,
            rs2Read0,
            rdWrite0,
            microcodeExecRead,
            hasSupervisor: hasSupervisor,
            hasUser: hasUser,
            microcode: microcode,
            mxlen: mxlen,
            mideleg: mideleg,
            medeleg: medeleg,
            mtvec: mtvec,
            stvec: stvec,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
          )
        : StaticExecutionUnit(
            clk,
            reset,
            readyExecution,
            currentSp,
            currentPc,
            currentMode,
            decodeIndex,
            decodeInstrTypeMap,
            decodeFields,
            csrRead0,
            csrWrite0,
            memExecRead0,
            memWrite0,
            rs1Read0,
            rs2Read0,
            rdWrite0,
            hasSupervisor: hasSupervisor,
            hasUser: hasUser,
            microcode: microcode,
            mxlen: mxlen,
            mideleg: mideleg,
            medeleg: medeleg,
            mtvec: mtvec,
            stvec: stvec,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
          );

    final exec1 = (useMixedExecution && microcodeExecRead != null)
        ? StaticExecutionUnit(
            clk,
            reset,
            readyExecution & exec0.done & ~exec0.valid,
            currentSp,
            currentPc,
            currentMode,
            decodeIndex,
            decodeInstrTypeMap,
            decodeFields,
            csrRead1,
            csrWrite1,
            memExecRead1!,
            memWrite1!,
            rs1Read1!,
            rs2Read1!,
            rdWrite1!,
            hasSupervisor: hasSupervisor,
            hasUser: hasUser,
            microcode: microcode,
            mxlen: mxlen,
            mideleg: mideleg,
            medeleg: medeleg,
            mtvec: mtvec,
            stvec: stvec,
            staticInstructions: staticInstructions,
            counterWidth: counterWidth,
          )
        : null;

    final execDone = exec1 != null ? exec0.done | exec1.done : exec0.done;
    final execValid = exec1 != null ? exec0.valid | exec1.valid : exec0.valid;

    final execNextSp = exec1 != null
        ? mux(exec0.done & exec0.valid, exec0.nextSp, exec1.nextSp)
        : exec0.nextSp;
    final execNextPc = exec1 != null
        ? mux(exec0.done & exec0.valid, exec0.nextPc, exec1.nextPc)
        : exec0.nextPc;
    final execNextMode = exec1 != null
        ? mux(exec0.done & exec0.valid, exec0.nextMode, exec1.nextMode)
        : exec0.nextMode;
    final execTrap = exec1 != null
        ? mux(exec0.done & exec0.valid, exec0.trap, exec1.trap)
        : exec0.trap;
    final execTrapCause = exec1 != null
        ? mux(exec0.done & exec0.valid, exec0.trapCause, exec1.trapCause)
        : exec0.trapCause;
    final execTrapTval = exec1 != null
        ? mux(exec0.done & exec0.valid, exec0.trapTval, exec1.trapTval)
        : exec0.trapTval;
    final execFence = exec1 != null
        ? mux(exec0.done & exec0.valid, exec0.fence, exec1.fence)
        : exec0.fence;
    final execInterruptHold = exec1 != null
        ? mux(
            exec0.done & exec0.valid,
            exec0.interruptHold,
            exec1.interruptHold,
          )
        : exec0.interruptHold;

    Sequential(clk, [
      If(
        reset | ~execDone,
        then: [
          done < 0,
          valid < 0,
          nextSp < 0,
          nextPc < 0,
          nextMode < 0,
          trap < 0,
          trapCause < 0,
          trapTval < 0,
          fence < 0,
          counter < 0,
          if (useMixedExecution &&
              microcodeExecRead != null &&
              csrRead != null) ...[
            csrRead.en < 0,
            csrRead.addr < 0,
            csrRead0!.data < 0,
            csrRead0!.done < 0,
            csrRead0!.valid < 0,
            csrRead1!.data < 0,
            csrRead1!.done < 0,
            csrRead1!.valid < 0,
          ],
          if (useMixedExecution &&
              microcodeExecRead != null &&
              csrWrite != null) ...[
            csrWrite.en < 0,
            csrWrite.addr < 0,
            csrWrite0!.done < 0,
            csrWrite0!.valid < 0,
            csrWrite1!.done < 0,
            csrWrite1!.valid < 0,
          ],
          if (useMixedExecution && microcodeExecRead != null) ...[
            memExecRead.en < 0,
            memExecRead.addr < 0,
            memExecRead0!.data < 0,
            memExecRead0!.done < 0,
            memExecRead0!.valid < 0,
            memExecRead1!.data < 0,
            memExecRead1!.done < 0,
            memExecRead1!.valid < 0,
            memWrite.en < 0,
            memWrite.addr < 0,
            memWrite0!.done < 0,
            memWrite0!.valid < 0,
            memWrite1!.done < 0,
            memWrite1!.valid < 0,
            rs1Read.en < 0,
            rs1Read.addr < 0,
            rs1Read0!.data < 0,
            rs1Read0!.done < 0,
            rs1Read0!.valid < 0,
            rs1Read1!.data < 0,
            rs1Read1!.done < 0,
            rs1Read1!.valid < 0,
            rs2Read.en < 0,
            rs2Read.addr < 0,
            rs2Read0!.data < 0,
            rs2Read0!.done < 0,
            rs2Read0!.valid < 0,
            rs2Read1!.data < 0,
            rs2Read1!.done < 0,
            rs2Read1!.valid < 0,
            rdWrite.en < 0,
            rdWrite.addr < 0,
            rdWrite0!.done < 0,
            rdWrite0!.valid < 0,
            rdWrite1!.done < 0,
            rdWrite1!.valid < 0,
          ],
        ],
        orElse: [
          done < fetcher.done & decodeDone & execDone,
          valid < fetcher.valid & decodeValid & execValid,
          nextSp < execNextSp,
          nextPc < execNextPc,
          nextMode < execNextMode,
          trap < execTrap,
          trapCause < execTrapCause,
          trapTval < execTrapTval,
          fence < execFence,
          interruptHold < execInterruptHold,
          If(enable, then: [counter < (counter + 1)]),
          if (useMixedExecution && microcodeExecRead != null && csrRead != null)
            If.block([
              Iff(csrRead0!.en, [
                csrRead.en < 1,
                csrRead.addr < csrRead0.addr,
                csrRead0!.data < csrRead.data,
                csrRead0!.done < csrRead.done,
                csrRead0!.valid < csrRead.valid,
              ]),
              Iff(csrRead1!.en, [
                csrRead.en < 1,
                csrRead.addr < csrRead1!.addr,
                csrRead1!.data < csrRead.data,
                csrRead1!.done < csrRead.done,
                csrRead1!.valid < csrRead.valid,
              ]),
              Else([
                csrRead.en < 0,
                csrRead.addr < 0,
                csrRead0!.data < 0,
                csrRead0!.done < 0,
                csrRead0!.valid < 0,
                csrRead1!.data < 0,
                csrRead1!.done < 0,
                csrRead1!.valid < 0,
              ]),
            ]),
          if (useMixedExecution &&
              microcodeExecRead != null &&
              csrWrite != null)
            If.block([
              Iff(csrWrite0!.en, [
                csrWrite.en < 1,
                csrWrite.addr < csrWrite0!.addr,
                csrWrite.data < csrWrite0!.data,
                csrWrite0!.done < csrWrite.done,
                csrWrite0!.valid < csrWrite.valid,
              ]),
              Iff(csrWrite1!.en, [
                csrWrite.en < 1,
                csrWrite.addr < csrWrite1!.addr,
                csrWrite.data < csrWrite1!.data,
                csrWrite1!.done < csrWrite.done,
                csrWrite1!.valid < csrWrite.valid,
              ]),
              Else([
                csrWrite.en < 0,
                csrWrite.addr < 0,
                csrWrite0!.done < 0,
                csrWrite0!.valid < 0,
                csrWrite1!.done < 0,
                csrWrite1!.valid < 0,
              ]),
            ]),
          if (useMixedExecution && microcodeExecRead != null) ...[
            If.block([
              Iff(memExecRead0!.en, [
                memExecRead.en < 1,
                memExecRead.addr < memExecRead0.addr,
                memExecRead0!.data < memExecRead.data,
                memExecRead0!.done < memExecRead.done,
                memExecRead0!.valid < memExecRead.valid,
              ]),
              Iff(memExecRead1!.en, [
                memExecRead.en < 1,
                memExecRead.addr < memExecRead1!.addr,
                memExecRead1!.data < memExecRead.data,
                memExecRead1!.done < memExecRead.done,
                memExecRead1!.valid < memExecRead.valid,
              ]),
              Else([
                memExecRead.en < 0,
                memExecRead.addr < 0,
                memExecRead0!.data < 0,
                memExecRead0!.done < 0,
                memExecRead0!.valid < 0,
                memExecRead1!.data < 0,
                memExecRead1!.done < 0,
                memExecRead1!.valid < 0,
              ]),
            ]),
            If.block([
              Iff(memWrite0!.en, [
                memWrite.en < 1,
                memWrite.addr < memWrite0!.addr,
                memWrite.data < memWrite0!.data,
                memWrite0!.done < memWrite.done,
                memWrite0!.valid < memWrite.valid,
              ]),
              Iff(memWrite1!.en, [
                memWrite.en < 1,
                memWrite.addr < memWrite1!.addr,
                memWrite.data < memWrite1!.data,
                memWrite1!.done < memWrite.done,
                memWrite1!.valid < memWrite.valid,
              ]),
              Else([
                memWrite.en < 0,
                memWrite.addr < 0,
                memWrite0!.done < 0,
                memWrite0!.valid < 0,
                memWrite1!.done < 0,
                memWrite1!.valid < 0,
              ]),
            ]),
            If.block([
              Iff(rs1Read0!.en, [
                rs1Read.en < 1,
                rs1Read.addr < rs1Read0.addr,
                rs1Read0!.data < rs1Read.data,
                rs1Read0!.done < rs1Read.done,
                rs1Read0!.valid < rs1Read.valid,
              ]),
              Iff(rs1Read1!.en, [
                rs1Read.en < 1,
                rs1Read.addr < rs1Read1!.addr,
                rs1Read1!.data < rs1Read.data,
                rs1Read1!.done < rs1Read.done,
                rs1Read1!.valid < rs1Read.valid,
              ]),
              Else([
                rs1Read.en < 0,
                rs1Read.addr < 0,
                rs1Read0!.data < 0,
                rs1Read0!.done < 0,
                rs1Read0!.valid < 0,
                rs1Read1!.data < 0,
                rs1Read1!.done < 0,
                rs1Read1!.valid < 0,
              ]),
            ]),
            If.block([
              Iff(rs2Read0!.en, [
                rs2Read.en < 1,
                rs2Read.addr < rs2Read0.addr,
                rs2Read0!.data < rs2Read.data,
                rs2Read0!.done < rs2Read.done,
                rs2Read0!.valid < rs2Read.valid,
              ]),
              Iff(rs2Read1!.en, [
                rs2Read.en < 1,
                rs2Read.addr < rs2Read1!.addr,
                rs2Read1!.data < rs2Read.data,
                rs2Read1!.done < rs2Read.done,
                rs2Read1!.valid < rs2Read.valid,
              ]),
              Else([
                rs2Read.en < 0,
                rs2Read.addr < 0,
                rs2Read0!.data < 0,
                rs2Read0!.done < 0,
                rs2Read0!.valid < 0,
                rs2Read1!.data < 0,
                rs2Read1!.done < 0,
                rs2Read1!.valid < 0,
              ]),
            ]),
            If.block([
              Iff(rdWrite0!.en, [
                rdWrite.en < 1,
                rdWrite.addr < rdWrite0!.addr,
                rdWrite.data < rdWrite0!.data,
                rdWrite0!.done < rdWrite.done,
                rdWrite0!.valid < rdWrite.valid,
              ]),
              Iff(rdWrite1!.en, [
                rdWrite.en < 1,
                rdWrite.addr < rdWrite1!.addr,
                rdWrite.data < rdWrite1!.data,
                rdWrite1!.done < rdWrite.done,
                rdWrite1!.valid < rdWrite.valid,
              ]),
              Else([
                rdWrite.en < 0,
                rdWrite.addr < 0,
                rdWrite0!.done < 0,
                rdWrite0!.valid < 0,
                rdWrite1!.done < 0,
                rdWrite1!.valid < 0,
              ]),
            ]),
          ],
        ],
      ),
    ]);
  }
}
