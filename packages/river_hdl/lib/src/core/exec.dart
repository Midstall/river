import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:riscv/riscv.dart';

abstract class ExecutionUnit extends Module {
  final Microcode microcode;
  final Mxlen mxlen;
  final bool hasSupervisor;
  final bool hasUser;
  final List<String> staticInstructions;

  late final Logic clk;
  late final Logic currentSp;
  late final Logic currentPc;
  late final Logic currentMode;
  late final DataPortInterface? csrRead;
  late final DataPortInterface? csrWrite;
  late final Logic? mideleg;
  late final Logic? medeleg;
  late final Logic? mtvec;
  late final Logic? stvec;

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

  ExecutionUnit(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic currentSp,
    Logic currentPc,
    Logic currentMode,
    Logic instrIndex,
    Map<String, Logic> instrTypeMap,
    Map<String, Logic> fields,
    DataPortInterface? csrRead,
    DataPortInterface? csrWrite,
    DataPortInterface memRead,
    DataPortInterface memWrite,
    DataPortInterface rs1Read,
    DataPortInterface rs2Read,
    DataPortInterface rdWrite, {
    DataPortInterface? microcodeRead,
    this.hasSupervisor = false,
    this.hasUser = false,
    required this.microcode,
    required this.mxlen,
    Logic? mideleg,
    Logic? medeleg,
    Logic? mtvec,
    Logic? stvec,
    int counterWidth = 32,
    this.staticInstructions = const [],
    super.name = 'river_execution_unit',
  }) {
    clk = addInput('clk', clk);
    this.clk = clk;

    reset = addInput('reset', reset);
    enable = addInput('enable', enable);

    this.currentSp = addInput('currentSp', currentSp, width: mxlen.size);
    currentSp = this.currentSp;

    this.currentPc = addInput('currentPc', currentPc, width: mxlen.size);
    currentPc = this.currentPc;

    this.currentMode = addInput('currentMode', currentMode, width: 3);
    currentMode = this.currentMode;

    instrIndex = addInput(
      'instrIndex',
      instrIndex,
      width: microcode.opIndexWidth,
    );

    instrTypeMap = Map.fromEntries(
      instrTypeMap.entries.map(
        (entry) =>
            MapEntry(entry.key, addInput(entry.value.name!, entry.value)),
      ),
    );

    fields = Map.fromEntries(
      fields.entries.map(
        (entry) => MapEntry(
          entry.key,
          addInput(entry.value.name!, entry.value, width: entry.value.width),
        ),
      ),
    );

    if (csrRead != null) {
      this.csrRead = csrRead!.clone()
        ..connectIO(
          this,
          csrRead!,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'csrRead_$og',
        );
      csrRead = this.csrRead;
    } else {
      this.csrRead = null;
    }

    if (csrWrite != null) {
      this.csrWrite = csrWrite!.clone()
        ..connectIO(
          this,
          csrWrite!,
          outputTags: {DataPortGroup.control, DataPortGroup.data},
          inputTags: {DataPortGroup.integrity},
          uniquify: (og) => 'csrWrite_$og',
        );
      csrWrite = this.csrWrite;
    } else {
      this.csrWrite = null;
    }

    memRead = memRead.clone()
      ..connectIO(
        this,
        memRead,
        outputTags: {DataPortGroup.control},
        inputTags: {DataPortGroup.data, DataPortGroup.integrity},
        uniquify: (og) => 'memRead_$og',
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

    if (microcodeRead != null) {
      microcodeRead = microcodeRead!.clone()
        ..connectIO(
          this,
          microcodeRead!,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'microcodeRead_$og',
        );
    }

    if (mideleg != null)
      this.mideleg = addInput('mideleg', mideleg, width: mxlen.size);
    else
      this.mideleg = null;
    if (medeleg != null)
      this.medeleg = addInput('medeleg', medeleg, width: mxlen.size);
    else
      this.medeleg = null;
    if (mtvec != null)
      this.mtvec = addInput('mtvec', mtvec, width: mxlen.size);
    else
      this.mtvec = null;
    if (stvec != null)
      this.stvec = addInput('stvec', stvec, width: mxlen.size);
    else
      this.stvec = null;

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

    final opIndices = microcode.opIndices;

    final maxLen = microcode.microOpSequences.values
        .map((s) => s.ops.length * 2)
        .fold(0, (a, b) => a > b ? a : b);

    final mopStep = Logic(name: 'mopStep', width: maxLen.bitLength);

    final alu = Logic(name: 'aluState', width: mxlen.size);
    final rs1 = Logic(name: 'rs1State', width: mxlen.size);
    final rs2 = Logic(name: 'rs2State', width: mxlen.size);
    final rd = Logic(name: 'rdState', width: mxlen.size);
    final imm = Logic(name: 'immState', width: mxlen.size);

    Sequential(clk, [
      If(
        reset,
        then: [
          alu < 0,
          mopStep < 0,
          done < 0,
          rs1Read.en < 0,
          rs1Read.addr < 0,
          rs2Read.en < 0,
          rs2Read.addr < 0,
          rdWrite.en < 0,
          rdWrite.addr < 0,
          rdWrite.data < 0,
          memRead.en < 0,
          memRead.addr < 0,
          memWrite.en < 0,
          memWrite.addr < 0,
          memWrite.data < 0,
          if (microcodeRead != null) ...[
            microcodeRead.en < 0,
            microcodeRead.addr < 0,
          ],
          if (this.csrRead != null) ...[
            this.csrRead!.en < 0,
            this.csrRead!.addr < 0,
          ],
          if (this.csrWrite != null) ...[
            this.csrWrite!.en < 0,
            this.csrWrite!.addr < 0,
            this.csrWrite!.data < 0,
          ],
          fence < 0,
          interruptHold < 0,
          nextPc < currentPc,
          nextSp < currentSp,
          counter < 0,
        ],
        orElse: [
          If(
            enable,
            then: [
              counter < (counter + 1),
              ...(microcodeRead != null
                  ? cycleMicrocode(
                      instrIndex,
                      mopStep,
                      microcodeRead!,
                      alu: alu,
                      rs1: rs1,
                      rs2: rs2,
                      rd: rd,
                      imm: imm,
                      fields: fields,
                      memRead: memRead,
                      memWrite: memWrite,
                      rs1Read: rs1Read,
                      rs2Read: rs2Read,
                      rdWrite: rdWrite,
                    )
                  : cycle(
                      instrIndex,
                      mopStep,
                      alu: alu,
                      rs1: rs1,
                      rs2: rs2,
                      rd: rd,
                      imm: imm,
                      fields: fields,
                      memRead: memRead,
                      memWrite: memWrite,
                      rs1Read: rs1Read,
                      rs2Read: rs2Read,
                      rdWrite: rdWrite,
                    )),
            ],
            orElse: [
              alu < 0,
              mopStep < 0,
              done < 0,
              rs1Read.en < 0,
              rs1Read.addr < 0,
              rs2Read.en < 0,
              rs2Read.addr < 0,
              rdWrite.en < 0,
              rdWrite.addr < 0,
              rdWrite.data < 0,
              memRead.en < 0,
              memRead.addr < 0,
              memWrite.en < 0,
              memWrite.addr < 0,
              memWrite.data < 0,
              if (microcodeRead != null) ...[
                microcodeRead.en < 0,
                microcodeRead.addr < 0,
              ],
              if (this.csrRead != null) ...[
                this.csrRead!.en < 0,
                this.csrRead!.addr < 0,
              ],
              if (this.csrWrite != null) ...[
                this.csrWrite!.en < 0,
                this.csrWrite!.addr < 0,
                this.csrWrite!.data < 0,
              ],
              fence < 0,
              interruptHold < 0,
              nextPc < currentPc,
              nextSp < currentSp,
            ],
          ),
        ],
      ),
    ]);
  }

  List<Conditional> cycle(
    Logic instrIndex,
    Logic mopStep, {
    required Logic alu,
    required Logic rs1,
    required Logic rs2,
    required Logic rd,
    required Logic imm,
    required Map<String, Logic> fields,
    required DataPortInterface memRead,
    required DataPortInterface memWrite,
    required DataPortInterface rs1Read,
    required DataPortInterface rs2Read,
    required DataPortInterface rdWrite,
  }) => [];

  List<Conditional> cycleMicrocode(
    Logic instrIndex,
    Logic mopStep,
    DataPortInterface microcodeRead, {
    required Logic alu,
    required Logic rs1,
    required Logic rs2,
    required Logic rd,
    required Logic imm,
    required Map<String, Logic> fields,
    required DataPortInterface memRead,
    required DataPortInterface memWrite,
    required DataPortInterface rs1Read,
    required DataPortInterface rs2Read,
    required DataPortInterface rdWrite,
  }) => [];

  Logic compareCurrentMode(PrivilegeMode target) =>
      currentMode.eq(Const(target.id, width: 3));

  Logic selectTrapTargetMode(
    Logic trapInterrupt,
    Logic causeCode,
    Logic mode,
    Logic? mideleg,
    Logic? medeleg, {
    String? suffix,
  }) {
    suffix ??= '';

    final machine = Const(PrivilegeMode.machine.id, width: 3);
    if (csrRead == null || csrWrite == null) return machine;

    final supervisor = Const(PrivilegeMode.supervisor.id, width: 3);

    final isMachine = mode.eq(machine);
    final noSup = ~Const(hasSupervisor ? 1 : 0);

    final delegatedInterrupt = mideleg == null ? Const(0) : mideleg[causeCode];
    final delegatedException = medeleg == null ? Const(0) : medeleg[causeCode];

    final goesToSupervisor = mux(
      trapInterrupt,
      delegatedInterrupt,
      delegatedException,
    );

    final notMachineAndHasSup = ~isMachine & Const(hasSupervisor ? 1 : 0);

    return mux(
      notMachineAndHasSup,
      mux(goesToSupervisor, supervisor, machine),
      machine,
    );
  }

  Logic encodeCause(Logic trapInterrupt, Logic causeCode) =>
      (trapInterrupt.zeroExtend(mxlen.size) << (mxlen.size - 1)) |
      causeCode.zeroExtend(mxlen.size);

  Logic computeTrapVectorPc(
    Logic tvec,
    Logic causeCode,
    Logic trapInterrupt, {
    String? suffix,
  }) {
    suffix ??= '';
    final base = (tvec & Const(~0x3, width: mxlen.size)).named(
      'trapBase$suffix',
    );
    final mode = tvec.slice(1, 0).named('trapMode$suffix');

    final isVectored = mode.eq(Const(1, width: 2)).named('isVectored$suffix');

    final vecOffset = (causeCode << 2)
        .zeroExtend(mxlen.size)
        .named('tvecOffset$suffix');

    return mux(
      isVectored & trapInterrupt,
      base + vecOffset,
      base,
    ).named('tvecPc$suffix');
  }

  List<Conditional> rawTrap(
    Logic trapInterrupt,
    Logic causeCode, [
    Logic? tval,
    String? suffix,
  ]) {
    suffix ??= '';

    if (csrRead == null || csrWrite == null) {
      return [
        trapCause < encodeCause(trapInterrupt, causeCode).slice(5, 0),
        trapTval < (tval ?? Const(0, width: mxlen.size)),
        output('trap') < 1,
        done < 1,
        valid < 1,
      ];
    }

    final tvec = Logic(name: 'tvec$suffix', width: mxlen.size);

    final newMode = selectTrapTargetMode(
      trapInterrupt,
      causeCode,
      currentMode,
      mideleg,
      medeleg,
      suffix: suffix,
    );

    return [
      nextMode < newMode,
      trapCause <
          encodeCause(
            trapInterrupt,
            causeCode,
          ).slice(5, 0).named('cause$suffix'),
      trapTval < (tval ?? Const(0, width: mxlen.size)),

      tvec <
          ((stvec != null)
              ? mux(
                  newMode.eq(Const(PrivilegeMode.machine.id, width: 3)),
                  mtvec ?? Const(0, width: mxlen.size),
                  stvec ?? Const(0, width: mxlen.size),
                )
              : (mtvec ?? Const(0, width: mxlen.size))),

      nextPc <
          computeTrapVectorPc(
            ((stvec != null)
                ? mux(
                    newMode.eq(Const(PrivilegeMode.machine.id, width: 3)),
                    mtvec ?? Const(0, width: mxlen.size),
                    stvec ?? Const(0, width: mxlen.size),
                  )
                : (mtvec ?? Const(0, width: mxlen.size))),
            causeCode,
            trapInterrupt,
            suffix: suffix,
          ),

      output('trap') < 1,
      done < 1,
      valid < 1,
    ];
  }

  List<Conditional> doTrap(Trap t, [Logic? tval, String? suffix]) {
    final trapInterrupt = Const(t.interrupt ? 1 : 0);
    final causeCode = Const(t.mcauseCode, width: 6);
    return rawTrap(trapInterrupt, causeCode, tval, suffix);
  }
}

class DynamicExecutionUnit extends ExecutionUnit {
  DynamicExecutionUnit(
    Logic clk,
    Logic reset,
    Logic enable,
    Logic currentSp,
    Logic currentPc,
    Logic currentMode,
    Logic instrIndex,
    Map<String, Logic> instrTypeMap,
    Map<String, Logic> fields,
    DataPortInterface? csrRead,
    DataPortInterface? csrWrite,
    DataPortInterface memRead,
    DataPortInterface memWrite,
    DataPortInterface rs1Read,
    DataPortInterface rs2Read,
    DataPortInterface rdWrite,
    DataPortInterface microcodeRead, {
    bool hasSupervisor = false,
    bool hasUser = false,
    required Microcode microcode,
    required Mxlen mxlen,
    Logic? mideleg,
    Logic? medeleg,
    Logic? mtvec,
    Logic? stvec,
    int counterWidth = 32,
    List<String> staticInstructions = const [],
    String name = 'river_dynamic_execution_unit',
  }) : super(
         clk,
         reset,
         enable,
         currentSp,
         currentPc,
         currentMode,
         instrIndex,
         instrTypeMap,
         fields,
         csrRead,
         csrWrite,
         memRead,
         memWrite,
         rs1Read,
         rs2Read,
         rdWrite,
         microcodeRead: microcodeRead,
         hasSupervisor: hasSupervisor,
         hasUser: hasUser,
         microcode: microcode,
         mxlen: mxlen,
         mideleg: mideleg,
         medeleg: medeleg,
         mtvec: mtvec,
         stvec: stvec,
         counterWidth: counterWidth,
         staticInstructions: staticInstructions,
         name: name,
       );

  @override
  List<Conditional> cycleMicrocode(
    Logic instrIndex,
    Logic mopStep,
    DataPortInterface microcodeRead, {
    required Logic alu,
    required Logic rs1,
    required Logic rs2,
    required Logic rd,
    required Logic imm,
    required Map<String, Logic> fields,
    required DataPortInterface memRead,
    required DataPortInterface memWrite,
    required DataPortInterface rs1Read,
    required DataPortInterface rs2Read,
    required DataPortInterface rdWrite,
  }) {
    final csrRead = this.csrRead;
    final csrWrite = this.csrWrite;

    final mopCount = Logic(name: 'mopCount', width: mopStep.width);

    final mopTable = Map.fromEntries(
      kMicroOpTable
          .where((mop) {
            if (mop.funct == ReadCsrMicroOp.funct && csrRead == null)
              return false;
            if (mop.funct == WriteCsrMicroOp.funct && csrWrite == null)
              return false;
            return true;
          })
          .map((mop) => MapEntry(Microcode.mopType(mop), mop)),
    );

    final mop = mopTable.map(
      (k, mop) => MapEntry(
        k,
        Map.fromEntries(
          mop.struct(mxlen).mapping.entries.map((entry) {
            final fieldName = entry.key;
            final range = entry.value;
            final value = microcodeRead.data
                .getRange(range.start, range.end + 1)
                .named('mop${k}_$fieldName');
            return MapEntry(fieldName, value);
          }),
        ),
      ),
    );

    final funct = microcodeRead.data
        .slice(MicroOp.functRange.end, MicroOp.functRange.start)
        .named('mopFunct');

    Logic readSource(Logic source) => mux(
      source.eq(Const(MicroOpSource.imm.value, width: MicroOpSource.width)),
      imm,
      mux(
        source.eq(Const(MicroOpSource.alu.value, width: MicroOpSource.width)),
        alu,
        mux(
          source.eq(Const(MicroOpSource.rs1.value, width: MicroOpSource.width)),
          rs1,
          mux(
            source.eq(
              Const(MicroOpSource.rs2.value, width: MicroOpSource.width),
            ),
            rs2,
            mux(
              source.eq(
                Const(MicroOpSource.rd.value, width: MicroOpSource.width),
              ),
              rd,
              nextPc,
            ),
          ),
        ),
      ),
    );

    Logic readField(Logic field, {bool register = true}) => mux(
      field.eq(Const(MicroOpField.rd.value, width: MicroOpField.width)),
      (register ? rd : fields['rd']!).zeroExtend(mxlen.size),
      mux(
        field.eq(Const(MicroOpField.rs1.value, width: MicroOpField.width)),
        (register ? rs1 : fields['rs1']!).zeroExtend(mxlen.size),
        mux(
          field.eq(Const(MicroOpField.rs2.value, width: MicroOpField.width)),
          (register ? rs2 : fields['rs2']!).zeroExtend(mxlen.size),
          mux(
            field.eq(Const(MicroOpField.imm.value, width: MicroOpField.width)),
            register ? imm : fields['imm']!,
            mux(
              field.eq(Const(MicroOpField.pc.value, width: MicroOpField.width)),
              nextPc,
              nextSp,
            ),
          ),
        ),
      ),
    );

    Conditional writeField(Logic field, Logic value) => Case(
      field,
      [
        CaseItem(Const(MicroOpField.rd.value, width: MicroOpField.width), [
          rd < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.rs1.value, width: MicroOpField.width), [
          rs1 < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.rs2.value, width: MicroOpField.width), [
          rs2 < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.imm.value, width: MicroOpField.width), [
          imm < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.sp.value, width: MicroOpField.width), [
          nextSp < value.zeroExtend(mxlen.size),
        ]),
      ],
      defaultItem: [done < 1, valid < 0],
    );

    Conditional clearField(Logic field) =>
        writeField(field, readField(field, register: false));

    return [
      If.block([
        Iff(mopStep.eq(0), [
          microcodeRead.en < 1,
          microcodeRead.addr <
              (instrIndex.zeroExtend(microcodeRead.addr.width) +
                  mopStep.zeroExtend(microcodeRead.addr.width)),
          done < 0,
          valid < 0,
          If(
            microcodeRead.done & microcodeRead.valid,
            then: [
              mopCount < microcodeRead.data.slice(mopCount.width - 1, 0),
              alu < 0,
              fence < 0,
              rs1 < fields['rs1']!.zeroExtend(mxlen.size),
              rs2 < fields['rs2']!.zeroExtend(mxlen.size),
              rd < fields['rd']!.zeroExtend(mxlen.size),
              imm < fields['imm']!.zeroExtend(mxlen.size),
              mopStep < 1,
              microcodeRead.en < 0,
            ],
          ),
          If(
            microcodeRead.done & ~microcodeRead.valid,
            then: [done < 1, valid < 0, microcodeRead.en < 0],
          ),
        ]),
        Iff(rs1Read.en, [
          Case(funct, [
            CaseItem(Const(ReadRegisterMicroOp.funct, width: funct.width), [
              If(
                rs1Read.done & rs1Read.valid,
                then: [
                  writeField(
                    mop['ReadRegister']!['source']!,
                    rs1Read.data + mop['ReadRegister']!['valueOffset']!,
                  ),
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                  rs1Read.en < 0,
                ],
              ),
            ]),
          ]),
        ]),
        Iff(rs2Read.en, [
          Case(funct, [
            CaseItem(Const(ReadRegisterMicroOp.funct, width: funct.width), [
              If(
                rs2Read.done & rs2Read.valid,
                then: [
                  writeField(
                    mop['ReadRegister']!['source']!,
                    rs2Read.data + mop['ReadRegister']!['valueOffset']!,
                  ),
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                  rs2Read.en < 0,
                ],
              ),
            ]),
          ]),
        ]),
        Iff(rdWrite.en, [
          Case(funct, [
            CaseItem(Const(WriteRegisterMicroOp.funct, width: funct.width), [
              If(
                rdWrite.done & rdWrite.valid,
                then: [
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                  rdWrite.en < 0,
                ],
              ),
            ]),
          ]),
        ]),
        Iff(memRead.en, [
          Case(
            funct,
            [
              CaseItem(Const(MemLoadMicroOp.funct, width: funct.width), [
                If(
                  memRead.done & memRead.valid,
                  then: [
                    Case(mop['MemLoad']!['size']!, [
                      for (final size in MicroOpMemSize.values.where(
                        (s) => s.bytes <= mxlen.width,
                      ))
                        CaseItem(
                          Const(size.value, width: MicroOpMemSize.width),
                          [
                            writeField(
                              mop['MemLoad']!['dest']!,
                              mux(
                                mop['MemLoad']!['unsigned']!,
                                memRead.data
                                    .slice(size.bits - 1, 0)
                                    .zeroExtend(mxlen.size),
                                memRead.data
                                    .slice(size.bits - 1, 0)
                                    .signExtend(mxlen.size),
                              ),
                            ),
                            mopStep < mopStep + 1,
                            microcodeRead.en < 0,
                            memRead.en < 0,
                          ],
                        ),
                    ]),
                  ],
                ),
                If(
                  memRead.done & ~memRead.valid,
                  then: doTrap(
                    Trap.loadAccess,
                    readField(mop['MemLoad']!['base']!) + imm,
                  ),
                ),
              ]),
            ],
            defaultItem: [
              microcodeRead.en < 1,
              microcodeRead.addr <
                  (instrIndex.zeroExtend(microcodeRead.addr.width) +
                      mopStep.zeroExtend(microcodeRead.addr.width)),
            ],
          ),
        ]),
        Iff(memWrite.en, [
          Case(funct, [
            CaseItem(Const(MemStoreMicroOp.funct, width: funct.width), [
              If(
                memWrite.done & memWrite.valid,
                then: [
                  memWrite.en < 0,
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                ],
              ),
              If(
                memWrite.done & ~memWrite.valid,
                then: [
                  memWrite.en < 0,
                  ...doTrap(
                    Trap.storeAccess,
                    readField(mop['MemStore']!['base']!) + imm,
                  ),
                ],
              ),
            ]),
          ]),
        ]),
        if (csrRead != null)
          Iff(csrRead.en, [
            Case(funct, [
              CaseItem(Const(ReadCsrMicroOp.funct, width: funct.width), [
                If(
                  csrRead.done & csrRead.valid,
                  then: [
                    writeField(mop['ReadCsr']!['source']!, csrRead.data),
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                    csrRead.en < 0,
                  ],
                ),
                If(csrRead.done & ~csrRead.valid, then: doTrap(Trap.illegal)),
              ]),
            ]),
          ]),
        if (csrWrite != null)
          Iff(csrWrite.en, [
            Case(funct, [
              CaseItem(Const(WriteCsrMicroOp.funct, width: funct.width), [
                If(
                  csrWrite.done & csrWrite.valid,
                  then: [
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                    csrWrite.en < 0,
                  ],
                ),
                If(csrWrite.done & ~csrWrite.valid, then: doTrap(Trap.illegal)),
              ]),
            ]),
          ]),
        Iff((mopStep - 1).lt(mopCount), [
          If(
            microcodeRead.done & microcodeRead.valid,
            then: [
              Case(
                funct,
                [
                  CaseItem(
                    Const(ReadRegisterMicroOp.funct, width: funct.width),
                    [
                      If.block([
                        Iff(
                          (readField(
                                    mop['ReadRegister']!['source']!,
                                  ).zeroExtend(mxlen.size) +
                                  mop['ReadRegister']!['offset']!)
                              .slice(4, 0)
                              .eq(Const(Register.x0.value, width: 5)),
                          [mopStep < mopStep + 1, microcodeRead.en < 0],
                        ),
                        Iff(
                          (readField(
                                    mop['ReadRegister']!['source']!,
                                  ).zeroExtend(mxlen.size) +
                                  mop['ReadRegister']!['offset']!)
                              .slice(4, 0)
                              .eq(Const(Register.x2.value, width: 5)),
                          [
                            writeField(
                              mop['ReadRegister']!['source']!,
                              currentSp,
                            ),
                            mopStep < mopStep + 1,
                            microcodeRead.en < 0,
                          ],
                        ),
                        Else([
                          If(
                            mop['ReadRegister']!['source']!.eq(
                              Const(
                                MicroOpSource.rs2.value,
                                width: MicroOpSource.width,
                              ),
                            ),
                            then: [
                              rs2Read.en < 1,
                              rs2Read.addr <
                                  (readField(
                                            mop['ReadRegister']!['source']!,
                                          ).zeroExtend(mxlen.size) +
                                          mop['ReadRegister']!['offset']!)
                                      .slice(4, 0),
                            ],
                            orElse: [
                              rs1Read.en < 1,
                              rs1Read.addr <
                                  (readField(
                                            mop['ReadRegister']!['source']!,
                                          ).zeroExtend(mxlen.size) +
                                          mop['ReadRegister']!['offset']!)
                                      .slice(4, 0),
                            ],
                          ),
                        ]),
                      ]),
                    ],
                  ),
                  CaseItem(
                    Const(WriteRegisterMicroOp.funct, width: funct.width),
                    [
                      If(
                        (readField(
                                  mop['WriteRegister']!['field']!,
                                ).zeroExtend(mxlen.size) +
                                mop['WriteRegister']!['offset']!)
                            .slice(4, 0)
                            .eq(Const(Register.x0.value, width: 5)),
                        then: [mopStep < mopStep + 1, microcodeRead.en < 0],
                        orElse: [
                          If(
                            (readField(
                                      mop['WriteRegister']!['field']!,
                                    ).zeroExtend(mxlen.size) +
                                    mop['WriteRegister']!['offset']!)
                                .slice(4, 0)
                                .eq(Const(Register.x2.value, width: 5)),
                            then: [
                              nextSp <
                                  (readSource(
                                        mop['WriteRegister']!['source']!,
                                      ) +
                                      mop['WriteRegister']!['valueOffset']!),
                              microcodeRead.en < 0,
                            ],
                            orElse: [
                              rdWrite.en < 1,
                              rdWrite.addr <
                                  (readField(
                                            mop['WriteRegister']!['field']!,
                                          ).zeroExtend(mxlen.size) +
                                          mop['WriteRegister']!['offset']!)
                                      .slice(4, 0),
                              rdWrite.data <
                                  (readSource(
                                        mop['WriteRegister']!['source']!,
                                      ) +
                                      mop['WriteRegister']!['valueOffset']!),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  CaseItem(Const(AluMicroOp.funct, width: funct.width), [
                    Case(mop['Alu']!['alu']!, [
                      CaseItem(
                        Const(
                          MicroOpAluFunct.add.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) +
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.sub.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) -
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.and.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) &
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.or.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) |
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.xor.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) ^
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.sll.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) <<
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.srl.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) >>
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.sra.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) >>
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.slt.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              readField(mop['Alu']!['a']!)
                                  .lte(readField(mop['Alu']!['b']!))
                                  .zeroExtend(mxlen.size),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.sltu.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) -
                                      readField(mop['Alu']!['b']!))[mxlen.size -
                                      1]
                                  .zeroExtend(mxlen.size),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.masked.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) &
                                  ~readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.mul.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) *
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.mulw.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) *
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.mulh.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) *
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.mulhsu.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) *
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.mulhu.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) *
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.div.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) /
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.divu.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) /
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.divuw.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) /
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.divw.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) /
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.rem.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) %
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.remuw.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) %
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpAluFunct.remw.value,
                          width: MicroOpAluFunct.width,
                        ),
                        [
                          alu <
                              (readField(mop['Alu']!['a']!) %
                                  readField(mop['Alu']!['b']!)),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                    ]),
                  ]),
                  CaseItem(Const(UpdatePCMicroOp.funct, width: funct.width), [
                    nextPc <
                        (mux(
                                  mop['UpdatePC']!['absolute']!,
                                  Const(0, width: mxlen.size),
                                  currentPc,
                                ) +
                                mux(
                                  mop['UpdatePC']!['hasField']!,
                                  readField(mop['UpdatePC']!['offsetField']!),
                                  mux(
                                    mop['UpdatePC']!['hasSource']!,
                                    readSource(
                                      mop['UpdatePC']!['offsetSource']!,
                                    ),
                                    mop['UpdatePC']!['offset']!,
                                  ),
                                )) &
                            ~mux(
                              mop['UpdatePC']!['align']!,
                              Const(1, width: mxlen.size),
                              Const(0, width: mxlen.size),
                            ),
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                  ]),
                  CaseItem(Const(MemLoadMicroOp.funct, width: funct.width), [
                    Case(mop['MemLoad']!['size']!, [
                      for (final size in MicroOpMemSize.values.where(
                        (s) => s.bytes <= mxlen.width,
                      ))
                        CaseItem(
                          Const(size.value, width: MicroOpMemSize.width),
                          [
                            If(
                              ((readField(mop['MemLoad']!['base']!) + imm) &
                                      Const(size.bytes - 1, width: mxlen.size))
                                  .neq(0),
                              then: doTrap(
                                Trap.misalignedLoad,
                                readField(mop['MemLoad']!['base']!) + imm,
                              ),
                              orElse: [
                                memRead.en < 1,
                                memRead.addr <
                                    (readField(mop['MemLoad']!['base']!) + imm),
                              ],
                            ),
                          ],
                        ),
                    ]),
                  ]),
                  CaseItem(Const(MemStoreMicroOp.funct, width: funct.width), [
                    Case(mop['MemStore']!['size']!, [
                      for (final size in MicroOpMemSize.values.where(
                        (s) => s.bytes <= mxlen.width,
                      ))
                        CaseItem(
                          Const(size.value, width: MicroOpMemSize.width),
                          [
                            If(
                              ((readField(mop['MemStore']!['base']!) + imm) &
                                      Const(size.bytes - 1, width: mxlen.size))
                                  .neq(0),
                              then: doTrap(
                                Trap.misalignedStore,
                                readField(mop['MemStore']!['base']!) + imm,
                              ),
                              orElse: [
                                memWrite.en < 1,
                                memWrite.addr <
                                    (readField(mop['MemStore']!['base']!) +
                                        imm),
                                memWrite.data <
                                    [
                                      (Const(1, width: 7) <<
                                          mop['MemLoad']!['size']!),
                                      readField(mop['MemStore']!['src']!),
                                    ].swizzle(),
                              ],
                            ),
                          ],
                        ),
                    ]),
                  ]),
                  CaseItem(Const(TrapMicroOp.funct, width: funct.width), [
                    Case(currentMode, [
                      for (final mode in PrivilegeMode.values)
                        CaseItem(Const(mode.id, width: 3), [
                          Case(mop['Trap']![mode.name]!, [
                            for (final trap in Trap.values)
                              CaseItem(
                                Const(
                                  trap.index,
                                  width: Trap.values.length.bitLength,
                                ),
                                doTrap(trap),
                              ),
                          ]),
                        ]),
                    ]),
                  ]),
                  CaseItem(Const(BranchIfMicroOp.funct, width: funct.width), [
                    Case(mop['BranchIf']!['condition']!, [
                      CaseItem(
                        Const(
                          MicroOpCondition.eq.value,
                          width: MicroOpCondition.width,
                        ),
                        [
                          If(
                            readSource(mop['BranchIf']!['target']!).eq(0),
                            then: [
                              nextPc <
                                  mux(
                                    mop['BranchIf']!['hasField']!,
                                    readField(mop['BranchIf']!['offsetField']!),
                                    mop['BranchIf']!['offset']!,
                                  ),
                              done < 1,
                              valid < 1,
                            ],
                            orElse: [
                              mopStep < mopStep + 1,
                              microcodeRead.en < 0,
                            ],
                          ),
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpCondition.ne.value,
                          width: MicroOpCondition.width,
                        ),
                        [
                          If(
                            readSource(mop['BranchIf']!['target']!).neq(0),
                            then: [
                              nextPc <
                                  mux(
                                    mop['BranchIf']!['hasField']!,
                                    readField(mop['BranchIf']!['offsetField']!),
                                    mop['BranchIf']!['offset']!,
                                  ),
                              done < 1,
                              valid < 1,
                            ],
                            orElse: [
                              mopStep < mopStep + 1,
                              microcodeRead.en < 0,
                            ],
                          ),
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpCondition.lt.value,
                          width: MicroOpCondition.width,
                        ),
                        [
                          If(
                            readSource(mop['BranchIf']!['target']!).lt(0),
                            then: [
                              nextPc <
                                  mux(
                                    mop['BranchIf']!['hasField']!,
                                    readField(mop['BranchIf']!['offsetField']!),
                                    mop['BranchIf']!['offset']!,
                                  ),
                              done < 1,
                              valid < 1,
                            ],
                            orElse: [
                              mopStep < mopStep + 1,
                              microcodeRead.en < 0,
                            ],
                          ),
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpCondition.gt.value,
                          width: MicroOpCondition.width,
                        ),
                        [
                          If(
                            readSource(mop['BranchIf']!['target']!).gt(0),
                            then: [
                              nextPc <
                                  mux(
                                    mop['BranchIf']!['hasField']!,
                                    readField(mop['BranchIf']!['offsetField']!),
                                    mop['BranchIf']!['offset']!,
                                  ),
                              done < 1,
                              valid < 1,
                            ],
                            orElse: [
                              mopStep < mopStep + 1,
                              microcodeRead.en < 0,
                            ],
                          ),
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpCondition.ge.value,
                          width: MicroOpCondition.width,
                        ),
                        [
                          If(
                            readSource(mop['BranchIf']!['target']!).gte(0),
                            then: [
                              nextPc <
                                  mux(
                                    mop['BranchIf']!['hasField']!,
                                    readField(mop['BranchIf']!['offsetField']!),
                                    mop['BranchIf']!['offset']!,
                                  ),
                              done < 1,
                              valid < 1,
                            ],
                            orElse: [
                              mopStep < mopStep + 1,
                              microcodeRead.en < 0,
                            ],
                          ),
                        ],
                      ),
                      CaseItem(
                        Const(
                          MicroOpCondition.le.value,
                          width: MicroOpCondition.width,
                        ),
                        [
                          If(
                            readSource(mop['BranchIf']!['target']!).lte(0),
                            then: [
                              nextPc <
                                  mux(
                                    mop['BranchIf']!['hasField']!,
                                    readField(mop['BranchIf']!['offsetField']!),
                                    mop['BranchIf']!['offset']!,
                                  ),
                              done < 1,
                              valid < 1,
                            ],
                            orElse: [
                              mopStep < mopStep + 1,
                              microcodeRead.en < 0,
                            ],
                          ),
                        ],
                      ),
                    ]),
                  ]),
                  CaseItem(
                    Const(WriteLinkRegisterMicroOp.funct, width: funct.width),
                    [
                      Case(mop['WriteLinkRegister']!['link']!, [
                        for (final link in MicroOpLink.values)
                          CaseItem(Const(link.value, width: MicroOpLink.width), [
                            If(
                              (link.reg != null
                                      ? Const(link.reg!.value, width: 5)
                                      : (link.source != null
                                            ? readSource(
                                                Const(
                                                  link.source!.value,
                                                  width: MicroOpSource.width,
                                                ),
                                              ).slice(4, 0)
                                            : Const(
                                                Register.x0.value,
                                                width: 5,
                                              )))
                                  .neq(Register.x0.value),
                              then: [
                                rdWrite.en < 1,
                                rdWrite.addr <
                                    (link.reg != null
                                        ? Const(link.reg!.value, width: 5)
                                        : (link.source != null
                                              ? readSource(
                                                  Const(
                                                    link.source!.value,
                                                    width: MicroOpSource.width,
                                                  ),
                                                ).slice(4, 0)
                                              : Const(
                                                  Register.x0.value,
                                                  width: 5,
                                                ))),
                                rdWrite.data <
                                    (nextPc +
                                        mop['WriteLinkRegister']!['pcOffset']!),
                              ],
                            ),
                          ]),
                      ]),
                    ],
                  ),
                  CaseItem(Const(FenceMicroOp.funct, width: funct.width), [
                    rs1Read.en < 0,
                    rs2Read.en < 0,
                    if (csrRead != null) csrRead.en < 0,
                    if (csrWrite != null) csrWrite.en < 0,
                    memRead.en < 0,
                    memWrite.en < 0,
                    rdWrite.en < 0,
                    fence < 1,
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                  ]),
                  CaseItem(
                    Const(ValidateFieldMicroOp.funct, width: funct.width),
                    [
                      Case(mop['ValidateField']!['condition']!, [
                        CaseItem(
                          Const(
                            MicroOpCondition.eq.value,
                            width: MicroOpCondition.width,
                          ),
                          [
                            If(
                              readField(
                                mop['ValidateField']!['field']!,
                              ).eq(mop['ValidateField']!['value']!),
                              then: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
                              ],
                              orElse: doTrap(Trap.illegal),
                            ),
                          ],
                        ),
                        CaseItem(
                          Const(
                            MicroOpCondition.ne.value,
                            width: MicroOpCondition.width,
                          ),
                          [
                            If(
                              readField(
                                mop['ValidateField']!['field']!,
                              ).neq(mop['ValidateField']!['value']!),
                              then: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
                              ],
                              orElse: doTrap(Trap.illegal),
                            ),
                          ],
                        ),
                        CaseItem(
                          Const(
                            MicroOpCondition.lt.value,
                            width: MicroOpCondition.width,
                          ),
                          [
                            If(
                              readField(
                                mop['ValidateField']!['field']!,
                              ).lt(mop['ValidateField']!['value']!),
                              then: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
                              ],
                              orElse: doTrap(Trap.illegal),
                            ),
                          ],
                        ),
                        CaseItem(
                          Const(
                            MicroOpCondition.gt.value,
                            width: MicroOpCondition.width,
                          ),
                          [
                            If(
                              readField(
                                mop['ValidateField']!['field']!,
                              ).gt(mop['ValidateField']!['value']!),
                              then: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
                              ],
                              orElse: doTrap(Trap.illegal),
                            ),
                          ],
                        ),
                        CaseItem(
                          Const(
                            MicroOpCondition.ge.value,
                            width: MicroOpCondition.width,
                          ),
                          [
                            If(
                              readField(
                                mop['ValidateField']!['field']!,
                              ).gte(mop['ValidateField']!['value']!),
                              then: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
                              ],
                              orElse: doTrap(Trap.illegal),
                            ),
                          ],
                        ),
                        CaseItem(
                          Const(
                            MicroOpCondition.le.value,
                            width: MicroOpCondition.width,
                          ),
                          [
                            If(
                              readField(
                                mop['ValidateField']!['field']!,
                              ).lte(mop['ValidateField']!['value']!),
                              then: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
                              ],
                              orElse: doTrap(Trap.illegal),
                            ),
                          ],
                        ),
                      ]),
                    ],
                  ),
                  CaseItem(
                    Const(ModifyLatchMicroOp.funct, width: funct.width),
                    [
                      If(
                        mop['ModifyLatch']!['replace']!,
                        then: [
                          writeField(
                            mop['ModifyLatch']!['field']!,
                            readSource(mop['ModifyLatch']!['source']!),
                          ),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                        orElse: [
                          clearField(mop['ModifyLatch']!['field']!),
                          mopStep < mopStep + 1,
                          microcodeRead.en < 0,
                        ],
                      ),
                    ],
                  ),
                  CaseItem(Const(SetFieldMicroOp.funct, width: funct.width), [
                    writeField(
                      mop['SetField']!['field']!,
                      mop['SetField']!['value']!,
                    ),
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                  ]),
                  CaseItem(
                    Const(InterruptHoldMicroOp.funct, width: funct.width),
                    [
                      interruptHold < 1,
                      mopStep < mopStep + 1,
                      microcodeRead.en < 0,
                    ],
                  ),
                  if (csrRead != null)
                    CaseItem(Const(ReadCsrMicroOp.funct, width: funct.width), [
                      If(
                        currentMode.eq(Const(PrivilegeMode.user.id, width: 3)),
                        then: doTrap(Trap.illegal),
                        orElse: [
                          csrRead.en < 1,
                          csrRead.addr <
                              readField(
                                mop['ReadCsr']!['source']!,
                              ).slice(11, 0),
                        ],
                      ),
                    ]),
                  if (csrWrite != null)
                    CaseItem(Const(WriteCsrMicroOp.funct, width: funct.width), [
                      If(
                        currentMode.eq(Const(PrivilegeMode.user.id, width: 3)),
                        then: doTrap(Trap.illegal),
                        orElse: [
                          csrWrite.en < 1,
                          csrWrite.addr <
                              readField(
                                mop['WriteCsr']!['field']!,
                              ).slice(11, 0),
                          csrWrite.data <
                              readSource(mop['WriteCsr']!['source']!),
                        ],
                      ),
                    ]),
                  CaseItem(Const(TlbFenceMicroOp.funct, width: funct.width), [
                    // TODO: once MMU has a TLB
                    mopStep < mopStep + 1,
                    microcodeRead.en < 0,
                  ]),
                  CaseItem(
                    Const(TlbInvalidateMicroOp.funct, width: funct.width),
                    [
                      // TODO: once MMU has a TLB
                      mopStep < mopStep + 1,
                      microcodeRead.en < 0,
                    ],
                  ),
                  CaseItem(Const(0, width: funct.width), []),
                ],
                defaultItem: [done < 1, valid < 0],
              ),
            ],
          ),
          If(
            microcodeRead.en & microcodeRead.done & ~microcodeRead.valid,
            then: [done < 1, valid < 0],
          ),
          If(
            ~microcodeRead.en,
            then: [
              microcodeRead.en < 1,
              microcodeRead.addr <
                  (instrIndex.zeroExtend(microcodeRead.addr.width) +
                      mopStep.zeroExtend(microcodeRead.addr.width)),
            ],
          ),
        ]),
        Else([done < 1, valid < 1]),
      ]),
    ];
  }
}

class StaticExecutionUnit extends ExecutionUnit {
  StaticExecutionUnit(
    super.clk,
    super.reset,
    super.enable,
    super.currentSp,
    super.currentPc,
    super.currentMode,
    super.instrIndex,
    super.instrTypeMap,
    super.fields,
    super.csrRead,
    super.csrWrite,
    super.memRead,
    super.memWrite,
    super.rs1Read,
    super.rs2Read,
    super.rdWrite, {
    super.hasSupervisor = false,
    super.hasUser = false,
    required super.microcode,
    required super.mxlen,
    super.mideleg,
    super.medeleg,
    super.mtvec,
    super.stvec,
    super.staticInstructions = const [],
    super.counterWidth = 32,
    super.name = 'river_static_execution_unit',
  });

  @override
  List<Conditional> cycle(
    Logic instrIndex,
    Logic mopStep, {
    required Logic alu,
    required Logic rs1,
    required Logic rs2,
    required Logic rd,
    required Logic imm,
    required Map<String, Logic> fields,
    required DataPortInterface memRead,
    required DataPortInterface memWrite,
    required DataPortInterface rs1Read,
    required DataPortInterface rs2Read,
    required DataPortInterface rdWrite,
  }) {
    final csrRead = this.csrRead;
    final csrWrite = this.csrWrite;

    final maxLen = microcode.microOpSequences.values
        .map((s) => s.ops.length * 2)
        .fold(0, (a, b) => a > b ? a : b);

    Logic readSource(MicroOpSource source) {
      switch (source) {
        case MicroOpSource.imm:
          return imm;
        case MicroOpSource.alu:
          return alu;
        case MicroOpSource.rs1:
          return rs1;
        case MicroOpSource.rs2:
          return rs2;
        case MicroOpSource.rd:
          return rd;
        case MicroOpSource.pc:
          return nextPc;
        default:
          throw 'Invalid source $source';
      }
    }

    Logic readField(MicroOpField field, {bool register = true}) {
      switch (field) {
        case MicroOpField.rd:
          return (register ? rd : fields['rd']!).zeroExtend(mxlen.size);
        case MicroOpField.rs1:
          return (register ? rs1 : fields['rs1']!).zeroExtend(mxlen.size);
        case MicroOpField.rs2:
          return (register ? rs2 : fields['rs2']!).zeroExtend(mxlen.size);
        case MicroOpField.imm:
          return register ? imm : fields['imm']!;
        case MicroOpField.pc:
          return nextPc;
        case MicroOpField.sp:
          return nextSp;
        default:
          throw 'Invalid field $field';
      }
    }

    Conditional writeField(MicroOpField field, Logic value) {
      switch (field) {
        case MicroOpField.rd:
          return rd < value.zeroExtend(mxlen.size);
        case MicroOpField.rs1:
          return rs1 < value.zeroExtend(mxlen.size);
        case MicroOpField.rs2:
          return rs2 < value.zeroExtend(mxlen.size);
        case MicroOpField.imm:
          return imm < value.zeroExtend(mxlen.size);
        case MicroOpField.sp:
          return nextPc < value.zeroExtend(mxlen.size);
        case MicroOpField.sp:
          return nextSp < value.zeroExtend(mxlen.size);
        default:
          throw 'Invalid field $field';
      }
    }

    Conditional clearField(MicroOpField field) =>
        writeField(field, fields[field.name]!.zeroExtend(mxlen.size));

    return [
      Case(
        instrIndex,
        microcode.execLookup.entries
            .where(
              (entry) => staticInstructions.isNotEmpty
                  ? staticInstructions.contains(entry.value.mnemonic)
                  : true,
            )
            .map((entry) {
              final op = entry.value;
              final steps = <CaseItem>[];

              for (final mop in op.indexedMicrocode.values) {
                final i = steps.length + 1;

                if (mop is ReadRegisterMicroOp) {
                  final addr =
                      (readField(mop.source) +
                              Const(mop.offset, width: mxlen.size))
                          .slice(4, 0);
                  final port = mop.source == MicroOpSource.rs2
                      ? rs2Read
                      : rs1Read;
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        addr.eq(Const(Register.x2.value, width: 5)),
                        then: [
                          writeField(mop.source, currentSp),
                          mopStep < mopStep + 2,
                        ],
                        orElse: [
                          port.addr < addr,
                          port.en < 1,
                          mopStep < mopStep + 1,
                        ],
                      ),
                    ]),
                  );

                  steps.add(
                    CaseItem(Const(i + 1, width: maxLen.bitLength), [
                      writeField(
                        mop.source,
                        port.data + Const(mop.valueOffset, width: mxlen.size),
                      ),
                      If(port.done & port.valid, then: [mopStep < mopStep + 1]),
                    ]),
                  );
                } else if (mop is WriteRegisterMicroOp) {
                  final addr =
                      (readField(mop.field) +
                              Const(mop.offset, width: mxlen.size))
                          .slice(4, 0);

                  final value =
                      (readSource(mop.source) +
                      Const(mop.valueOffset, width: mxlen.size));

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        addr.eq(Const(Register.x2.value, width: 5)),
                        then: [nextSp < value],
                      ),
                      rdWrite.addr < addr,
                      rdWrite.data < value,
                      rdWrite.en < addr.gt(0),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is AluMicroOp) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      alu <
                          (switch (mop.alu) {
                            MicroOpAluFunct.add =>
                              readField(mop.a) + readField(mop.b),
                            MicroOpAluFunct.sub =>
                              readField(mop.a) - readField(mop.b),
                            MicroOpAluFunct.and =>
                              readField(mop.a) & readField(mop.b),
                            MicroOpAluFunct.or =>
                              readField(mop.a) | readField(mop.b),
                            MicroOpAluFunct.xor =>
                              readField(mop.a) ^ readField(mop.b),
                            MicroOpAluFunct.sll =>
                              readField(mop.a) << readField(mop.b),
                            MicroOpAluFunct.srl =>
                              readField(mop.a) >> readField(mop.b),
                            MicroOpAluFunct.sra =>
                              readField(mop.a) >> readField(mop.b),
                            MicroOpAluFunct.slt => readField(
                              mop.a,
                            ).lte(readField(mop.b)).zeroExtend(mxlen.size),
                            MicroOpAluFunct.sltu =>
                              (readField(mop.a) - readField(mop.b))[mxlen.size -
                                      1]
                                  .zeroExtend(mxlen.size),
                            MicroOpAluFunct.masked =>
                              readField(mop.a) & ~readField(mop.b),
                            MicroOpAluFunct.mul =>
                              readField(mop.a) * readField(mop.b),
                            MicroOpAluFunct.mulw =>
                              readField(mop.a) * readField(mop.b),
                            MicroOpAluFunct.mulh =>
                              readField(mop.a) * readField(mop.b),
                            MicroOpAluFunct.mulhsu =>
                              readField(mop.a) * readField(mop.b),
                            MicroOpAluFunct.mulhu =>
                              readField(mop.a) * readField(mop.b),
                            MicroOpAluFunct.div =>
                              readField(mop.a) / readField(mop.b),
                            MicroOpAluFunct.divu =>
                              readField(mop.a) / readField(mop.b),
                            MicroOpAluFunct.divuw =>
                              readField(mop.a) / readField(mop.b),
                            MicroOpAluFunct.divw =>
                              readField(mop.a) / readField(mop.b),
                            MicroOpAluFunct.rem =>
                              readField(mop.a) % readField(mop.b),
                            MicroOpAluFunct.remu =>
                              readField(mop.a) % readField(mop.b),
                            MicroOpAluFunct.remuw =>
                              readField(mop.a) % readField(mop.b),
                            MicroOpAluFunct.remw =>
                              readField(mop.a) % readField(mop.b),
                            _ => throw 'Invalid ALU function ${mop.alu}',
                          }).named(
                            'alu_${op.mnemonic}_${mop.alu.name}_${mop.a.name}_${mop.b.name}',
                          ),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is UpdatePCMicroOp) {
                  Logic value = Const(mop.offset, width: mxlen.size);
                  if (mop.offsetField != null)
                    value = readField(mop.offsetField!);
                  if (mop.offsetSource != null)
                    value = readSource(mop.offsetSource!);
                  if (mop.align) value &= ~Const(1, width: mxlen.size);

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      nextPc < (mop.absolute ? value : (currentPc + value)),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is MemLoadMicroOp) {
                  final base = readField(mop.base);
                  final addr = base + imm;

                  final unaligned =
                      (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(
                        0,
                      );

                  final raw = memRead.data.slice(mop.size.bits - 1, 0);

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        unaligned,
                        then: doTrap(
                          Trap.misalignedLoad,
                          addr,
                          '_${op.mnemonic}',
                        ),
                        orElse: [
                          memRead.en < 1,
                          memRead.addr < addr,
                          mopStep < mopStep + 1,
                        ],
                      ),
                    ]),
                  );

                  steps.add(
                    CaseItem(Const(i + 1, width: maxLen.bitLength), [
                      If(
                        memRead.en & memRead.done & memRead.valid,
                        then: [
                          writeField(
                            mop.dest,
                            mop.unsigned
                                ? raw.zeroExtend(mxlen.size)
                                : raw.signExtend(mxlen.size),
                          ),
                          mopStep < mopStep + 1,
                        ],
                      ),
                      If(
                        memRead.en & memRead.done & ~memRead.valid,
                        then: doTrap(Trap.loadAccess, addr, '_${op.mnemonic}'),
                      ),
                    ]),
                  );
                } else if (mop is MemStoreMicroOp) {
                  final base = readField(mop.base);
                  final value = readField(mop.src);
                  final addr = base + imm;

                  final unaligned =
                      (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(
                        0,
                      );

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        unaligned,
                        then: doTrap(
                          Trap.misalignedStore,
                          addr,
                          '_${op.mnemonic}',
                        ),
                        orElse: [
                          memWrite.en < 1,
                          memWrite.addr < addr,
                          memWrite.data <
                              [Const(mop.size.bits, width: 7), value].swizzle(),
                          If(
                            memWrite.done & memWrite.valid,
                            then: [memWrite.en < 0, mopStep < mopStep + 1],
                          ),
                          If(
                            memWrite.done & ~memWrite.valid,
                            then: [
                              memWrite.en < 0,
                              ...doTrap(
                                Trap.storeAccess,
                                addr,
                                '_${op.mnemonic}',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ]),
                  );
                } else if (mop is TrapMicroOp) {
                  final kindMachine = mop.kindMachine;
                  final kindSupervisor = mop.kindSupervisor ?? kindMachine;
                  final kindUser = mop.kindUser ?? kindSupervisor;

                  Logic computeKind(
                    PrivilegeMode expectedMode,
                    Logic a,
                    Logic b, [
                    Logic? fallback,
                  ]) {
                    final value = a == b
                        ? a
                        : mux(
                            currentMode.eq(Const(expectedMode.id, width: 3)),
                            a,
                            b,
                          );
                    return switch (expectedMode) {
                      PrivilegeMode.machine => value,
                      PrivilegeMode.supervisor =>
                        hasSupervisor ? value : (fallback ?? b),
                      PrivilegeMode.user => hasUser ? value : (fallback ?? b),
                    };
                  }

                  steps.add(
                    CaseItem(
                      Const(i, width: maxLen.bitLength),
                      rawTrap(
                        computeKind(
                          PrivilegeMode.machine,
                          Const(kindMachine.interrupt),
                          computeKind(
                            PrivilegeMode.supervisor,
                            Const(kindSupervisor.interrupt),
                            computeKind(
                              PrivilegeMode.user,
                              Const(kindUser.interrupt),
                              Const(kindMachine.interrupt),
                            ),
                            Const(kindMachine.interrupt),
                          ),
                        ),
                        computeKind(
                          PrivilegeMode.machine,
                          Const(kindMachine.mcauseCode, width: 6),
                          computeKind(
                            PrivilegeMode.supervisor,
                            Const(kindSupervisor.mcauseCode, width: 6),
                            computeKind(
                              PrivilegeMode.user,
                              Const(kindUser.mcauseCode, width: 6),
                              Const(kindMachine.mcauseCode, width: 6),
                            ),
                            Const(kindMachine.mcauseCode, width: 6),
                          ),
                        ),
                        null,
                        '_${op.mnemonic}',
                      ),
                    ),
                  );
                } else if (mop is BranchIfMicroOp) {
                  final target = readSource(mop.target);

                  final value = mop.offsetField != null
                      ? readField(mop.offsetField!)
                      : Const(mop.offset, width: mxlen.size);

                  final condition = switch (mop.condition) {
                    MicroOpCondition.eq => target.eq(0),
                    MicroOpCondition.ne => target.neq(0),
                    MicroOpCondition.lt => target.lt(0),
                    MicroOpCondition.gt => target.gt(0),
                    MicroOpCondition.ge => target.gte(0),
                    MicroOpCondition.le => target.lte(0),
                  };

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        condition,
                        then: [nextPc < value, done < 1, valid < 1],
                        orElse: [mopStep < mopStep + 1],
                      ),
                    ]),
                  );
                } else if (mop is WriteLinkRegisterMicroOp) {
                  final value = nextPc + Const(mop.pcOffset, width: mxlen.size);

                  Logic reg = Const(Register.x0.value, width: 5);
                  if (mop.link.reg != null) {
                    reg = Const(mop.link.reg!.value, width: 5);
                  } else if (mop.link.source != null) {
                    reg = readSource(mop.link.source!);
                  }

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        reg.neq(Register.x0.value),
                        then: [
                          rdWrite.addr < reg.slice(4, 0),
                          rdWrite.data < value,
                          rdWrite.en < 1,
                        ],
                      ),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is FenceMicroOp) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      rs1Read.en < 0,
                      rs2Read.en < 0,
                      if (csrRead != null) csrRead.en < 0,
                      if (csrWrite != null) csrWrite.en < 0,
                      memRead.en < 0,
                      memWrite.en < 0,
                      rdWrite.en < 0,
                      fence < 1,
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is ValidateFieldMicroOp) {
                  final field = readField(mop.field);
                  final value = Const(mop.value, width: mxlen.size);

                  final condition = switch (mop.condition) {
                    MicroOpCondition.eq => field.eq(value),
                    MicroOpCondition.ne => field.neq(value),
                    MicroOpCondition.lt => field.lt(value),
                    MicroOpCondition.gt => field.gt(value),
                    MicroOpCondition.ge => field.gte(value),
                    MicroOpCondition.le => field.lte(value),
                    _ => throw 'Invalid condition: ${mop.condition}',
                  };

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        condition,
                        then: [mopStep < mopStep + 1],
                        orElse: doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                      ),
                    ]),
                  );
                } else if (mop is ModifyLatchMicroOp) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      if (mop.replace)
                        writeField(mop.field, readSource(mop.source))
                      else
                        clearField(mop.field),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is SetFieldMicroOp) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      writeField(
                        mop.field,
                        Const(mop.value, width: mxlen.size),
                      ),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is InterruptHoldMicroOp) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      interruptHold < 1,
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is ReadCsrMicroOp && csrRead != null) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        currentMode.eq(Const(PrivilegeMode.user.id, width: 3)),
                        then: doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                        orElse: [
                          csrRead.en < 1,
                          csrRead.addr < readField(mop.source).slice(11, 0),
                          mopStep < mopStep + 1,
                        ],
                      ),
                    ]),
                  );

                  steps.add(
                    CaseItem(Const(i + 1, width: maxLen.bitLength), [
                      If.block([
                        Iff(csrRead.en & csrRead.done & csrRead.valid, [
                          writeField(mop.source, csrRead.data),
                          mopStep < mopStep + 1,
                        ]),
                        Iff(
                          csrRead.en & csrRead.done & ~csrRead.valid,
                          doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                        ),
                      ]),
                    ]),
                  );
                } else if (mop is WriteCsrMicroOp && csrWrite != null) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        currentMode.eq(Const(PrivilegeMode.user.id, width: 3)),
                        then: doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                        orElse: [
                          csrWrite.en < 1,
                          csrWrite.addr < readField(mop.field).slice(11, 0),
                          csrWrite.data < readSource(mop.source),
                          mopStep < mopStep + 1,
                        ],
                      ),
                    ]),
                  );

                  steps.add(
                    CaseItem(Const(i + 1, width: maxLen.bitLength), [
                      If.block([
                        Iff(csrWrite.en & csrWrite.done & csrWrite.valid, [
                          mopStep < mopStep + 1,
                        ]),
                        Iff(
                          csrWrite.en & csrWrite.done & ~csrWrite.valid,
                          doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                        ),
                      ]),
                    ]),
                  );
                } else if (mop is TlbFenceMicroOp) {
                  // TODO: once MMU has a TLB
                } else if (mop is TlbInvalidateMicroOp) {
                  // TODO: once MMU has a TLB
                } else {
                  print(mop);
                }
              }

              return CaseItem(Const(entry.key, width: instrIndex.width), [
                Case(mopStep, [
                  CaseItem(Const(0, width: maxLen.bitLength), [
                    alu < 0,
                    fence < 0,
                    rs1 < fields['rs1']!.zeroExtend(mxlen.size),
                    rs2 < fields['rs2']!.zeroExtend(mxlen.size),
                    rd < fields['rd']!.zeroExtend(mxlen.size),
                    imm < fields['imm']!.zeroExtend(mxlen.size),
                    mopStep < 1,
                  ]),
                  ...steps,
                  CaseItem(Const(steps.length + 1, width: maxLen.bitLength), [
                    done < 1,
                    valid < 1,
                  ]),
                ]),
              ]);
            })
            .toList(),
        defaultItem: [
          alu < 0,
          mopStep < 0,
          done < 1,
          valid < 0,
          rs1Read.en < 0,
          rs1Read.addr < 0,
          rs2Read.en < 0,
          rs2Read.addr < 0,
          rdWrite.en < 0,
          rdWrite.addr < 0,
          rdWrite.data < 0,
          memRead.en < 0,
          memRead.addr < 0,
          memWrite.en < 0,
          memWrite.addr < 0,
          memWrite.data < 0,
        ],
      ),
    ];
  }
}
