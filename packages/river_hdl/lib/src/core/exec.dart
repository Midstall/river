import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import '../data_port.dart';
import '../compat.dart';
import '../microcode_rom.dart';
import 'alu_ops.dart';
import 'iterative_divider.dart';
import 'iterative_multiplier.dart';
import 'microcode_alu.dart';

/// Div/rem functs routed to the shared [IterativeDivider] instead of a
/// combinational `/`/`%`. Whole RV32M/RV64M div+rem set (signed/unsigned, full+word).
const _kIterativeDivRem = {
  RiscVAluFunct.div,
  RiscVAluFunct.divu,
  RiscVAluFunct.divw,
  RiscVAluFunct.divuw,
  RiscVAluFunct.rem,
  RiscVAluFunct.remu,
  RiscVAluFunct.remw,
  RiscVAluFunct.remuw,
};

/// Manual IEEE-754 compare of two same-width float bit patterns [a],[b]
/// (ROHD-HCL has no FP comparator). Returns less-than / equal / ordered
/// (neither operand is NaN) as 1-bit Logics; handles +0==-0 and NaN-unordered.
/// [width] is the total bit width, [expBits] the exponent field width.
({Logic lt, Logic eq, Logic ordered}) fpCompare(
  Logic a,
  Logic b,
  int width,
  int expBits,
) {
  final manBits = width - 1 - expBits;
  final sa = a[width - 1];
  final sb = b[width - 1];
  final expA = a.slice(width - 2, manBits);
  final expB = b.slice(width - 2, manBits);
  final manA = a.slice(manBits - 1, 0);
  final manB = b.slice(manBits - 1, 0);
  final magA = a.slice(width - 2, 0); // exp:mantissa magnitude
  final magB = b.slice(width - 2, 0);
  final allOnes = Const((1 << expBits) - 1, width: expBits);
  final aNaN = expA.eq(allOnes) & manA.neq(0);
  final bNaN = expB.eq(allOnes) & manB.neq(0);
  final bothZero = magA.eq(0) & magB.eq(0);
  final sameSign = sa.eq(sb);
  final ltMag = mux(sa, magA.gt(magB), magA.lt(magB)); // negative => reversed
  final lt = mux(sameSign, ltMag, sa & ~bothZero); // diff sign: a<b iff a<0
  final eq = bothZero | (sameSign & magA.eq(magB));
  final ordered = ~(aNaN | bNaN);
  return (lt: lt, eq: eq, ordered: ordered);
}

/// Selects the privilege mode a trap is delivered to: supervisor when the core
/// is below M-mode, supervisor is configured, and the cause is delegated
/// (medeleg/mideleg); otherwise machine. Pure (no module state) so both the
/// in-order [ExecutionUnit] and the OoO commit path can call it.
Logic selectTrapTargetModeTop(
  Logic trapInterrupt,
  Logic causeCode,
  Logic mode,
  Logic? mideleg,
  Logic? medeleg, {
  required bool hasCsr,
  required bool hasSupervisor,
}) {
  final machine = Const(PrivilegeMode.machine.id, width: 3);
  if (!hasCsr) return machine;
  final supervisor = Const(PrivilegeMode.supervisor.id, width: 3);
  final isMachine = mode.eq(machine);
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

/// Computes the trap-handler PC from a tvec CSR: base = tvec & ~3; vectored
/// mode (tvec[1:0]==1) adds 4*cause but only for interrupts. Pure helper shared
/// by the in-order and OoO trap paths.
Logic computeTrapVectorPcTop(
  Logic tvec,
  Logic causeCode,
  Logic trapInterrupt,
  RiscVMxlen mxlen, {
  String? suffix,
}) {
  suffix ??= '';
  final base = (tvec & Const(~0x3, width: mxlen.size)).named('trapBase$suffix');
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

abstract class ExecutionUnit extends Module {
  final MicrocodeRom microcode;
  final RiscVMxlen mxlen;
  final int vlen;
  final bool hasSupervisor;
  final bool hasUser;
  // When true the mul family uses the shared multi-cycle IterativeMultiplier
  // (chunk multiply reused per cycle) instead of a single-cycle partial-product
  // tree. The area sign is config-dependent (measured both ways: iterative loses
  // on creek+DFU 25F, wins on creek_weir DDR rv64 25F). Re-measure post-pack per
  // config before flipping.
  final bool useIterativeMul;
  // Zvfh = half-precision (SEW=16) vector FP. Derived from the ISA config so a
  // core without it never elaborates the FP16 lane units (8 adders + 8 mults at
  // VLEN=128).
  bool get hasZvfh => microcode.isa.extensions.any((e) => e.name == 'Zvfh');
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
  // Async interrupt take (computed in core.dart from mip&mie + mode/delegation).
  // When [interruptTake] is high at an instruction boundary (mopStep==0), an
  // interrupt trap with cause [interruptCause] is taken instead of the fetched
  // instruction, vectoring through the shared trap helpers.
  late final Logic? interruptTake;
  late final Logic? interruptCause;
  late final Logic?
  virtIn; // V-bit: VS-mode access to an HS-only CSR -> cause 22
  // Smstateen SE0 bits, for the VS-mode state-enable virtual-instruction nuance.
  late final Logic? mstateen0Se0;
  late final Logic? hstateen0Se0;
  late final Logic? memFaultGuest; // dport fault was in the G-stage -> guest PF

  // LR/SC reservation (A extension): a single address reservation set by
  // load-reserved and consumed/cleared by store-conditional.
  late final Logic reservationValid;
  late final Logic reservationAddr;
  // AMO scratch: holds the loaded ("old") value across the dynamic-microcode
  // read -> modify -> write phases of a single RiscVAtomicMemory micro-op, so
  // the destination register gets the pre-modification value on completion.
  late final Logic amoOld;

  // Floating-point (F/D) register file, internal to the in-order unit. Present
  // only when the configured ISA uses FP regs (detected from op resources).
  // FP reads/writes are routed here when an op's RfResource marks the field FP.
  DataPortInterface? fprs1Read;
  DataPortInterface? fprs2Read;
  DataPortInterface? fprdWrite;
  HarborRegisterFile? fpRegfile;

  // Vector register file (32 x VLEN), present when the ISA has the V extension.
  DataPortInterface? vrs1Read;
  DataPortInterface? vrs2Read;
  DataPortInterface? vrdWrite;
  HarborRegisterFile? vRegfile;
  // Vector config state, written by vsetvli, read by vector ops: _vtype holds
  // vtypei (vsew[5:3]/vlmul[2:0]); _vl holds the active element count. _vtmp
  // holds an arith result across the read-modify-write for vl/tail masking.
  Logic? _vtype;
  Logic? _vl;
  Logic? _vtmp;
  // LMUL grouping: the register index (0..LMUL-1) within the destination group
  // currently being processed by a vector arith op.
  Logic? _vregIdx;

  // Single-precision FP arithmetic results, combinationally computed from the
  // rs1/rs2 operand latches by ROHD-HCL units (present when hasFloat).
  Logic? _fpAddS;
  Logic? _fpSubS;
  Logic? _fpMulS;
  Logic? _fpSqrtS;
  Logic? _fpAddD;
  Logic? _fpSubD;
  Logic? _fpMulD;
  Logic? _fpSqrtD;
  // Fused multiply-add results: rd = +-(rs1*rs2) +- rs3. Built by reusing the FP
  // multiplier and adding 4 adders per precision (one per sign combination).
  Logic? _fmaddS;
  Logic? _fmsubS;
  Logic? _fnmsubS;
  Logic? _fnmaddS;
  Logic? _fmaddD;
  Logic? _fmsubD;
  Logic? _fnmsubD;
  Logic? _fnmaddD;
  // The rs3 operand latch (instance field so cycle()'s readField/writeField can
  // reach it without threading a new param through every cycle variant).
  Logic? _rs3Latch;
  // fp->int rounding+saturation support: |operand| converted losslessly to a
  // Q64.N fixed (N = full mantissa width, so no rounding loss). cycle() extracts
  // integer/round/sticky from these and applies the per-rm rounding + signed/
  // unsigned saturation. `_cvtOvf*` flags |operand| >= 2^64.
  Logic? _cvtMagS; // Q64.24 magnitude of the f32 operand (89 bits)
  Logic? _cvtOvfS;
  Logic? _cvtMagD; // Q64.53 magnitude of the f64 operand (118 bits)
  Logic? _cvtOvfD;
  // fcvt int<->fp results. fp->int (W/L, signed/unsigned) is handled by the
  // unified roundSatFpToInt in cycle(); only int->fp + precision converts are
  // pre-built here.
  Logic? _fcvtSW; // int32 -> f32
  Logic? _fcvtDW; // int32 -> f64
  Logic? _fcvtSD; // f64 -> f32 (narrow)
  Logic? _fcvtDS; // f32 -> f64 (widen)
  Logic? _fcvtSL; // int64 -> f32
  Logic? _fcvtDL; // int64 -> f64
  // Unsigned int->fp (rs2 bit0): s.wu/s.lu / d.wu/d.lu.
  Logic? _fcvtSWu; // uint32 -> f32
  Logic? _fcvtSLu; // uint64 -> f32
  Logic? _fcvtDWu; // uint32 -> f64
  Logic? _fcvtDLu; // uint64 -> f64
  // Multi-cycle Newton-Raphson divider state (shared across precisions; only
  // one fdiv runs at a time in-order). _divStep sequences the FSM; _recip holds
  // the reciprocal estimate x; _divT holds the intermediate b*x. The reused
  // multiplier/adder outputs are _divMulOut{S,D}; seeds are _divSeed{S,D}.
  Logic? _divStep;
  Logic? _recip;
  Logic? _divT;
  Logic? _divSeedS;
  Logic? _divSeedD;
  Logic? _divMulOutS;
  Logic? _divMulOutD;
  // Shared multi-cycle integer divider (M-extension div/rem), present when the
  // ISA has M. One instance replaces the eight combinational div/rem trees that
  // otherwise dominate the static execution unit's LUTs. The div/rem mop holds
  // [_idivStart] high while resident and reads back the divider outputs; see
  // StaticExecutionUnit.cycle and iterative_divider.dart.
  IterativeDivider? _idiv;
  Logic? _idivStart;
  Logic? _idivDividend;
  Logic? _idivDivisor;

  // Shared multi-cycle iterative multiplier (M mul family), present when the ISA
  // has M. Replaces the single-cycle 64x64 partial-product tree (a large LUT4
  // cost on ECP5 25F): one chunk-multiply reused per cycle accumulates the 2*XLEN
  // unsigned product. A mul/mulh* mop holds [_imulStart] while resident and reads
  // back IterativeMultiplier.product; signed-high flavors apply the same two
  // sign-correction subtracts as the single-cycle path. See iterative_multiplier.dart.
  IterativeMultiplier? _imul;
  Logic? _imulStart;
  Logic? _imulA;
  Logic? _imulB;

  Logic get done => output('done');
  Logic get valid => output('valid');
  Logic get nextSp => output('nextSp');
  Logic get nextPc => output('nextPc');
  Logic get nextMode => output('nextMode');
  Logic get trap => output('trap');
  Logic get trapCause => output('trapCause');
  Logic get trapInterrupt => output('trapInterrupt');
  Logic get trapTval => output('trapTval');
  Logic get trapEpc => output('trapEpc');
  Logic get isReturn => output('isReturn');
  Logic get returnLevel => output('returnLevel');
  Logic get memGuest => output('memGuest');
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
    this.useIterativeMul = true,
    required this.microcode,
    required this.mxlen,
    this.vlen = 128,
    Logic? mideleg,
    Logic? medeleg,
    Logic? mtvec,
    Logic? stvec,
    Logic? interruptTake,
    Logic? interruptCause,
    Logic? virtIn,
    Logic? mstateen0Se0,
    Logic? hstateen0Se0,
    Logic? memFaultGuest,
    // Asserted when the instruction at currentPc could not be fetched because
    // its translation faulted. The cycle raises instructionPageFault instead of
    // executing (there is no instruction).
    Logic? fetchFault,
    int counterWidth = 32,
    this.staticInstructions = const [],
    super.name = 'river_execution_unit',
  }) {
    this.clk = clk = addInput('clk', clk);

    reset = addInput('reset', reset);
    enable = addInput('enable', enable);

    this.currentSp = addInput('currentSp', currentSp, width: mxlen.size);
    currentSp = this.currentSp;

    this.currentPc = addInput('currentPc', currentPc, width: mxlen.size);
    currentPc = this.currentPc;

    this.currentMode = addInput('currentMode', currentMode, width: 3);
    currentMode = this.currentMode;

    final fetchFaultIn = fetchFault == null
        ? Const(0)
        : addInput('fetchFault', fetchFault);

    instrIndex = addInput(
      'instrIndex',
      instrIndex,
      width: microcode.opIndexWidth,
    );

    instrTypeMap = Map.fromEntries(
      instrTypeMap.entries.map(
        (entry) => MapEntry(entry.key, addInput(entry.value.name, entry.value)),
      ),
    );

    fields = Map.fromEntries(
      fields.entries.map(
        (entry) => MapEntry(
          entry.key,
          addInput(entry.value.name, entry.value, width: entry.value.width),
        ),
      ),
    );

    if (csrRead != null) {
      this.csrRead = csrRead.clone()
        ..connectIO(
          this,
          csrRead,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'csrRead_$og',
        );
      csrRead = this.csrRead;
    } else {
      this.csrRead = null;
    }

    if (csrWrite != null) {
      this.csrWrite = csrWrite.clone()
        ..connectIO(
          this,
          csrWrite,
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
      microcodeRead = microcodeRead.clone()
        ..connectIO(
          this,
          microcodeRead,
          outputTags: {DataPortGroup.control},
          inputTags: {DataPortGroup.data, DataPortGroup.integrity},
          uniquify: (og) => 'microcodeRead_$og',
        );
    }

    if (mideleg != null) {
      this.mideleg = addInput('mideleg', mideleg, width: mxlen.size);
    } else {
      this.mideleg = null;
    }
    if (medeleg != null) {
      this.medeleg = addInput('medeleg', medeleg, width: mxlen.size);
    } else {
      this.medeleg = null;
    }
    if (mtvec != null) {
      this.mtvec = addInput('mtvec', mtvec, width: mxlen.size);
    } else {
      this.mtvec = null;
    }
    if (stvec != null) {
      this.stvec = addInput('stvec', stvec, width: mxlen.size);
    } else {
      this.stvec = null;
    }
    if (interruptTake != null) {
      this.interruptTake = addInput('interruptTake', interruptTake);
      this.interruptCause = addInput(
        'interruptCause',
        interruptCause!,
        width: 6,
      );
    } else {
      this.interruptTake = null;
      this.interruptCause = null;
    }
    if (virtIn != null) {
      this.virtIn = addInput('virtIn', virtIn);
    } else {
      this.virtIn = null;
    }
    this.mstateen0Se0 = mstateen0Se0 == null
        ? null
        : addInput('mstateen0Se0', mstateen0Se0);
    this.hstateen0Se0 = hstateen0Se0 == null
        ? null
        : addInput('hstateen0Se0', hstateen0Se0);
    if (memFaultGuest != null) {
      this.memFaultGuest = addInput('memFaultGuest', memFaultGuest);
    } else {
      this.memFaultGuest = null;
    }

    addOutput('done');
    addOutput('valid');
    addOutput('nextSp', width: mxlen.size);
    addOutput('nextPc', width: mxlen.size);
    addOutput('nextMode', width: 3);
    addOutput('trap');
    addOutput('trapCause', width: 6);
    // 1 when the committed trap is an interrupt (async), 0 for a synchronous
    // exception. The core sets mcause bit XLEN-1 from this; trapCause carries
    // only the low cause code (also used for delegation indexing).
    addOutput('trapInterrupt');
    addOutput('trapTval', width: mxlen.size);
    // PC of the trapping instruction → {m,s}epc. Captured here (not from the
    // core's live pc register, which has already advanced to tvec by the time
    // the registered trap pulse reaches core).
    addOutput('trapEpc', width: mxlen.size);
    // xRET (MRET/SRET): isReturn pulses on the retire cycle; returnLevel is the
    // privilege level being returned FROM (3=MRET, 1=SRET). core.dart restores
    // PC/mode from {m,s}epc/{m,s}status on this pulse.
    addOutput('isReturn');
    addOutput('returnLevel', width: 3);
    // Asserted for the duration of an HLV/HSV (hypervisor virtual) memory access
    // so the MMU translates it through the guest two-stage tables even from
    // HS-mode (virt=0). Held while memRead/memWrite.en is held (same registered
    // timing), so the multi-cycle walk sees it throughout.
    addOutput('memGuest');
    addOutput('fence');
    addOutput('interruptHold');
    addOutput('counter', width: counterWidth);

    final maxLen = microcode.microOpSequences.values
        .map((s) => s.ops.length * 2)
        .fold(0, (a, b) => a > b ? a : b);

    final mopStep = Logic(name: 'mopStep', width: maxLen.bitLength);

    final alu = Logic(name: 'aluState', width: mxlen.size);
    final rs1 = Logic(name: 'rs1State', width: mxlen.size);
    final rs2 = Logic(name: 'rs2State', width: mxlen.size);
    // Third source latch, used by the fused multiply-add ops (rs3). Its FP read
    // reuses fprs1Read (reads are sequential), so no extra regfile port is needed.
    final rs3 = Logic(name: 'rs3State', width: mxlen.size);
    _rs3Latch = rs3;
    final rd = Logic(name: 'rdState', width: mxlen.size);
    final imm = Logic(name: 'immState', width: mxlen.size);

    reservationValid = Logic(name: 'reservationValid');
    reservationAddr = Logic(name: 'reservationAddr', width: mxlen.size);
    amoOld = Logic(name: 'amoOld', width: mxlen.size);

    // Floating-point register file (F/D). Instantiated only when some handled
    // op reads/writes an FP register (RfResource with RiscVFloatRegFile). The
    // FP regfile is 64 bits wide (holds D; F values are NaN-boxed/low-32).
    final hasFloat = microcode.execLookup.values.any(
      (op) => op.resources.any(
        (r) => r is RfResource && r.regfile is RiscVFloatRegFile,
      ),
    );
    if (hasFloat) {
      final fp1 = DataPortInterface(64, 5);
      final fp2 = DataPortInterface(64, 5);
      final fpw = DataPortInterface(64, 5);
      final fpRegs = HarborRegisterFile(
        numEntries: 32,
        dataWidth: 64,
        name: 'fp_regfile',
        // RISC-V has no hardwired-zero float register: f0/ft0 is a normal
        // storage entry (unlike integer x0). Without this the default
        // reservedZero=true forces f0 to read as zero regardless of writes.
        reservedZero: false,
      );
      fpRegs.input('clk').srcConnection! <= clk;
      fpRegs.input('reset').srcConnection! <= reset;
      fpRegs.input('rd0_addr').srcConnection! <= fp1.addr;
      fpRegs.input('rd1_addr').srcConnection! <= fp2.addr;
      fpRegs.input('wr_en').srcConnection! <= fpw.en;
      fpRegs.input('wr_addr').srcConnection! <= fpw.addr;
      fpRegs.input('wr_data').srcConnection! <= fpw.data;
      fp1.data <= fpRegs.rd0Data;
      fp2.data <= fpRegs.rd1Data;
      fp1.done <= fp1.en;
      fp1.valid <= fp1.en;
      fp2.done <= fp2.en;
      fp2.valid <= fp2.en;
      fpw.done <= fpw.en;
      fpw.valid <= fpw.en;
      fprs1Read = fp1;
      fprs2Read = fp2;
      fprdWrite = fpw;
      fpRegfile = fpRegs;

      // Single-precision FP arithmetic (combinational ROHD-HCL units wired to
      // the operand latches). fsub = fadd with b's sign flipped.
      final fa = FloatingPoint32();
      fa <= rs1.slice(31, 0);
      final fb = FloatingPoint32();
      fb <= rs2.slice(31, 0);
      final fnegb = FloatingPoint32();
      fnegb <= rs2.slice(31, 0) ^ (Const(1, width: 32) << 31);
      Logic packed(FloatingPoint f) =>
          [f.sign, f.exponent, f.mantissa].swizzle();
      final add = FloatingPointAdderSinglePath(fa, fb);
      final sub = FloatingPointAdderSinglePath(fa, fnegb);
      final mul = FloatingPointMultiplierSimple(fa, fb);
      final sqrt = FloatingPointSqrtSimple(fa);
      _fpAddS = packed(add.sum);
      _fpSubS = packed(sub.sum);
      _fpMulS = packed(mul.product);
      _fpSqrtS = packed(sqrt.sqrt);

      // Fused multiply-add (single): reuse the product (rs1*rs2) and add +-rs3.
      // Negation flips the sign bit. fmadd=+p+c, fmsub=+p-c, fnmsub=-p+c,
      // fnmadd=-p-c. Four adders feed the four functs (selected in the switch).
      final fmaNegProdS = FloatingPoint32();
      fmaNegProdS <= packed(mul.product) ^ (Const(1, width: 32) << 31);
      final fmaCS = FloatingPoint32();
      fmaCS <= rs3.slice(31, 0);
      final fmaNegCS = FloatingPoint32();
      fmaNegCS <= rs3.slice(31, 0) ^ (Const(1, width: 32) << 31);
      _fmaddS = packed(FloatingPointAdderSinglePath(mul.product, fmaCS).sum);
      _fmsubS = packed(FloatingPointAdderSinglePath(mul.product, fmaNegCS).sum);
      _fnmsubS = packed(FloatingPointAdderSinglePath(fmaNegProdS, fmaCS).sum);
      _fnmaddS = packed(
        FloatingPointAdderSinglePath(fmaNegProdS, fmaNegCS).sum,
      );

      // fcvt int<->float (single). The emulator truncates toward zero and
      // ignores rm; FixedToFloat/FloatToFixed do the same, so this matches the
      // golden model. fcvt.s.w: signed int32 -> f32. fcvt.w.s: f32 -> int32
      // (RTZ), sign-extended to xlen.
      // FixedToFloat rejects fractionWidth==0 (it computes log2Ceil(0) = -inf),
      // so use Q31.1 with the int pre-shifted left by 1: value = bits/2 == N.
      final intIn = FixedPoint(
        signed: true,
        integerWidth: 31,
        fractionWidth: 1,
      );
      intIn <= (rs1.slice(31, 0).signExtend(33) << 1);
      final outSW = FloatingPoint32();
      FixedToFloat(intIn, outSW);
      _fcvtSW = packed(outSW);

      // int64->f32: FixedToFloat rejects fractionWidth==0, so use Q64.1 with the
      // 64-bit signed integer pre-shifted left by 1 (value = bits/2 == N); the
      // extra integer bit preserves the full 64-bit magnitude (no top-bit loss).
      final intInL = FixedPoint(
        signed: true,
        integerWidth: 64,
        fractionWidth: 1,
      );
      intInL <= (rs1.signExtend(66) << 1);
      final outSL = FloatingPoint32();
      FixedToFloat(intInL, outSL);
      _fcvtSL = packed(outSL);

      // Unsigned single-precision int->fp conversions (rs2 bit0 set). uint->fp
      // uses an unsigned FixedPoint (Q.1 pre-shift, like the signed path) so
      // FixedToFloat treats the source as magnitude-only. (fp->uint is handled by
      // the unified roundSatFpToInt in cycle().)
      final uInW = FixedPoint(
        signed: false,
        integerWidth: 32,
        fractionWidth: 1,
      );
      uInW <= (rs1.slice(31, 0).zeroExtend(33) << 1);
      final outSWu = FloatingPoint32();
      FixedToFloat(uInW, outSWu);
      _fcvtSWu = packed(outSWu);
      final uInL = FixedPoint(
        signed: false,
        integerWidth: 64,
        fractionWidth: 1,
      );
      uInL <= (rs1.zeroExtend(65) << 1);
      final outSLu = FloatingPoint32();
      FixedToFloat(uInL, outSLu);
      _fcvtSLu = packed(outSLu);

      // Magnitude of the f32 operand as a lossless Q64.24 fixed (24 fraction
      // bits = full f32 mantissa). cycle() reads integer=[87:24], round=[23],
      // sticky=|[22:0] from this for per-rm rounding + saturation. checkOverflow
      // flags |f| >= 2^64.
      final absFaS = FloatingPoint32();
      absFaS <= (rs1.slice(31, 0) & Const(0x7FFFFFFF, width: 32));
      final f2magS = FloatToFixed(
        absFaS,
        integerWidth: 64,
        fractionWidth: 24,
        checkOverflow: true,
      );
      _cvtMagS = f2magS.fixed.packed;
      _cvtOvfS = f2magS.overflow ?? Const(0);

      // fdiv: multi-cycle Newton-Raphson reusing ONE multiplier + adder per
      // precision (sequenced by _divStep in the FpuOp handler), keeps
      // elaboration cheap vs. unrolling ~14 FP units. Reciprocal seed
      // x0 = (2*bias<<manBits) - bits(b), exact for power-of-two divisors.
      // _divStep phases: 0 = load seed; odd 1..7 = t<=b*x; even 2..8 =
      // x<=x*(2-t); 9 = result<=a*x (4 iterations -> ~56-bit, full f32/f64).
      _divStep = Logic(name: 'divStep', width: 4);
      _recip = Logic(name: 'recipEst', width: 64);
      _divT = Logic(name: 'divT', width: 64);
      final divIsFinal = _divStep!.eq(9);
      final divIsX = ~_divStep![0] & ~_divStep!.eq(0); // even, !=0 => x*(2-t)

      _divSeedS =
          Const(BigInt.from(2 * 127) << 23, width: 32) - rs2.slice(31, 0);
      final divTwoS = FloatingPoint32();
      divTwoS <= Const(0x40000000, width: 32); // 2.0f
      final divNegTS = FloatingPoint32();
      divNegTS <= _divT!.slice(31, 0) ^ (Const(1, width: 32) << 31);
      final divUS = packed(FloatingPointAdderSinglePath(divTwoS, divNegTS).sum);
      final divMulInAS = FloatingPoint32();
      divMulInAS <=
          mux(
            divIsFinal,
            rs1.slice(31, 0),
            mux(divIsX, _recip!.slice(31, 0), rs2.slice(31, 0)),
          );
      final divMulInBS = FloatingPoint32();
      divMulInBS <= mux(divIsX, divUS, _recip!.slice(31, 0));
      _divMulOutS = packed(
        FloatingPointMultiplierSimple(divMulInAS, divMulInBS).product,
      );

      // Double-precision arithmetic (only when the ISA uses 64-bit FP regs).
      final hasDouble = microcode.execLookup.values.any(
        (op) => op.resources.any(
          (r) =>
              r is RfResource &&
              r.regfile is RiscVFloatRegFile &&
              (r.regfile as RiscVFloatRegFile).width == 64,
        ),
      );
      if (hasDouble) {
        final da = FloatingPoint64();
        da <= rs1;
        final db = FloatingPoint64();
        db <= rs2;
        final dnegb = FloatingPoint64();
        dnegb <= rs2 ^ (Const(1, width: 64) << 63);
        final dadd = FloatingPointAdderSinglePath(da, db);
        final dsub = FloatingPointAdderSinglePath(da, dnegb);
        final dmul = FloatingPointMultiplierSimple(da, db);
        final dsqrt = FloatingPointSqrtSimple(da);
        _fpAddD = packed(dadd.sum);
        _fpSubD = packed(dsub.sum);
        _fpMulD = packed(dmul.product);
        _fpSqrtD = packed(dsqrt.sqrt);

        // Fused multiply-add (double): mirrors the single path with FP64 units.
        final fmaNegProdD = FloatingPoint64();
        fmaNegProdD <= packed(dmul.product) ^ (Const(1, width: 64) << 63);
        final fmaCD = FloatingPoint64();
        fmaCD <= rs3;
        final fmaNegCD = FloatingPoint64();
        fmaNegCD <= rs3 ^ (Const(1, width: 64) << 63);
        _fmaddD = packed(FloatingPointAdderSinglePath(dmul.product, fmaCD).sum);
        _fmsubD = packed(
          FloatingPointAdderSinglePath(dmul.product, fmaNegCD).sum,
        );
        _fnmsubD = packed(FloatingPointAdderSinglePath(fmaNegProdD, fmaCD).sum);
        _fnmaddD = packed(
          FloatingPointAdderSinglePath(fmaNegProdD, fmaNegCD).sum,
        );

        // fcvt for double: int32<->f64 and f32<->f64 precision converts.
        final outDW = FloatingPoint64();
        FixedToFloat(intIn, outDW); // signed int32 -> f64
        _fcvtDW = packed(outDW);
        // int64 -> f64 (fcvt.d.l); fp->int for double is handled by the unified
        // roundSatFpToInt in cycle().
        final outDL = FloatingPoint64();
        FixedToFloat(intInL, outDL); // int64 -> f64 (Q64.1 fixed from above)
        _fcvtDL = packed(outDL);

        // Unsigned double int->fp conversions (rs2 bit0); the unsigned FixedPoint
        // inputs (uInW/uInL) are reused with f64 outputs.
        final outDWu = FloatingPoint64();
        FixedToFloat(uInW, outDWu);
        _fcvtDWu = packed(outDWu);
        final outDLu = FloatingPoint64();
        FixedToFloat(uInL, outDLu);
        _fcvtDLu = packed(outDLu);

        // Magnitude of the f64 operand as a lossless Q64.53 fixed (53 fraction
        // bits = full f64 mantissa). Same role as _cvtMagS for the single path.
        final absDaD = FloatingPoint64();
        absDaD <=
            (rs1 &
                Const(BigInt.parse('7FFFFFFFFFFFFFFF', radix: 16), width: 64));
        final f2magD = FloatToFixed(
          absDaD,
          integerWidth: 64,
          fractionWidth: 53,
          checkOverflow: true,
        );
        _cvtMagD = f2magD.fixed.packed;
        _cvtOvfD = f2magD.overflow ?? Const(0);

        // f64 -> f32 (narrow): zero-extend into the 64-bit latch.
        final outSD = FloatingPoint32();
        FloatingPointConverter(da, outSD);
        _fcvtSD = packed(outSD).zeroExtend(mxlen.size);
        // f32 -> f64 (widen): take the low 32 bits as the source float.
        final outDS = FloatingPoint64();
        FloatingPointConverter(fa, outDS);
        _fcvtDS = packed(outDS);

        // fdiv.d reuses the same _divStep FSM (divIsFinal/divIsX) with FP64
        // units and the full 64-bit recip/T registers.
        _divSeedD = Const(BigInt.from(2 * 1023) << 52, width: 64) - rs2;
        final divTwoD = FloatingPoint64();
        divTwoD <= Const(BigInt.from(0x4000000000000000), width: 64); // 2.0d
        final divNegTD = FloatingPoint64();
        divNegTD <= _divT! ^ (Const(1, width: 64) << 63);
        final divUD = packed(
          FloatingPointAdderSinglePath(divTwoD, divNegTD).sum,
        );
        final divMulInAD = FloatingPoint64();
        divMulInAD <= mux(divIsFinal, rs1, mux(divIsX, _recip!, rs2));
        final divMulInBD = FloatingPoint64();
        divMulInBD <= mux(divIsX, divUD, _recip!);
        _divMulOutD = packed(
          FloatingPointMultiplierSimple(divMulInAD, divMulInBD).product,
        );
      }
    }

    // Vector register file (32 x VLEN). Present when any handled op has a
    // VectorResource. Zero-latency, ROHD auto-detects the submodule.
    final hasVector = microcode.execLookup.values.any(
      (op) => op.resources.any((r) => r is VectorResource),
    );
    if (hasVector) {
      final v1 = DataPortInterface(vlen, 5);
      final v2 = DataPortInterface(vlen, 5);
      final vw = DataPortInterface(vlen, 5);
      final vregs = HarborRegisterFile(
        numEntries: 32,
        dataWidth: vlen,
        name: 'v_regfile',
      );
      vregs.input('clk').srcConnection! <= clk;
      vregs.input('reset').srcConnection! <= reset;
      vregs.input('rd0_addr').srcConnection! <= v1.addr;
      vregs.input('rd1_addr').srcConnection! <= v2.addr;
      vregs.input('wr_en').srcConnection! <= vw.en;
      vregs.input('wr_addr').srcConnection! <= vw.addr;
      vregs.input('wr_data').srcConnection! <= vw.data;
      v1.data <= vregs.rd0Data;
      v2.data <= vregs.rd1Data;
      v1.done <= v1.en;
      v1.valid <= v1.en;
      v2.done <= v2.en;
      v2.valid <= v2.en;
      vw.done <= vw.en;
      vw.valid <= vw.en;
      vrs1Read = v1;
      vrs2Read = v2;
      vrdWrite = vw;
      vRegfile = vregs;
      _vtype = Logic(name: 'vtypeState', width: 11);
      _vl = Logic(name: 'vlState', width: mxlen.size);
      _vtmp = Logic(name: 'vtmpState', width: vlen);
      _vregIdx = Logic(name: 'vregIdxState', width: 4);
    }

    // One shared multi-cycle integer divider for the whole div/rem family
    // (built when the ISA has M). Its control register [_idivStart] is driven
    // and reset alongside the other multi-cycle state in the Sequential below;
    // the operand nets carry unsigned magnitudes selected by the resident
    // div/rem mop (StaticExecutionUnit.cycle). Unused (start tied low) on the
    // microcode/OoO paths, where synthesis prunes it.
    if (microcode.isa.extensions.any((e) => e.name == 'M')) {
      _idivStart = Logic(name: 'idivStart');
      _idivDividend = Logic(name: 'idivDividend', width: mxlen.size);
      _idivDivisor = Logic(name: 'idivDivisor', width: mxlen.size);
      _idiv = IterativeDivider(
        clk,
        reset,
        _idivStart!,
        _idivDividend!,
        _idivDivisor!,
        width: mxlen.size,
      );
      if (useIterativeMul) {
        _imulStart = Logic(name: 'imulStart');
        _imulA = Logic(name: 'imulA', width: mxlen.size);
        _imulB = Logic(name: 'imulB', width: mxlen.size);
        _imul = IterativeMultiplier(
          clk,
          reset,
          _imulStart!,
          _imulA!,
          _imulB!,
          width: mxlen.size,
        );
      }
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          alu < 0,
          mopStep < 0,
          done < 0,
          output('trap') < 0,
          output('trapInterrupt') < 0,
          output('trapEpc') < currentPc,
          output('isReturn') < 0,
          output('returnLevel') < 0,
          output('memGuest') < 0,
          reservationValid < 0,
          amoOld < 0,
          if (_divStep != null) _divStep! < 0,
          if (_idivStart != null) ...[
            _idivStart! < 0,
            _idivDividend! < 0,
            _idivDivisor! < 0,
          ],
          if (_imulStart != null) ...[
            _imulStart! < 0,
            _imulA! < 0,
            _imulB! < 0,
          ],
          // Pragmatic power-on vector config (e32, vl=VLMAX) so ops work before
          // an explicit vsetvli; real code sets vtype/vl first. (RVV proper
          // would reset vill; this convenience keeps non-vsetvli tests valid.)
          if (_vtype != null) _vtype! < Const(0x10, width: 11),
          if (_vl != null) _vl! < Const(vlen ~/ 32, width: mxlen.size),
          if (_vtmp != null) _vtmp! < 0,
          if (_vregIdx != null) _vregIdx! < 0,
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
          nextMode < Const(PrivilegeMode.machine.id, width: 3),
          counter < 0,
        ],
        orElse: [
          If(
            enable,
            then: [
              counter < (counter + 1),
              // Default: privilege is unchanged and no trap. doTrap/MRET/SRET
              // override these later in the same Sequential, taking precedence.
              nextMode < currentMode,
              output('trap') < 0,
              output('trapEpc') < currentPc,
              output('isReturn') < 0,
              output('returnLevel') < 0,
              output('memGuest') < 0,
              // A fetch fault means there is no instruction to run: raise an
              // instruction page fault at currentPc (the faulting PC) instead.
              // An async interrupt is taken only at a CLEAN instruction boundary:
              // mopStep==0 AND no memory or register-write side effect is in
              // flight. mopStep==0 alone is NOT a clean boundary. An atomic runs
              // its whole read-modify-write at mopStep==0 (the read-completion
              // wrapper issues the write and the write-completion wrapper writes
              // rd, neither advances mopStep), so mopStep stays 0 across the
              // memRead wait, the memWrite wait and the rd commit. Taking the
              // interrupt during that window lets the posted write commit on
              // silicon while rd and the PC do not retire, so the atomic re-runs
              // and applies the operation twice (a skipped ticket that deadlocks
              // a ticket spinlock). It also leaves memRead/memWrite.en asserted
              // into the handler, because rawTrap does not clear them. Gating on
              // the held (registered) memRead.en, memWrite.en and rdWrite.en
              // holds the interrupt off until the access retires, so the atomic
              // is indivisible with respect to the interrupt. At a true boundary
              // all three are 0 and epc is the not-yet-run instruction. It
              // vectors through the same rawTrap path as a synchronous trap.
              If(
                (this.interruptTake ?? Const(0)) &
                    mopStep.eq(0) &
                    ~memRead.en &
                    ~memWrite.en &
                    ~rdWrite.en,
                then: rawTrap(
                  Const(1),
                  this.interruptCause ?? Const(0, width: 6),
                  Const(0, width: mxlen.size),
                ),
                orElse: [
                  If(
                    fetchFaultIn,
                    then: doTrap(Trap.instructionPageFault, currentPc),
                    orElse: microcodeRead != null
                        ? cycleMicrocode(
                            instrIndex,
                            mopStep,
                            microcodeRead,
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
                          ),
                  ),
                ],
              ),
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
              nextMode < currentMode,
              output('trap') < 0,
              output('trapEpc') < currentPc,
              output('isReturn') < 0,
              output('returnLevel') < 0,
              output('memGuest') < 0,
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
  }) => selectTrapTargetModeTop(
    trapInterrupt,
    causeCode,
    mode,
    mideleg,
    medeleg,
    hasCsr: csrRead != null && csrWrite != null,
    hasSupervisor: hasSupervisor,
  );

  Logic encodeCause(Logic trapInterrupt, Logic causeCode) =>
      (trapInterrupt.zeroExtend(mxlen.size) << (mxlen.size - 1)) |
      causeCode.zeroExtend(mxlen.size);

  Logic computeTrapVectorPc(
    Logic tvec,
    Logic causeCode,
    Logic trapInterrupt, {
    String? suffix,
  }) => computeTrapVectorPcTop(
    tvec,
    causeCode,
    trapInterrupt,
    mxlen,
    suffix: suffix,
  );

  List<Conditional> rawTrap(
    Logic trapInterrupt,
    Logic causeCode, [
    Logic? tval,
    String? suffix,
    Logic? modeCause,
  ]) {
    suffix ??= '';

    // A trap op with modeCause set re-encodes its cause from the originating
    // privilege/virt: ECALL becomes U/VU=8, HS=9, VS=10, M=11. Every other trap
    // keeps its fixed causeCode. Centralized here so the static path, the
    // microcode path, and any future privilege-dependent trap share one cause
    // encoding (the switched cause also feeds delegation via
    // selectTrapTargetMode below).
    final effCause = (modeCause == null)
        ? causeCode
        : mux(
            modeCause,
            mux(
              currentMode.eq(Const(PrivilegeMode.machine.id, width: 3)),
              Const(11, width: 6),
              mux(
                currentMode.eq(Const(PrivilegeMode.supervisor.id, width: 3)),
                mux(
                  virtIn ?? Const(0),
                  Const(10, width: 6),
                  Const(9, width: 6),
                ),
                Const(8, width: 6),
              ),
            ),
            causeCode,
          );

    if (csrRead == null || csrWrite == null) {
      return [
        trapCause < encodeCause(trapInterrupt, effCause).slice(5, 0),
        output('trapInterrupt') < trapInterrupt,
        trapTval < (tval ?? Const(0, width: mxlen.size)),
        output('trapEpc') < currentPc,
        output('trap') < 1,
        done < 1,
        valid < 1,
      ];
    }

    final tvec = Logic(name: 'tvec$suffix', width: mxlen.size);

    final newMode = selectTrapTargetMode(
      trapInterrupt,
      effCause,
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
            effCause,
          ).slice(5, 0).named('cause$suffix'),
      output('trapInterrupt') < trapInterrupt,
      trapTval < (tval ?? Const(0, width: mxlen.size)),
      output('trapEpc') < currentPc,

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
            effCause,
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
    final causeCode = Const(t.causeCode, width: 6);
    return rawTrap(trapInterrupt, causeCode, tval, suffix);
  }

  /// VS-mode state-enable virtual-instruction: a guest sstateen (0x10C-0x10F)
  /// access that mstateen0.SE0 permits but hstateen0.SE0 blocks. (An
  /// mstateen-blocked access is illegal, raised by the CSR legality path.)
  /// Const(0) for a core without stateen + hypervisor support.
  Logic _stateenVsViol(Logic addr12) {
    final mse0 = mstateen0Se0;
    final hse0 = hstateen0Se0;
    if (mse0 == null || hse0 == null) return Const(0);
    return (virtIn ?? Const(0)) &
        addr12.gte(Const(0x10C, width: 12)) &
        addr12.lte(Const(0x10F, width: 12)) &
        mse0 &
        ~hse0;
  }
}

class DynamicExecutionUnit extends ExecutionUnit {
  DynamicExecutionUnit(
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
    super.rdWrite,
    DataPortInterface microcodeRead, {
    super.hasSupervisor,
    super.hasUser,
    required super.microcode,
    required super.mxlen,
    super.vlen = 128,
    super.mideleg,
    super.medeleg,
    super.mtvec,
    super.stvec,
    super.interruptTake,
    super.interruptCause,
    super.virtIn,
    super.mstateen0Se0,
    super.hstateen0Se0,
    super.memFaultGuest,
    super.fetchFault,
    super.counterWidth,
    super.staticInstructions,
    super.name = 'river_dynamic_execution_unit',
  }) : super(microcodeRead: microcodeRead);

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

    // Micro-op funct codes this config's ROM actually emits. A funct-Case arm
    // whose funct is never emitted is dead logic (the ROM can never produce it),
    // so drop it and its operand datapath. Derived from the ROM alone, so each
    // config keeps exactly its arms. rc1-s (RV64IMAC) e.g. never emits
    // TlbFence/TlbInvalidate/InterruptHold/FpuOp.
    final emittedFuncts = microcode.emittedFuncts;
    bool functEmitted(int f) => emittedFuncts.contains(f);

    final mopTable = Map.fromEntries(
      kMicroOpTable
          .where((mop) {
            if (mop.funct == ReadCsrMicroOp.funct && csrRead == null) {
              return false;
            }
            if (mop.funct == WriteCsrMicroOp.funct && csrWrite == null) {
              return false;
            }
            return true;
          })
          .map((mop) => MapEntry(MicrocodeRom.mopType(mop), mop)),
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
      source.eq(Const(MicroOpSource.imm, width: MicroOpSource.width)),
      imm,
      mux(
        source.eq(Const(MicroOpSource.alu, width: MicroOpSource.width)),
        alu,
        mux(
          source.eq(Const(MicroOpSource.rs1, width: MicroOpSource.width)),
          rs1,
          mux(
            source.eq(Const(MicroOpSource.rs2, width: MicroOpSource.width)),
            rs2,
            mux(
              source.eq(Const(MicroOpSource.rd, width: MicroOpSource.width)),
              rd,
              nextPc,
            ),
          ),
        ),
      ),
    );

    Logic readField(Logic field, {bool register = true}) => mux(
      field.eq(Const(MicroOpField.rd, width: MicroOpField.width)),
      (register ? rd : fields['rd']!).zeroExtend(mxlen.size),
      mux(
        field.eq(Const(MicroOpField.rs1, width: MicroOpField.width)),
        (register ? rs1 : fields['rs1']!).zeroExtend(mxlen.size),
        mux(
          field.eq(Const(MicroOpField.rs2, width: MicroOpField.width)),
          (register ? rs2 : fields['rs2']!).zeroExtend(mxlen.size),
          mux(
            field.eq(Const(MicroOpField.imm, width: MicroOpField.width)),
            register ? imm : fields['imm']!,
            mux(
              field.eq(Const(MicroOpField.pc, width: MicroOpField.width)),
              nextPc,
              nextSp,
            ),
          ),
        ),
      ),
    );

    // Shared microcode-ALU operands: hoisted out of the ~19-arm funct Case so
    // synth infers ONE operand mux per side instead of one per arm (mux-bound).
    final aluA = readField(mop['Alu']!['a']!);
    final aluB = readField(mop['Alu']!['b']!);

    // Shared single-cycle integer ALU: ONE control-driven unit for all 18
    // single-cycle funct arms (add/sub/logic/shift/compare/word/zicond). mul
    // (iterative _imul) and div/rem (IterativeDivider) stay multi-cycle and
    // explicit; everything else falls through to this result.
    final microcodeAlu = MicrocodeAlu(
      aluA,
      aluB,
      mop['Alu']!['alu']!,
      mxlen: mxlen,
    ).result;

    // Atomics (AMO/LR/SC) exist ONLY at word and doubleword width (RISC-V has no
    // sub-word atomic; the ROM never emits a byte/half atomic size, see harbor
    // rv_a.dart). Restricting the atomic size Cases to these widths drops the
    // unreachable byte/half arms (each a full operand-read + combine). The AMO
    // combine (amoNewVal, a 9-way afunct mux) per size is the biggest mux source
    // in the unit (~22% of all muxes at byte+word widths).
    bool atomicSize(RiscVMemSize s) =>
        (s.bytes == 4 || s.bytes == 8) && s.bytes <= mxlen.width;

    // Shared memory-address base operand: the base read is the SAME 6:1 operand
    // mux in all five memory handlers (MemLoad/MemStore/LoadReserved/
    // StoreConditional/AtomicMemory), differing only in which 3-bit ROM field
    // selects it. Mux the cheap selector by the active micro-op so ONE wide
    // readField serves them all instead of five (mux-bound).
    Logic functIs(int f) => funct.eq(Const(f, width: funct.width));
    final opBase = readField(
      mux(
        functIs(MemLoadMicroOp.funct),
        mop['MemLoad']!['base']!,
        mux(
          functIs(MemStoreMicroOp.funct),
          mop['MemStore']!['base']!,
          mux(
            functIs(LoadReservedMicroOp.funct),
            mop['LoadReserved']!['base']!,
            mux(
              functIs(StoreConditionalMicroOp.funct),
              mop['StoreConditional']!['base']!,
              mop['AtomicMemory']!['base']!,
            ),
          ),
        ),
      ),
    );

    // Shared store-data operand: MemStore and StoreConditional both read a `src`
    // field (mutually-exclusive funct arms, both drive memWrite.data). Mux the
    // 3-bit selector by funct so ONE readField serves both (mux-bound).
    final opStoreSrc = readField(
      mux(
        functIs(MemStoreMicroOp.funct),
        mop['MemStore']!['src']!,
        mop['StoreConditional']!['src']!,
      ),
    );

    // Shared operand-source read. WriteRegister, ModifyLatch, MoveToField and
    // WriteCsr each read a MicroOpSource operand in mutually-exclusive funct
    // arms; muxing the 3-bit source selector by funct lets ONE readSource serve
    // them all (mux-bound). Only folds in micro-ops present in this ROM.
    Logic srcSel = mop['WriteRegister']!['source']!;
    if (mop.containsKey('ModifyLatch')) {
      srcSel = mux(
        functIs(ModifyLatchMicroOp.funct),
        mop['ModifyLatch']!['source']!,
        srcSel,
      );
    }
    if (mop.containsKey('MoveToField')) {
      srcSel = mux(
        functIs(SetFieldMicroOpFunct.funct),
        mop['MoveToField']!['src']!,
        srcSel,
      );
    }
    if (csrWrite != null && mop.containsKey('WriteCsr')) {
      srcSel = mux(
        functIs(WriteCsrMicroOp.funct),
        mop['WriteCsr']!['source']!,
        srcSel,
      );
    }
    if (mop.containsKey('UpdatePC')) {
      srcSel = mux(
        functIs(UpdatePCMicroOp.funct),
        mop['UpdatePC']!['offsetSource']!,
        srcSel,
      );
    }
    final sharedSourceVal = readSource(srcSel);

    // Shared operand-field read for the mutually-exclusive UpdatePC and
    // CopyField arms (both readField(...) a micro-op field with the default
    // register variant); one shared 6:1 operand mux instead of two.
    Logic? sharedFieldVal;
    if (mop.containsKey('UpdatePC') && mop.containsKey('CopyField')) {
      sharedFieldVal = readField(
        mux(
          functIs(UpdatePCMicroOp.funct),
          mop['UpdatePC']!['offsetField']!,
          mop['CopyField']!['src']!,
        ),
      );
    }

    // Shared CSR address read. ReadCsr and WriteCsr are mutually-exclusive funct
    // arms that both derive the 12-bit CSR index from a micro-op field via
    // readField(...).slice(11,0); muxing the field selector by funct shares that
    // single readField operand mux. Built only when a CSR port exists.
    Logic? csrAddr;
    if (csrRead != null || csrWrite != null) {
      var csrAddrSel = mop['ReadCsr']!['source']!;
      if (csrWrite != null) {
        csrAddrSel = mux(
          functIs(WriteCsrMicroOp.funct),
          mop['WriteCsr']!['field']!,
          csrAddrSel,
        );
      }
      csrAddr = readField(csrAddrSel).slice(11, 0);
    }

    // AMO read-modify-write: combine the loaded ("old") value with src per the
    // 4-bit afunct selector (RiscVAtomicFunct.index). All operands are [bits]
    // wide; the result is [bits] wide. Mirrors the static RiscVAtomicMemory arm.
    // cas (Zacas) needs rd's value as the compare operand and is handled by the
    // static path only; plain rvA never emits it, so it falls through to src.
    Logic amoNewVal(Logic afunct, Logic old, Logic src, int bits) {
      Logic sel(int v) =>
          afunct.eq(Const(v, width: AtomicMemoryMicroOp.functWidth));
      return mux(
        sel(0),
        old + src, // add
        mux(
          sel(1),
          src, // swap
          mux(
            sel(2),
            old ^ src, // xor
            mux(
              sel(3),
              old & src, // and
              mux(
                sel(4),
                old | src, // or
                mux(
                  sel(5),
                  mux(bmSignedLt(old, src, bits), old, src), // min
                  mux(
                    sel(6),
                    mux(bmSignedLt(old, src, bits), src, old), // max
                    mux(
                      sel(7),
                      mux(old.lt(src), old, src), // minu
                      mux(
                        sel(8),
                        mux(old.lt(src), src, old), // maxu
                        src, // cas fallthrough (static path only)
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // AMO read-modify-write combine, computed ONCE at XLEN instead of a 9-way
    // amoNewVal per size. `amoSizeMux` selects an XLEN value by atomic size
    // (word/dword); old and src are sign-extended to XLEN. Signed min/max and
    // unsigned minu/maxu stay correct (32->64 sign-extension is monotonic for
    // both orderings); add/xor/and/or/swap only need correct low bits. The mem
    // port writes only `amoBytes` bytes, so high bits are don't-care.
    Logic amoSizeMux(Logic Function(RiscVMemSize) f) {
      final sizes = MicroOpMemSize.values.where(atomicSize).toList();
      var acc = f(sizes.first);
      for (final s in sizes.skip(1)) {
        acc = mux(
          mop['AtomicMemory']!['size']!.eq(
            Const(s.value, width: MicroOpMemSize.width),
          ),
          f(s),
          acc,
        );
      }
      return acc;
    }

    final amoOldX = amoSizeMux(
      (s) => memRead.data.slice(s.bits - 1, 0).signExtend(mxlen.size),
    );
    final amoNewX = amoNewVal(
      mop['AtomicMemory']!['afunct']!,
      amoOldX,
      amoSizeMux(
        (s) => readField(
          mop['AtomicMemory']!['src']!,
        ).slice(s.bits - 1, 0).signExtend(mxlen.size),
      ),
      mxlen.size,
    );
    final amoBytes = amoSizeMux((s) => Const(s.bytes, width: 7));
    // Stored value: the combine's low size.bits, ZERO-extended to XLEN (the
    // combine is sign-extended for correct min/max, but the store wrote zero
    // high bits before this fold, and the mem model keeps those high bytes).
    final amoStoreVal = amoSizeMux(
      (s) => amoNewX.slice(s.bits - 1, 0).zeroExtend(mxlen.size),
    );

    // MemLoad result: the loaded memRead.data extended to XLEN per the access
    // size ([sizeField]) and signedness ([unsignedField]). Computed once as a
    // size-driven data mux so the MemLoad-completion arm does a single
    // writeField instead of replicating the dest demux per byte/half/word/dword.
    Logic loadSizeMux(Logic sizeField, Logic unsignedField) {
      final sizes = MicroOpMemSize.values
          .where((s) => s.bytes <= mxlen.width)
          .toList();
      Logic ext(RiscVMemSize s) => mux(
        unsignedField,
        memRead.data.slice(s.bits - 1, 0).zeroExtend(mxlen.size),
        memRead.data.slice(s.bits - 1, 0).signExtend(mxlen.size),
      );
      var acc = ext(sizes.first);
      for (final s in sizes.skip(1)) {
        acc = mux(
          sizeField.eq(Const(s.value, width: MicroOpMemSize.width)),
          ext(s),
          acc,
        );
      }
      return acc;
    }

    // Shared rd-commit dest selector. LoadReserved, AMO-write and SC-write all
    // finish with the SAME "commit rd (or advance on x0)" datapath, reading a
    // dest field via readField(dest, register: false).slice(4,0). Mutually
    // exclusive by funct, so muxing the 3-bit dest selector by funct shares ONE
    // readField(dest) cone (mux-bound). Every micro-op type is in the mop table
    // (filtered only by CSR presence), so no key guards needed.
    var commitDest = mop['LoadReserved']!['dest']! as Logic;
    commitDest = mux(
      funct.eq(Const(StoreConditionalMicroOp.funct, width: funct.width)),
      mop['StoreConditional']!['dest']!,
      commitDest,
    );
    commitDest = mux(
      funct.eq(Const(AtomicMemoryMicroOp.funct, width: funct.width)),
      mop['AtomicMemory']!['dest']!,
      commitDest,
    );
    // AMO writes the old memory value, SC writes zero (LR uses the loaded value,
    // handled at its own site since the width/extension differs).
    final scAmoVal = mux(
      funct.eq(Const(AtomicMemoryMicroOp.funct, width: funct.width)),
      amoOld,
      Const(0, width: mxlen.size),
    );

    Conditional writeField(Logic field, Logic value) => Case(
      field,
      [
        CaseItem(Const(MicroOpField.rd, width: MicroOpField.width), [
          rd < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.rs1, width: MicroOpField.width), [
          rs1 < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.rs2, width: MicroOpField.width), [
          rs2 < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.imm, width: MicroOpField.width), [
          imm < value.zeroExtend(mxlen.size),
        ]),
        CaseItem(Const(MicroOpField.sp, width: MicroOpField.width), [
          nextSp < value.zeroExtend(mxlen.size),
        ]),
      ],
      defaultItem: [done < 1, valid < 0],
    );

    Conditional clearField(Logic field) =>
        writeField(field, readField(field, register: false));

    // Iterative multiplier for the mul family. The shared [IterativeMultiplier]
    // computes the full 2*XLEN unsigned product over a few cycles (one chunk-
    // multiply reused per cycle) instead of a single-cycle partial-product tree.
    // A mul/mulh* mop holds [_imulStart] while resident (operands stable, mopStep
    // frozen) and reads back the product. mul/mulw/mulh* flavors derive from that
    // registered product: a slice for low/word/high-unsigned, plus the two
    // sign-correction subtracts for signed-high. Mirrors idivArm's handshake.
    final mulA = aluA;
    final mulB = aluB;
    // mul family present whenever the ISA has M. With useIterativeMul the product
    // comes from _imul; otherwise a single-cycle combinational unsigned product.
    // mulw/mulh* flavors derive identically from the 2w-bit product either way.
    final hasMul = microcode.isa.extensions.any((e) => e.name == 'M');
    Logic? mulLowR, mulwR, mulhSSR, mulhSUR, mulhUUR;
    if (hasMul) {
      final w = mxlen.size;
      final z = Const(0, width: w);
      final prod = _imul != null
          ? _imul!
                .product // 2w-bit unsigned product (multi-cycle)
          : (mulA.zeroExtend(w * 2) *
                mulB.zeroExtend(w * 2)); // single-cycle unsigned product
      mulLowR = prod.slice(w - 1, 0);
      mulwR = mulLowR.slice(31, 0).signExtend(w);
      mulhUUR = prod.slice(w * 2 - 1, w);
      // Signed-high corrections: MULHSU treats a as signed, b as unsigned; if a
      // is negative subtract b from the high word. MULH treats both signed; the
      // extra correction for b negative subtracts a.
      mulhSUR = mulhUUR - mux(mulA[w - 1], mulB, z);
      mulhSSR = mulhSUR - mux(mulB[w - 1], mulA, z);
    }

    // One mul-family arm: route to the shared IterativeMultiplier exactly like
    // idivArm routes div/rem. Hold start while resident (operands held stable
    // since mopStep does not advance), and on done commit the selected flavor of
    // the unsigned product and advance. Stub when no M.
    List<Conditional> imulArm(Logic? result) {
      if (!hasMul) {
        // No M extension: unreachable stub (the Case is fully elaborated).
        return [
          alu < Const(0, width: mxlen.size),
          mopStep < mopStep + 1,
          microcodeRead.en < 0,
        ];
      }
      if (_imul == null) {
        // Single-cycle mul: result is combinational, commit and advance now.
        return [alu < result!, mopStep < mopStep + 1, microcodeRead.en < 0];
      }
      return [
        _imulStart! < 1,
        _imulA! < mulA,
        _imulB! < mulB,
        If(
          _imul!.done,
          then: [
            alu < result!,
            _imulStart! < 0,
            mopStep < mopStep + 1,
            microcodeRead.en < 0,
          ],
        ),
      ];
    }

    // Routes a div/rem micro-op to the shared multi-cycle IterativeDivider:
    // hold start while resident, feed unsigned magnitudes (divisor forced
    // non-zero), and on done commit the sign/word/div-by-zero/overflow-fixed
    // result and advance. Reproduces the static unit's semantics. When the ISA
    // has no M extension the divider is absent and these arms are unreachable
    // stubs (still elaborated as part of the full funct Case).
    List<Conditional> idivArm({
      required bool isW,
      required bool isRem,
      required bool isSigned,
    }) {
      if (_idiv == null) {
        return [
          alu < Const(0, width: mxlen.size),
          mopStep < mopStep + 1,
          microcodeRead.en < 0,
        ];
      }
      final w = isW ? 32 : mxlen.size;
      final aOp = isW ? mulA.slice(31, 0) : mulA;
      final bOp = isW ? mulB.slice(31, 0) : mulB;
      final aMag = isSigned ? bmAbs(aOp, w) : aOp;
      final bMag = isSigned ? bmAbs(bOp, w) : bOp;
      final zw = Const(0, width: w);
      final dividend = aMag.zeroExtend(mxlen.size);
      final divisor = mux(
        bMag.eq(zw),
        Const(1, width: w),
        bMag,
      ).zeroExtend(mxlen.size);
      final q = _idiv!.quotient.slice(w - 1, 0);
      final r = _idiv!.remainder.slice(w - 1, 0);
      final resW = isRem
          ? (isSigned ? remFixupS(aOp, bOp, r, w) : remFixupU(aOp, bOp, r, w))
          : (isSigned ? divFixupS(aOp, bOp, q, w) : divFixupU(aOp, bOp, q, w));
      final result = isW ? resW.signExtend(mxlen.size) : resW;
      return [
        _idivStart! < 1,
        _idivDividend! < dividend,
        _idivDivisor! < divisor,
        If(
          _idiv!.done,
          then: [
            alu < result,
            _idivStart! < 0,
            mopStep < mopStep + 1,
            microcodeRead.en < 0,
          ],
        ),
      ];
    }

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
          If(
            rdWrite.done & rdWrite.valid,
            then: [mopStep < mopStep + 1, microcodeRead.en < 0, rdWrite.en < 0],
          ),
        ]),
        Iff(memRead.en, [
          Case(funct, [
            CaseItem(Const(MemLoadMicroOp.funct, width: funct.width), [
              If(
                memRead.done & memRead.valid,
                then: [
                  // Sign/zero-extend the loaded value by size ONCE via a size-
                  // driven data mux, then a SINGLE writeField, instead of a per-
                  // size Case replicating the wide writeField dest-demux for each
                  // of byte/half/word/dword (mux-bound). Result equals the old
                  // per-size value exactly (each arm was the same extend of the
                  // same slice).
                  writeField(
                    mop['MemLoad']!['dest']!,
                    loadSizeMux(
                      mop['MemLoad']!['size']!,
                      mop['MemLoad']!['unsigned']!,
                    ),
                  ),
                  mopStep < mopStep + 1,
                  microcodeRead.en < 0,
                  memRead.en < 0,
                ],
              ),
              If(
                memRead.done & ~memRead.valid,
                then: doTrap(Trap.loadPageFault, opBase + imm),
              ),
            ]),
            // Load-reserved: commit rd = sign-extended loaded value, arm the
            // reservation, then advance (via the rdWrite wrapper, or directly
            // when rd == x0).
            CaseItem(Const(LoadReservedMicroOp.funct, width: funct.width), [
              If(
                memRead.done & memRead.valid,
                then: [
                  reservationValid < 1,
                  reservationAddr < memRead.addr,
                  memRead.en < 0,
                  Case(mop['LoadReserved']!['size']!, [
                    for (final size in MicroOpMemSize.values.where(atomicSize))
                      CaseItem(Const(size.value, width: MicroOpMemSize.width), [
                        If(
                          readField(
                            commitDest,
                            register: false,
                          ).slice(4, 0).gt(0),
                          then: [
                            rdWrite.addr <
                                readField(
                                  commitDest,
                                  register: false,
                                ).slice(4, 0),
                            rdWrite.data <
                                memRead.data
                                    .slice(size.bits - 1, 0)
                                    .signExtend(mxlen.size),
                            rdWrite.en < 1,
                          ],
                          orElse: [mopStep < mopStep + 1, microcodeRead.en < 0],
                        ),
                      ]),
                  ]),
                ],
              ),
              If(
                memRead.done & ~memRead.valid,
                then: [memRead.en < 0, ...doTrap(Trap.loadPageFault, opBase)],
              ),
            ]),
            // AMO read phase: latch the (sign-extended) old value, compute the
            // new value, and issue the write. rd + advance happen in the
            // memWrite-completion wrapper.
            CaseItem(Const(AtomicMemoryMicroOp.funct, width: funct.width), [
              If(
                memRead.done & memRead.valid,
                then: [
                  // Shared combine (amoNewX) + size-driven byte count; no
                  // per-size Case. The mem port writes only amoBytes bytes.
                  amoOld < amoOldX,
                  memWrite.en < 1,
                  memWrite.addr < memRead.addr,
                  memWrite.data < [amoBytes, amoStoreVal].swizzle(),
                  memRead.en < 0,
                ],
              ),
              If(
                memRead.done & ~memRead.valid,
                then: [memRead.en < 0, ...doTrap(Trap.loadPageFault, opBase)],
              ),
            ]),
          ]),
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
                  ...doTrap(Trap.storePageFault, opBase + imm),
                ],
              ),
            ]),
            // AMO write phase: commit rd = old value, then advance (rdWrite
            // wrapper, or directly when rd == x0).
            CaseItem(Const(AtomicMemoryMicroOp.funct, width: funct.width), [
              If(
                memWrite.done & memWrite.valid,
                then: [
                  memWrite.en < 0,
                  If(
                    readField(commitDest, register: false).slice(4, 0).gt(0),
                    then: [
                      rdWrite.addr <
                          readField(commitDest, register: false).slice(4, 0),
                      rdWrite.data < scAmoVal,
                      rdWrite.en < 1,
                    ],
                    orElse: [mopStep < mopStep + 1, microcodeRead.en < 0],
                  ),
                ],
              ),
              If(
                memWrite.done & ~memWrite.valid,
                then: [memWrite.en < 0, ...doTrap(Trap.storePageFault, opBase)],
              ),
            ]),
            // SC hit: the store succeeded -> rd = 0, then advance.
            CaseItem(Const(StoreConditionalMicroOp.funct, width: funct.width), [
              If(
                memWrite.done & memWrite.valid,
                then: [
                  memWrite.en < 0,
                  If(
                    readField(commitDest, register: false).slice(4, 0).gt(0),
                    then: [
                      rdWrite.addr <
                          readField(commitDest, register: false).slice(4, 0),
                      rdWrite.data < scAmoVal,
                      rdWrite.en < 1,
                    ],
                    orElse: [mopStep < mopStep + 1, microcodeRead.en < 0],
                  ),
                ],
              ),
              If(
                memWrite.done & ~memWrite.valid,
                then: [memWrite.en < 0, ...doTrap(Trap.storePageFault, opBase)],
              ),
            ]),
          ]),
        ]),
        if (csrRead != null)
          Iff(csrRead.en, [
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
        if (csrWrite != null)
          Iff(csrWrite.en, [
            If(
              csrWrite.done & csrWrite.valid,
              then: [
                mopStep < mopStep + 1,
                microcodeRead.en < 0,
                csrWrite.en < 0,
              ],
            ),
            // csrrs/csrrc rs1=x0 (csrr*i uimm=0) reading a read-only CSR: the
            // write is illegal (valid=0) but the spec says these forms do not
            // write and must not trap. funct3[1] marks set/clear; instr[19:15]
            // (rs1/uimm field) == 0 is the no-write case. Suppress the trap and
            // complete (rd already has the old value from the read step).
            If(
              csrWrite.done &
                  ~csrWrite.valid &
                  fields['funct3']![1] &
                  fields['rs1']!.eq(Const(0, width: fields['rs1']!.width)),
              then: [
                mopStep < mopStep + 1,
                microcodeRead.en < 0,
                csrWrite.en < 0,
              ],
            ),
            If(
              csrWrite.done &
                  ~csrWrite.valid &
                  ~(fields['funct3']![1] &
                      fields['rs1']!.eq(Const(0, width: fields['rs1']!.width))),
              then: doTrap(Trap.illegal),
            ),
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
                                MicroOpSource.rs2,
                                width: MicroOpSource.width,
                              ),
                            ),
                            then: [
                              rs2Read.en < 1,
                              rs2Read.addr <
                                  (readField(
                                            mop['ReadRegister']!['source']!,
                                            register: false,
                                          ).zeroExtend(mxlen.size) +
                                          mop['ReadRegister']!['offset']!)
                                      .slice(4, 0),
                            ],
                            orElse: [
                              rs1Read.en < 1,
                              rs1Read.addr <
                                  (readField(
                                            mop['ReadRegister']!['source']!,
                                            register: false,
                                          ).zeroExtend(mxlen.size) +
                                          mop['ReadRegister']!['offset']!)
                                      .slice(4, 0),
                            ],
                          ),
                        ]),
                      ]),
                    ],
                  ),
                  CaseItem(Const(WriteRegisterMicroOp.funct, width: funct.width), [
                    If(
                      (readField(
                                mop['WriteRegister']!['field']!,
                                register: false,
                              ).zeroExtend(mxlen.size) +
                              mop['WriteRegister']!['offset']!)
                          .slice(4, 0)
                          .eq(Const(Register.x0.value, width: 5)),
                      then: [mopStep < mopStep + 1, microcodeRead.en < 0],
                      orElse: [
                        // Mirror x2 (sp) writes to the fast-path nextSp, but x2
                        // is a real GPR too: it must ALSO take the normal
                        // regfile write below (whose rdWrite handshake advances
                        // mopStep). Setting nextSp alone left no mopStep advance
                        // and hung the core on any x2 write.
                        If(
                          (readField(
                                    mop['WriteRegister']!['field']!,
                                    register: false,
                                  ).zeroExtend(mxlen.size) +
                                  mop['WriteRegister']!['offset']!)
                              .slice(4, 0)
                              .eq(Const(Register.x2.value, width: 5)),
                          then: [
                            nextSp <
                                (sharedSourceVal +
                                    mop['WriteRegister']!['valueOffset']!),
                          ],
                        ),
                        rdWrite.en < 1,
                        rdWrite.addr <
                            (readField(
                                      mop['WriteRegister']!['field']!,
                                      register: false,
                                    ).zeroExtend(mxlen.size) +
                                    mop['WriteRegister']!['offset']!)
                                .slice(4, 0),
                        rdWrite.data <
                            (sharedSourceVal +
                                mop['WriteRegister']!['valueOffset']!),
                      ],
                    ),
                  ]),
                  CaseItem(Const(AluMicroOp.funct, width: funct.width), [
                    Case(
                      mop['Alu']!['alu']!,
                      [
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mul,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulLowR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mulw,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulwR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mulh,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulhSSR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mulhsu,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulhSUR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.mulhu,
                            width: MicroOpAluFunct.width,
                          ),
                          imulArm(mulhUUR),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.div,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: false, isRem: false, isSigned: true),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.divu,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: false, isRem: false, isSigned: false),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.divuw,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: true, isRem: false, isSigned: false),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.divw,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: true, isRem: false, isSigned: true),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.rem,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: false, isRem: true, isSigned: true),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.remu,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: false, isRem: true, isSigned: false),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.remuw,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: true, isRem: true, isSigned: false),
                        ),
                        CaseItem(
                          Const(
                            MicroOpAluFunct.remw,
                            width: MicroOpAluFunct.width,
                          ),
                          idivArm(isW: true, isRem: true, isSigned: true),
                        ),
                      ],
                      defaultItem: [
                        // All single-cycle ALU functs (add/sub/logic/shift/
                        // compare/word/zicond) route to the shared MicrocodeAlu;
                        // only the multi-cycle mul (_imul) and div/rem
                        // (IterativeDivider) arms above are explicit.
                        alu < microcodeAlu,
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
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
                                  sharedFieldVal!,
                                  mux(
                                    mop['UpdatePC']!['hasSource']!,
                                    sharedSourceVal,
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
                              ((opBase + imm) &
                                      Const(size.bytes - 1, width: mxlen.size))
                                  .neq(0),
                              then: doTrap(Trap.misalignedLoad, opBase + imm),
                              orElse: [
                                memRead.en < 1,
                                memRead.addr < (opBase + imm),
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
                              ((opBase + imm) &
                                      Const(size.bytes - 1, width: mxlen.size))
                                  .neq(0),
                              then: doTrap(Trap.misalignedStore, opBase + imm),
                              orElse: [
                                memWrite.en < 1,
                                memWrite.addr < (opBase + imm),
                                memWrite.data <
                                    [
                                      (Const(1, width: 7) <<
                                          mop['MemStore']!['size']!),
                                      opStoreSrc,
                                    ].swizzle(),
                              ],
                            ),
                          ],
                        ),
                    ]),
                  ]),
                  // Load-reserved: issue the read (the memRead-completion wrapper
                  // writes rd, sets the reservation, and advances).
                  CaseItem(
                    Const(LoadReservedMicroOp.funct, width: funct.width),
                    [
                      Case(mop['LoadReserved']!['size']!, [
                        for (final size in MicroOpMemSize.values.where(
                          atomicSize,
                        ))
                          CaseItem(
                            Const(size.value, width: MicroOpMemSize.width),
                            [
                              If(
                                (opBase &
                                        Const(
                                          size.bytes - 1,
                                          width: mxlen.size,
                                        ))
                                    .neq(0),
                                then: doTrap(Trap.misalignedLoad, opBase),
                                orElse: [memRead.en < 1, memRead.addr < opBase],
                              ),
                            ],
                          ),
                      ]),
                    ],
                  ),
                  // Store-conditional: on a reservation HIT, issue the write (the
                  // memWrite-completion wrapper writes rd=0 and advances); on a
                  // MISS, write rd=1 and complete here. Always clears the
                  // reservation.
                  CaseItem(
                    Const(StoreConditionalMicroOp.funct, width: funct.width),
                    [
                      Case(mop['StoreConditional']!['size']!, [
                        for (final size in MicroOpMemSize.values.where(
                          atomicSize,
                        ))
                          CaseItem(
                            Const(size.value, width: MicroOpMemSize.width),
                            [
                              If(
                                (opBase &
                                        Const(
                                          size.bytes - 1,
                                          width: mxlen.size,
                                        ))
                                    .neq(0),
                                then: doTrap(Trap.misalignedStore, opBase),
                                orElse: [
                                  reservationValid < 0,
                                  If(
                                    reservationValid &
                                        reservationAddr.eq(opBase),
                                    then: [
                                      memWrite.en < 1,
                                      // opBase IS readField(SC base) here (funct
                                      // selects StoreConditional), so reuse the
                                      // shared base read instead of two more.
                                      memWrite.addr < opBase,
                                      memWrite.data <
                                          [
                                            Const(size.bytes, width: 7),
                                            opStoreSrc,
                                          ].swizzle(),
                                    ],
                                    orElse: [
                                      // Miss: rd = 1 (fail), complete now.
                                      If(
                                        readField(
                                          mop['StoreConditional']!['dest']!,
                                          register: false,
                                        ).slice(4, 0).gt(0),
                                        then: [
                                          rdWrite.addr <
                                              readField(
                                                mop['StoreConditional']!['dest']!,
                                                register: false,
                                              ).slice(4, 0),
                                          rdWrite.data <
                                              Const(1, width: mxlen.size),
                                          rdWrite.en < 1,
                                        ],
                                        orElse: [
                                          mopStep < mopStep + 1,
                                          microcodeRead.en < 0,
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                      ]),
                    ],
                  ),
                  // AMO: issue the read; the memRead-completion wrapper latches
                  // the old value, computes the new value and issues the write,
                  // and the memWrite-completion wrapper writes rd and advances.
                  CaseItem(
                    Const(AtomicMemoryMicroOp.funct, width: funct.width),
                    [
                      Case(mop['AtomicMemory']!['size']!, [
                        for (final size in MicroOpMemSize.values.where(
                          atomicSize,
                        ))
                          CaseItem(
                            Const(size.value, width: MicroOpMemSize.width),
                            [
                              If(
                                (opBase &
                                        Const(
                                          size.bytes - 1,
                                          width: mxlen.size,
                                        ))
                                    .neq(0),
                                then: doTrap(Trap.misalignedStore, opBase),
                                orElse: [memRead.en < 1, memRead.addr < opBase],
                              ),
                            ],
                          ),
                      ]),
                    ],
                  ),
                  CaseItem(Const(TrapMicroOp.funct, width: funct.width), [
                    // The micro-op's own modeCause bit drives the switch: when
                    // set (ecall), rawTrap re-encodes the cause by privilege.
                    // No RTL heuristic on the cause value.
                    ...rawTrap(
                      mop['Trap']!['isInterrupt']!,
                      mop['Trap']!['causeCode']!,
                      null,
                      null,
                      mop['Trap']!['modeCause']!,
                    ),
                  ]),
                  CaseItem(Const(BranchIfMicroOp.funct, width: funct.width), [
                    // Compare the latched rs1/rs2 values DIRECTLY (the branch
                    // microcode reads both before this step). Testing the sign of
                    // the rs1-rs2 difference can't express unsigned bltu/bgeu and
                    // is wrong for signed blt/bge on overflow. Mirrors the static
                    // RiscVBranch path + fu_branch.dart.
                    Case(mop['BranchIf']!['condition']!, [
                      for (final cond in [
                        (MicroOpCondition.eq, rs1.eq(rs2)),
                        (MicroOpCondition.ne, rs1.neq(rs2)),
                        (MicroOpCondition.lt, bmSignedLt(rs1, rs2, mxlen.size)),
                        (
                          MicroOpCondition.ge,
                          ~bmSignedLt(rs1, rs2, mxlen.size),
                        ),
                        (MicroOpCondition.ltu, rs1.lt(rs2)),
                        (MicroOpCondition.geu, ~rs1.lt(rs2)),
                      ])
                        CaseItem(
                          Const(cond.$1, width: MicroOpCondition.width),
                          [
                            If(
                              cond.$2,
                              then: [
                                nextPc < (currentPc + imm),
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
                              // rd == x0: a no-link jump (`tail`/`jr`). No write
                              // issues, so the rdWrite.done handshake that
                              // advances mopStep never fires; advance directly
                              // here or the FSM hangs on the jump.
                              orElse: [
                                mopStep < mopStep + 1,
                                microcodeRead.en < 0,
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
                  if (mop.containsKey('ValidateField'))
                    CaseItem(
                      Const(ValidateFieldMicroOp.funct, width: funct.width),
                      [
                        Case(mop['ValidateField']!['condition']!, [
                          CaseItem(
                            Const(
                              MicroOpCondition.eq,
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
                              MicroOpCondition.ne,
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
                              MicroOpCondition.lt,
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
                              MicroOpCondition.gt,
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
                              MicroOpCondition.ge,
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
                              MicroOpCondition.le,
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
                  if (mop.containsKey('ModifyLatch'))
                    CaseItem(
                      Const(ModifyLatchMicroOp.funct, width: funct.width),
                      [
                        If(
                          mop['ModifyLatch']!['replace']!,
                          then: [
                            writeField(
                              mop['ModifyLatch']!['field']!,
                              sharedSourceVal,
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
                  if (mop.containsKey('SetField'))
                    CaseItem(Const(SetFieldMicroOp.funct, width: funct.width), [
                      writeField(
                        mop['SetField']!['field']!,
                        mop['SetField']!['value']!,
                      ),
                      mopStep < mopStep + 1,
                      microcodeRead.en < 0,
                    ]),
                  if (functEmitted(InterruptHoldMicroOp.funct))
                    CaseItem(
                      Const(InterruptHoldMicroOp.funct, width: funct.width),
                      [
                        interruptHold < 1,
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  if (mop.containsKey('CopyField'))
                    CaseItem(
                      Const(CopyFieldMicroOp.funct, width: funct.width),
                      [
                        writeField(mop['CopyField']!['dest']!, sharedFieldVal!),
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  if (mop.containsKey('MoveToField'))
                    CaseItem(
                      Const(SetFieldMicroOpFunct.funct, width: funct.width),
                      [
                        writeField(
                          mop['MoveToField']!['dest']!,
                          sharedSourceVal,
                        ),
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  if (csrRead != null)
                    CaseItem(Const(ReadCsrMicroOp.funct, width: funct.width), [
                      If(
                        currentMode.eq(Const(PrivilegeMode.user.id, width: 3)),
                        then: doTrap(Trap.illegal),
                        orElse: [csrRead.en < 1, csrRead.addr < csrAddr!],
                      ),
                    ]),
                  if (csrWrite != null)
                    CaseItem(Const(WriteCsrMicroOp.funct, width: funct.width), [
                      If(
                        currentMode.eq(Const(PrivilegeMode.user.id, width: 3)),
                        then: doTrap(Trap.illegal),
                        orElse: [
                          csrWrite.en < 1,
                          csrWrite.addr < csrAddr!,
                          csrWrite.data < sharedSourceVal,
                        ],
                      ),
                    ]),
                  if (functEmitted(TlbFenceMicroOp.funct))
                    CaseItem(Const(TlbFenceMicroOp.funct, width: funct.width), [
                      // sfence.vma: pulse fence, which the core routes to the MMU
                      // fetch-TLB flush (it also harmlessly over-flushes the icache).
                      fence < 1,
                      mopStep < mopStep + 1,
                      microcodeRead.en < 0,
                    ]),
                  if (functEmitted(TlbInvalidateMicroOp.funct))
                    CaseItem(
                      Const(TlbInvalidateMicroOp.funct, width: funct.width),
                      [
                        // TODO: once MMU has a TLB
                        mopStep < mopStep + 1,
                        microcodeRead.en < 0,
                      ],
                    ),
                  // MRET/SRET. Terminal single-step: signal the return and target
                  // privilege; core.dart restores PC<-{m,s}epc, mode<-{m,s}status.xPP
                  // and pops the status stack. privilegeLevel from the micro-op
                  // (3=M, 1=S). Mirrors the static RiscVReturnOp path. Missing here
                  // once, so mret looped forever (the creek trap-return hang).
                  CaseItem(Const(ReturnMicroOp.funct, width: funct.width), [
                    output('isReturn') < 1,
                    output('returnLevel') <
                        mop['Return']!['privilegeLevel']!.zeroExtend(
                          output('returnLevel').width,
                        ),
                    done < 1,
                    valid < 1,
                  ]),
                  // wfi: treat the wait as a NOP hint and advance to the next
                  // micro-op (its microcode's UpdatePc retires at pc+4). Without
                  // this arm wfi hit the default case and stalled the core.
                  CaseItem(
                    Const(WaitForInterruptMicroOp.funct, width: funct.width),
                    [mopStep < mopStep + 1, microcodeRead.en < 0],
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
  /// One [BmMulSet] per distinct operand FIELD pair: every mul-family
  /// micro-op shares a single multiplier array instead of elaborating its
  /// own (the static per-arm switch otherwise builds one per opcode). Keyed
  /// by the field enums because readField mints a fresh wire per call; the
  /// underlying field latches are the same signals across micro-ops.
  final _mulSets = <Object, BmMulSet>{};

  BmMulSet _mulSetFor(Object key, Logic a, Logic b, int w) =>
      _mulSets.putIfAbsent(key, () => BmMulSet(a, b, w));

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
    super.vlen = 128,
    super.mideleg,
    super.medeleg,
    super.mtvec,
    super.stvec,
    super.interruptTake,
    super.interruptCause,
    super.virtIn,
    super.mstateen0Se0,
    super.hstateen0Se0,
    super.memFaultGuest,
    super.fetchFault,
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

    Logic readSource(RiscVMicroOpSource source) {
      switch (source) {
        case RiscVMicroOpSource.imm:
          return imm;
        case RiscVMicroOpSource.alu:
          return alu;
        case RiscVMicroOpSource.rs1:
          return rs1;
        case RiscVMicroOpSource.rs2:
          return rs2;
        case RiscVMicroOpSource.rd:
          return rd;
        case RiscVMicroOpSource.pc:
          return nextPc;
      }
    }

    Logic readField(RiscVMicroOpField field, {bool register = true}) {
      switch (field) {
        case RiscVMicroOpField.rd:
          return (register ? rd : fields['rd']!).zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs1:
          return (register ? rs1 : fields['rs1']!).zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs2:
          return (register ? rs2 : fields['rs2']!).zeroExtend(mxlen.size);
        case RiscVMicroOpField.imm:
          return register ? imm : fields['imm']!;
        case RiscVMicroOpField.pc:
          return nextPc;
        case RiscVMicroOpField.rs3:
          return (register ? _rs3Latch! : fields['rs3']!).zeroExtend(
            mxlen.size,
          );
      }
    }

    Conditional writeField(RiscVMicroOpField field, Logic value) {
      switch (field) {
        case RiscVMicroOpField.rd:
          return rd < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs1:
          return rs1 < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs2:
          return rs2 < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.imm:
          return imm < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.pc:
          return nextPc < value.zeroExtend(mxlen.size);
        case RiscVMicroOpField.rs3:
          return _rs3Latch! < value.zeroExtend(mxlen.size);
      }
    }

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

              // Which micro-op fields name FP registers for this op (from its
              // RfResource declarations). ReadRegister/WriteRegister of these
              // fields route to the FP register file rather than the integer one.
              final fpFields = <RiscVMicroOpField>{};
              for (final r in op.resources) {
                if (r is RfResource && r.regfile is RiscVFloatRegFile) {
                  final a = r.access;
                  if (a is RfRead) {
                    if (a.name == 'RS1') fpFields.add(RiscVMicroOpField.rs1);
                    if (a.name == 'RS2') fpFields.add(RiscVMicroOpField.rs2);
                    if (a.name == 'RS3') fpFields.add(RiscVMicroOpField.rs3);
                  } else if (a is RfWrite && a.name == 'RD') {
                    fpFields.add(RiscVMicroOpField.rd);
                  }
                }
              }

              // Vector vsetvli: vl = min(AVL, VLMAX), VLMAX = vlen*LMUL/SEW.
              // Special-cased (its only microcode is RiscVUpdatePc): read AVL
              // from rs1, compute vl from the vtypei immediate (zimm_rs2 =
              // bits[30:20]: vsew[5:3], vlmul[2:0]), write rd=vl, advance PC.
              // VLMAX = base<<vlmul for integer LMUL (vlmul 0-3) and base>>(8-vlmul)
              // for fractional LMUL (vlmul 5/6/7 = mf8/mf4/mf2), base = vlen>>(3+vsew).
              // rs1==x0 is special: with rd!=x0 it sets vl=VLMAX; with rd==x0 it
              // keeps the current vl (vtype still updates). The micro-op loop
              // below is skipped for vsetvli.
              final isVsetvli = op.mnemonic == 'vsetvli';
              final isVle = op.mnemonic == 'vle32.v';
              final isVse = op.mnemonic == 'vse32.v';
              // OPIVV/OPIVX/OPIVI integer arithmetic. The decoder collides all
              // ops within a funct3 group, so these mnemonics are the collided
              // entries (.vv/.vx/.vi); the actual op is the runtime funct6, and
              // the second operand is a vreg (.vv) / scalar broadcast (.vx) /
              // immediate broadcast (.vi).
              final isVArithVV = op.mnemonic == 'vadd.vv';
              final isVArithVX = op.mnemonic == 'vadd.vx';
              final isVArithVI = op.mnemonic == 'vadd.vi';
              final isVArith = isVArithVV || isVArithVX || isVArithVI;
              // OPFVV FP arithmetic collides like the integer ops; vfadd/vfmul
              // are distinguished by the runtime funct6 (add=0x00, mul=0x24).
              final isVFloat = op.mnemonic == 'vfadd.vv';
              final isVecHandled =
                  isVsetvli || isVle || isVse || isVArith || isVFloat;
              if (isVsetvli) {
                final vtypei = fields['zimm_rs2']!;
                final vsew = vtypei.slice(5, 3);
                final vlmul = vtypei.slice(2, 0);
                final avlIdx = fields['rs1_uimm']!.slice(4, 0);
                final rdIdx = fields['rd']!.slice(4, 0);
                final shiftAmt = Const(3, width: 6) + vsew.zeroExtend(6);
                final base = Const(vlen, width: mxlen.size) >> shiftAmt;
                // Integer LMUL (vlmul 0-3): base<<vlmul. Fractional LMUL
                // (vlmul[2] set: 5/6/7 = mf8/mf4/mf2): base>>(8-vlmul).
                final vlmaxInt = base << vlmul.zeroExtend(mxlen.size);
                final vlmaxFrac =
                    base >> (Const(8, width: 6) - vlmul.zeroExtend(6));
                final vlmax = mux(vlmul[2], vlmaxFrac, vlmaxInt);
                final rs1IsX0 = avlIdx.eq(Const(0, width: 5));
                final rdIsX0 = rdIdx.eq(Const(0, width: 5));
                final minAvl = mux(rs1Read.data.lt(vlmax), rs1Read.data, vlmax);
                // rs1!=x0: min(x[rs1], VLMAX). rs1=x0: VLMAX, or keep vl if rd=x0.
                final vl = mux(rs1IsX0, mux(rdIsX0, _vl!, vlmax), minAvl);
                steps.add(
                  CaseItem(Const(1, width: maxLen.bitLength), [
                    rs1Read.addr < avlIdx,
                    rs1Read.en < 1,
                    mopStep < mopStep + 1,
                  ]),
                );
                steps.add(
                  CaseItem(Const(2, width: maxLen.bitLength), [
                    If(
                      rs1Read.done & rs1Read.valid,
                      then: [
                        rdWrite.addr < rdIdx,
                        rdWrite.data < vl,
                        rdWrite.en < rdIdx.neq(Const(0, width: 5)),
                        // Commit vector config state for subsequent ops.
                        _vtype! < vtypei,
                        _vl! < vl,
                        // nextPc holds into the auto-done step (steps.length+1).
                        nextPc < (currentPc + Const(4, width: mxlen.size)),
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
              } else if (isVle) {
                // vle32.v vd, (rs1): unit-stride load of the full VLEN-wide vreg
                // from x[rs1], as VLEN/mxlen mxlen-wide chunks. For VLEN=128 /
                // rv64 that's 2 chunks: base is captured in `alu`, chunk 0 in
                // `rs1`, and the final step assembles vd = {chunk1, chunk0}.
                // (vl<VLMAX tail handling is the separate vl/tail polish.)
                final chunkBytes = mxlen.size ~/ 8;
                final regStride = vlen ~/ 8; // bytes per vreg
                final baseIdx = fields['rs1']!.slice(4, 0);
                final vdIdx = fields['vd_vs3']!.slice(4, 0);
                // LMUL grouping: a unit-stride load fills L=1<<vlmul consecutive
                // vregs from contiguous memory. `_vregIdx` (k) walks the group;
                // register k lives at base + k*regStride and writes vd+k. (vl<VLMAX
                // tail handling is still the separate vl/tail polish; the whole
                // group is loaded.)
                final lmaxL = mux(
                  _vtype!.slice(2, 0).gte(Const(4, width: 3)),
                  Const(1, width: 5),
                  (Const(1, width: 5) << _vtype!.slice(2, 0).zeroExtend(5)),
                );
                final kL = _vregIdx!;
                final kOffL =
                    (kL.zeroExtend(mxlen.size) *
                            Const(regStride, width: mxlen.size))
                        .slice(mxlen.size - 1, 0);
                final regBaseL = alu + kOffL; // memory base for register k
                final vdRegL = (vdIdx.zeroExtend(6) + kL.zeroExtend(6)).slice(
                  4,
                  0,
                );
                steps.add(
                  CaseItem(Const(1, width: maxLen.bitLength), [
                    rs1Read.addr < baseIdx,
                    rs1Read.en < 1,
                    mopStep < mopStep + 1,
                  ]),
                );
                steps.add(
                  CaseItem(Const(2, width: maxLen.bitLength), [
                    If(
                      rs1Read.done & rs1Read.valid,
                      then: [
                        alu < rs1Read.data, // base (held across the group)
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
                // Step 3 (per-register loop target): issue chunk 0 for reg k.
                steps.add(
                  CaseItem(Const(3, width: maxLen.bitLength), [
                    memRead.addr < regBaseL,
                    memRead.en < 1,
                    mopStep < mopStep + 1,
                  ]),
                );
                steps.add(
                  CaseItem(Const(4, width: maxLen.bitLength), [
                    If(
                      memRead.done & memRead.valid,
                      then: [
                        rs1 < memRead.data, // chunk 0
                        memRead.addr <
                            (regBaseL + Const(chunkBytes, width: mxlen.size)),
                        memRead.en < 1, // chunk 1
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
                steps.add(
                  CaseItem(Const(5, width: maxLen.bitLength), [
                    If(
                      memRead.done & memRead.valid,
                      then: [
                        vrdWrite!.addr < vdRegL,
                        // {chunk1 (high), chunk0 (low)} = full vreg.
                        vrdWrite!.data <
                            [
                              memRead.data,
                              rs1.slice(mxlen.size - 1, 0),
                            ].swizzle(),
                        vrdWrite!.en < 1,
                        // Deassert the read enable so the next register's chunk-0
                        // issue (step 3) is a clean rising edge: the memory only
                        // latches a fresh request on en 0->1. Holding en high and
                        // only changing the address streams stale data (the k>0
                        // load otherwise consumed the previous register's chunk).
                        memRead.en < 0,
                        If(
                          (kL.zeroExtend(5) + Const(1, width: 5)).lt(lmaxL),
                          then: [
                            // Loop to step 1 (re-read base): re-reading the GPR
                            // base is idempotent and lets _vregIdx settle before
                            // the address recomputes.
                            _vregIdx! < (kL + Const(1, width: 4)),
                            mopStep < Const(1, width: maxLen.bitLength),
                          ],
                          orElse: [
                            _vregIdx! < Const(0, width: 4),
                            nextPc < (currentPc + Const(4, width: mxlen.size)),
                            mopStep < mopStep + 1,
                          ],
                        ),
                      ],
                    ),
                  ]),
                );
              } else if (isVse) {
                // vse32.v vs3, (rs1): store the full VLEN-wide vreg to x[rs1] as
                // VLEN/mxlen sized dword chunks (2 for VLEN=128/rv64). Base in
                // `alu`; vs3 held in vrs1Read across the chunk writes.
                final chunkBytes = mxlen.size ~/ 8;
                final regStride = vlen ~/ 8; // bytes per vreg
                final baseIdx = fields['rs1']!.slice(4, 0);
                final vs3Idx = fields['vd_vs3']!.slice(4, 0);
                // sized-store data {size=8 (dword), value} for a vreg slice.
                Logic stData(Logic v) => [Const(8, width: 7), v].swizzle();
                // LMUL grouping: store L=1<<vlmul consecutive vregs to contiguous
                // memory. `_vregIdx` (k) walks the group; register vs3+k stores to
                // base + k*regStride. The vreg read is re-issued per register (it
                // has 1-cycle latency, so step 3 reads, step 4 consumes).
                final lmaxS = mux(
                  _vtype!.slice(2, 0).gte(Const(4, width: 3)),
                  Const(1, width: 5),
                  (Const(1, width: 5) << _vtype!.slice(2, 0).zeroExtend(5)),
                );
                final kS = _vregIdx!;
                final kOffS =
                    (kS.zeroExtend(mxlen.size) *
                            Const(regStride, width: mxlen.size))
                        .slice(mxlen.size - 1, 0);
                final regBaseS = alu + kOffS;
                final vs3RegS = (vs3Idx.zeroExtend(6) + kS.zeroExtend(6)).slice(
                  4,
                  0,
                );
                steps.add(
                  CaseItem(Const(1, width: maxLen.bitLength), [
                    rs1Read.addr < baseIdx,
                    rs1Read.en < 1,
                    mopStep < mopStep + 1,
                  ]),
                );
                steps.add(
                  CaseItem(Const(2, width: maxLen.bitLength), [
                    If(
                      rs1Read.done & rs1Read.valid,
                      then: [
                        alu < rs1Read.data, // base (held across the group)
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
                // Step 3 (per-register loop target): read vreg vs3+k.
                steps.add(
                  CaseItem(Const(3, width: maxLen.bitLength), [
                    vrs1Read!.addr < vs3RegS,
                    vrs1Read!.en < 1,
                    mopStep < mopStep + 1,
                  ]),
                );
                steps.add(
                  CaseItem(Const(4, width: maxLen.bitLength), [
                    If(
                      vrs1Read!.done & vrs1Read!.valid,
                      then: [
                        memWrite.addr < regBaseS, // chunk 0 @ regBase
                        memWrite.data < stData(vrs1Read!.data.slice(63, 0)),
                        memWrite.en < 1,
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
                steps.add(
                  CaseItem(Const(5, width: maxLen.bitLength), [
                    If(
                      memWrite.done & memWrite.valid,
                      then: [
                        // chunk 1 @ regBase + chunkBytes (vreg[127:64]).
                        memWrite.addr <
                            (regBaseS + Const(chunkBytes, width: mxlen.size)),
                        memWrite.data < stData(vrs1Read!.data.slice(127, 64)),
                        memWrite.en < 1,
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
                steps.add(
                  CaseItem(Const(6, width: maxLen.bitLength), [
                    If(
                      memWrite.done & memWrite.valid,
                      then: [
                        memWrite.en < 0,
                        If(
                          (kS.zeroExtend(5) + Const(1, width: 5)).lt(lmaxS),
                          then: [
                            // Loop to step 1 (re-read base): lets _vregIdx settle
                            // before recompute.
                            _vregIdx! < (kS + Const(1, width: 4)),
                            mopStep < Const(1, width: maxLen.bitLength),
                          ],
                          orElse: [
                            _vregIdx! < Const(0, width: 4),
                            nextPc < (currentPc + Const(4, width: mxlen.size)),
                            mopStep < mopStep + 1,
                          ],
                        ),
                      ],
                    ),
                  ]),
                );
              } else if (isVArith) {
                // Integer arithmetic vd = (vs2) OP (vs1 | x[rs1] | imm5),
                // SEW-generic: the lane width is taken from the live vtype.vsew
                // (8<<vsew), with carry/borrow isolated at lane boundaries for
                // add/sub and and/or/xor done full-width. LMUL grouping below.
                // The vs1 field [19:15] is vs1 (.vv) / rs1 (.vx) / imm5 (.vi).
                final src1Idx = fields['vs1']!.slice(4, 0);
                final vs2Idx = fields['vs2']!.slice(4, 0);
                final vdIdx = fields['vd']!.slice(4, 0);
                // SEW-generic segmented op: build per-lane results for a given
                // lane width (carries isolated at lane boundaries).
                final vsew = _vtype!.slice(5, 3); // SEW = 8 << vsew
                // LMUL grouping: the op spans L = 1<<vlmul consecutive vregs
                // (integer LMUL m1/m2/m4/m8; fractional LMUL uses 1 reg). `_vregIdx`
                // (k, 0..L-1) walks the group; per-register operand/dest addresses
                // are (baseField + k) wrapped to 5 bits. The 3-step read-compute-
                // write FSM loops once per register.
                final vlmulF = _vtype!.slice(2, 0);
                final lmax = mux(
                  vlmulF.gte(Const(4, width: 3)),
                  Const(1, width: 5),
                  (Const(1, width: 5) << vlmulF.zeroExtend(5)),
                );
                final k = _vregIdx!; // 4-bit register index within the group
                Logic regAddr(Logic base) =>
                    (base.zeroExtend(6) + k.zeroExtend(6)).slice(4, 0);
                final vs2Reg = regAddr(vs2Idx);
                final vs1Reg = regAddr(src1Idx);
                final vdReg = regAddr(vdIdx);
                // Elements per register at the live SEW (= VLEN / SEW).
                final epr =
                    (Const(vlen, width: 16) >>
                            (Const(3, width: 4) + vsew.zeroExtend(4)))
                        .zeroExtend(_vl!.width);
                Logic seg(
                  int laneW,
                  Logic a,
                  Logic b,
                  Logic Function(Logic, Logic) f,
                ) {
                  final lanes = <Logic>[];
                  for (var lo = 0; lo + laneW <= vlen; lo += laneW) {
                    lanes.add(
                      f(
                        a.slice(lo + laneW - 1, lo),
                        b.slice(lo + laneW - 1, lo),
                      ),
                    );
                  }
                  return lanes.reversed.toList().swizzle();
                }

                // Select lane width from the live vsew (default 32).
                Logic segSew(
                  Logic a,
                  Logic b,
                  Logic Function(Logic, Logic) f,
                ) => mux(
                  vsew.eq(Const(0, width: 3)),
                  seg(8, a, b, f),
                  mux(
                    vsew.eq(Const(1, width: 3)),
                    seg(16, a, b, f),
                    mux(
                      vsew.eq(Const(3, width: 3)),
                      seg(64, a, b, f),
                      seg(32, a, b, f),
                    ),
                  ),
                );

                // Op from the runtime funct6 (the collided mnemonic is always
                // 'vadd.*'). a = vs2, b = the second operand. funct6: add=0x00,
                // sub=0x02, and=0x09, or=0x0A, xor=0x0B. and/or/xor are
                // SEW-independent (full-width bitwise).
                final f6 = fields['funct6']!;
                Logic f6eq(int v) => f6.eq(Const(v, width: f6.width));
                // Per-lane shift amount = low log2(SEW) bits of b (SEW = x.width).
                Logic sll(Logic x, Logic y) =>
                    x << y.slice(x.width.bitLength - 2, 0);
                Logic srl(Logic x, Logic y) =>
                    x >>> y.slice(x.width.bitLength - 2, 0);
                Logic arith(Logic a, Logic b) => mux(
                  f6eq(0x02),
                  segSew(a, b, (x, y) => x - y), // vsub
                  mux(
                    f6eq(0x09),
                    a & b, // vand (SEW-independent)
                    mux(
                      f6eq(0x0A),
                      a | b, // vor
                      mux(
                        f6eq(0x0B),
                        a ^ b, // vxor
                        mux(
                          f6eq(0x04),
                          segSew(a, b, (x, y) => mux(x.lt(y), x, y)), // vminu
                          mux(
                            f6eq(0x05),
                            segSew(
                              a,
                              b,
                              (x, y) => mux(bmSignedLt(x, y, x.width), x, y),
                            ),
                            mux(
                              f6eq(0x06),
                              segSew(
                                a,
                                b,
                                (x, y) => mux(x.lt(y), y, x),
                              ), // vmaxu
                              mux(
                                f6eq(0x07),
                                segSew(
                                  a,
                                  b,
                                  (x, y) =>
                                      mux(bmSignedLt(x, y, x.width), y, x),
                                ),
                                mux(
                                  f6eq(0x25),
                                  segSew(a, b, sll), // vsll
                                  mux(
                                    f6eq(0x28),
                                    segSew(a, b, srl), // vsrl
                                    segSew(
                                      a,
                                      b,
                                      (x, y) => x + y,
                                    ), // 0x00 = vadd
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );

                // Broadcast a 32-bit scalar to every SEW=32 lane.
                Logic bcast(Logic s32) =>
                    List.filled(vlen ~/ 32, s32).swizzle();
                // .vi immediate: imm5 in the vs1 field, sign-extended to 32.
                final immB = bcast(fields['vs1']!.slice(4, 0).signExtend(32));

                steps.add(
                  CaseItem(Const(1, width: maxLen.bitLength), [
                    vrs2Read!.addr < vs2Reg,
                    vrs2Read!.en < 1,
                    if (isVArithVV) ...[
                      vrs1Read!.addr < vs1Reg,
                      vrs1Read!.en < 1,
                    ],
                    if (isVArithVX) ...[rs1Read.addr < src1Idx, rs1Read.en < 1],
                    mopStep < mopStep + 1,
                  ]),
                );
                final src1Ready = isVArithVV
                    ? (vrs1Read!.done & vrs1Read!.valid)
                    : isVArithVX
                    ? (rs1Read.done & rs1Read.valid)
                    : Const(1); // .vi: immediate, no read
                final b = isVArithVV
                    ? vrs1Read!.data
                    : isVArithVX
                    ? bcast(rs1Read.data.slice(31, 0))
                    : immB;
                // Step 2: capture the full-width result. Step 3 reads the old vd
                // and merges: active lanes (low vl*SEW bits) take the result,
                // tail bits stay undisturbed (matches the emulator).
                steps.add(
                  CaseItem(Const(2, width: maxLen.bitLength), [
                    If(
                      vrs2Read!.done & vrs2Read!.valid & src1Ready,
                      then: [
                        _vtmp! < arith(vrs2Read!.data, b),
                        // Re-point a read port to old vd; its data (the vreg
                        // read has 1-cycle latency) is consumed at step 3.
                        vrs2Read!.addr < vdReg,
                        vrs2Read!.en < 1,
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
                // Per-register vl/tail mask for register k: the active elements
                // are the global indices [k*EPR, (k+1)*EPR) that are below vl, so
                // localVl = clamp(vl - k*EPR, 0, EPR), and the mask is the low
                // (localVl * SEW) bits. Register k beyond vl gets localVl=0 (mask
                // 0 -> vd undisturbed); a fully-active register gets the full mask.
                final kEpr = (k.zeroExtend(_vl!.width) * epr).slice(
                  _vl!.width - 1,
                  0,
                );
                final remVl = mux(
                  _vl!.gt(kEpr),
                  _vl! - kEpr,
                  Const(0, width: _vl!.width),
                );
                final localVl = mux(remVl.gt(epr), epr, remVl);
                final shiftAmt =
                    localVl << (Const(3, width: 4) + vsew.zeroExtend(4));
                final ones = Const(1, width: vlen + 1);
                final mask = ((ones << shiftAmt) - ones).slice(vlen - 1, 0);
                steps.add(
                  CaseItem(Const(3, width: maxLen.bitLength), [
                    // vrs2Read.data is now old vd (addr set at step 2). Merge:
                    // active lanes = result, tail = undisturbed.
                    vrdWrite!.addr < vdReg,
                    vrdWrite!.data <
                        ((_vtmp! & mask) | (vrs2Read!.data & ~mask)),
                    vrdWrite!.en < 1,
                    If(
                      (k.zeroExtend(5) + Const(1, width: 5)).lt(lmax),
                      then: [
                        // More registers in the group: advance k and restart the
                        // 3-step FSM at step 1 (mopStep holds the PC unchanged).
                        _vregIdx! < (k + Const(1, width: 4)),
                        mopStep < Const(1, width: maxLen.bitLength),
                      ],
                      orElse: [
                        _vregIdx! < Const(0, width: 4),
                        nextPc < (currentPc + Const(4, width: mxlen.size)),
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
              } else if (isVFloat) {
                // OPFVV vfadd.vv / vfmul.vv: per-lane FP add or multiply via
                // ROHD-HCL units, selected by funct6 (add=0x00, mul=0x24). The
                // lane width is SEW-generic from the live vtype.vsew: SEW=32
                // (FP32) and SEW=64 (FP64) always, plus SEW=16 (FP16) when Zvfh
                // is configured (see fpLanes below).
                final vs1Idx = fields['vs1']!.slice(4, 0);
                final vs2Idx = fields['vs2']!.slice(4, 0);
                final vdIdx = fields['vd']!.slice(4, 0);
                final f6 = fields['funct6']!;
                // LMUL grouping (mirrors the integer path): the op spans
                // L=1<<vlmul consecutive vregs; `_vregIdx` (k) walks the group
                // and per-register addresses are (baseField + k)[4:0].
                final vlmulF = _vtype!.slice(2, 0);
                final lmax = mux(
                  vlmulF.gte(Const(4, width: 3)),
                  Const(1, width: 5),
                  (Const(1, width: 5) << vlmulF.zeroExtend(5)),
                );
                final k = _vregIdx!;
                Logic regAddr(Logic base) =>
                    (base.zeroExtend(6) + k.zeroExtend(6)).slice(4, 0);
                final vs2Reg = regAddr(vs2Idx);
                final vs1Reg = regAddr(vs1Idx);
                final vdReg = regAddr(vdIdx);
                // Elements per register at the live SEW (= VLEN / SEW).
                final epr =
                    (Const(vlen, width: 16) >>
                            (Const(3, width: 4) +
                                _vtype!.slice(5, 3).zeroExtend(4)))
                        .zeroExtend(_vl!.width);
                // Per-lane FP add/mul for a given lane width (16, 32 or 64). All
                // widths are built and muxed on vsew (16->vsew==1, 32->2, 64->3),
                // since ROHD elaborates statically. FloatingPointAdder/Multiplier
                // are width-generic over FloatingPoint16/32/64 (Zvfh = SEW=16).
                Logic fpLanesW(Logic a, Logic b, bool mul, int laneW) {
                  final lanes = <Logic>[];
                  for (var lo = 0; lo + laneW <= vlen; lo += laneW) {
                    FloatingPoint mk() => switch (laneW) {
                      16 => FloatingPoint16(),
                      64 => FloatingPoint64(),
                      _ => FloatingPoint32(),
                    };
                    final fa = mk();
                    fa <= a.slice(lo + laneW - 1, lo);
                    final fb = mk();
                    fb <= b.slice(lo + laneW - 1, lo);
                    final r = mul
                        ? FloatingPointMultiplierSimple(fa, fb).product
                        : FloatingPointAdderSinglePath(fa, fb).sum;
                    lanes.add([r.sign, r.exponent, r.mantissa].swizzle());
                  }
                  return lanes.reversed.toList().swizzle();
                }

                final vsewF = _vtype!.slice(5, 3);
                Logic fpLanes(Logic a, Logic b, bool mul) {
                  // SEW=32 (single) / SEW=64 (double) are always built.
                  final base = mux(
                    vsewF.eq(Const(3, width: 3)), // SEW=64 (double)
                    fpLanesW(a, b, mul, 64),
                    fpLanesW(a, b, mul, 32), // default SEW=32 (single)
                  );
                  // SEW=16 (half) lanes only when Zvfh is configured: this is a
                  // Dart-level gate, so a non-Zvfh core never elaborates the FP16
                  // units. Without Zvfh a SEW=16 vfadd falls through to `base`
                  // (the SEW=32 datapath), which the spec never reaches anyway.
                  if (!hasZvfh) return base;
                  return mux(
                    vsewF.eq(
                      Const(1, width: 3),
                    ), // SEW=16 (Zvfh half-precision)
                    fpLanesW(a, b, mul, 16),
                    base,
                  );
                }

                steps.add(
                  CaseItem(Const(1, width: maxLen.bitLength), [
                    vrs1Read!.addr < vs1Reg,
                    vrs1Read!.en < 1,
                    vrs2Read!.addr < vs2Reg,
                    vrs2Read!.en < 1,
                    mopStep < mopStep + 1,
                  ]),
                );
                final fadd = fpLanes(vrs2Read!.data, vrs1Read!.data, false);
                final fmul = fpLanes(vrs2Read!.data, vrs1Read!.data, true);
                // Same vl/tail read-modify-write as the integer path: capture
                // the FP result, re-read old vd, merge active vs tail.
                steps.add(
                  CaseItem(Const(2, width: maxLen.bitLength), [
                    If(
                      vrs1Read!.done &
                          vrs1Read!.valid &
                          vrs2Read!.done &
                          vrs2Read!.valid,
                      then: [
                        _vtmp! <
                            mux(
                              f6.eq(Const(0x24, width: f6.width)),
                              fmul,
                              fadd,
                            ),
                        vrs2Read!.addr < vdReg, // old vd (1-cycle latency)
                        vrs2Read!.en < 1,
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
                final fpVsew = _vtype!.slice(5, 3);
                // Per-register tail mask: localVl = clamp(vl - k*EPR, 0, EPR).
                final fpKEpr = (k.zeroExtend(_vl!.width) * epr).slice(
                  _vl!.width - 1,
                  0,
                );
                final fpRemVl = mux(
                  _vl!.gt(fpKEpr),
                  _vl! - fpKEpr,
                  Const(0, width: _vl!.width),
                );
                final fpLocalVl = mux(fpRemVl.gt(epr), epr, fpRemVl);
                final fpShift =
                    fpLocalVl << (Const(3, width: 4) + fpVsew.zeroExtend(4));
                final fpOnes = Const(1, width: vlen + 1);
                final fpMask = ((fpOnes << fpShift) - fpOnes).slice(
                  vlen - 1,
                  0,
                );
                steps.add(
                  CaseItem(Const(3, width: maxLen.bitLength), [
                    vrdWrite!.addr < vdReg,
                    vrdWrite!.data <
                        ((_vtmp! & fpMask) | (vrs2Read!.data & ~fpMask)),
                    vrdWrite!.en < 1,
                    If(
                      (k.zeroExtend(5) + Const(1, width: 5)).lt(lmax),
                      then: [
                        _vregIdx! < (k + Const(1, width: 4)),
                        mopStep < Const(1, width: maxLen.bitLength),
                      ],
                      orElse: [
                        _vregIdx! < Const(0, width: 4),
                        nextPc < (currentPc + Const(4, width: mxlen.size)),
                        mopStep < mopStep + 1,
                      ],
                    ),
                  ]),
                );
              }

              for (final mop
                  in (isVecHandled
                      ? <RiscVMicroOp>[]
                      : op.indexedMicrocode.values)) {
                final i = steps.length + 1;

                if (mop is RiscVReadRegister) {
                  final isFp = fpFields.contains(mop.source);
                  final addr =
                      (readField(mop.source, register: false) +
                              Const(mop.offset, width: mxlen.size))
                          .slice(4, 0);
                  final port = isFp
                      ? (mop.source == RiscVMicroOpField.rs2
                            ? fprs2Read!
                            : fprs1Read!)
                      : (mop.source == RiscVMicroOpField.rs2
                            ? rs2Read
                            : rs1Read);
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      // x2/sp shortcut only applies to the integer register
                      // file; FP reads always go through the port.
                      if (isFp) ...[
                        port.addr < addr,
                        port.en < 1,
                        mopStep < mopStep + 1,
                      ] else
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

                  // FP read port is FLEN(64)-wide; take the low mxlen bits for
                  // the mxlen-wide intermediate (no-op on rv64; rv32 F's f32 is
                  // in the low 32). #71.
                  final readData = isFp
                      ? port.data.getRange(0, mxlen.size)
                      : port.data;
                  steps.add(
                    CaseItem(Const(i + 1, width: maxLen.bitLength), [
                      writeField(
                        mop.source,
                        readData + Const(mop.offset, width: mxlen.size),
                      ),
                      If(port.done & port.valid, then: [mopStep < mopStep + 1]),
                    ]),
                  );
                } else if (mop is RiscVWriteRegister) {
                  final isFp = fpFields.contains(mop.dest);
                  final addr =
                      (readField(mop.dest, register: false) +
                              Const(mop.valueOffset, width: mxlen.size))
                          .slice(4, 0);

                  final value =
                      (readSource(mop.source) +
                      Const(mop.valueOffset, width: mxlen.size));

                  final wport = isFp ? fprdWrite! : rdWrite;
                  // The FP regfile is FLEN(64)-wide but values flow through the
                  // mxlen-wide intermediate; resize to the write port's width at
                  // the boundary (no-op on rv64 where mxlen==64). #71.
                  final wData = isFp ? value.zeroExtend(64) : value;
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      // Mirror sp into nextSp only for integer x2 writes.
                      if (!isFp)
                        If(
                          addr.eq(Const(Register.x2.value, width: 5)),
                          then: [nextSp < value],
                        ),
                      wport.addr < addr,
                      wport.data < wData,
                      // FP f0 is a real register (not hardwired zero), so FP
                      // writes always enable; integer x0 writes are dropped.
                      wport.en < (isFp ? Const(1) : addr.gt(0)),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is RiscVAlu &&
                    _kIterativeDivRem.contains(mop.funct)) {
                  // Multi-cycle integer divide/remainder. Hold the shared
                  // IterativeDivider's start high while this mop is resident,
                  // feeding it unsigned magnitudes, and commit the sign/edge-
                  // fixed result when it reports done. This is what removes the
                  // eight combinational div/rem trees (the static unit's biggest
                  // LUT cost). div and rem share the same iteration; signed and
                  // word-width variants differ only in the pre/post fixup here.
                  final f = mop.funct;
                  final isW =
                      f == RiscVAluFunct.divw ||
                      f == RiscVAluFunct.divuw ||
                      f == RiscVAluFunct.remw ||
                      f == RiscVAluFunct.remuw;
                  final isRem =
                      f == RiscVAluFunct.rem ||
                      f == RiscVAluFunct.remu ||
                      f == RiscVAluFunct.remw ||
                      f == RiscVAluFunct.remuw;
                  final isSigned =
                      f == RiscVAluFunct.div ||
                      f == RiscVAluFunct.divw ||
                      f == RiscVAluFunct.rem ||
                      f == RiscVAluFunct.remw;
                  final w = isW ? 32 : mxlen.size;
                  final aOp = isW
                      ? readField(mop.a).slice(31, 0)
                      : readField(mop.a);
                  final bOp = isW
                      ? readField(mop.b).slice(31, 0)
                      : readField(mop.b);
                  // Feed unsigned magnitudes; force the divisor non-zero so the
                  // core never divides by zero (the fixup overrides the result
                  // when the original divisor is zero anyway).
                  final aMag = isSigned ? bmAbs(aOp, w) : aOp;
                  final bMag = isSigned ? bmAbs(bOp, w) : bOp;
                  final zw = Const(0, width: w);
                  final dividend = aMag.zeroExtend(mxlen.size);
                  final divisor = mux(
                    bMag.eq(zw),
                    Const(1, width: w),
                    bMag,
                  ).zeroExtend(mxlen.size);
                  final q = _idiv!.quotient.slice(w - 1, 0);
                  final r = _idiv!.remainder.slice(w - 1, 0);
                  final resW = isRem
                      ? (isSigned
                            ? remFixupS(aOp, bOp, r, w)
                            : remFixupU(aOp, bOp, r, w))
                      : (isSigned
                            ? divFixupS(aOp, bOp, q, w)
                            : divFixupU(aOp, bOp, q, w));
                  final result = isW ? resW.signExtend(mxlen.size) : resW;
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      _idivStart! < 1,
                      _idivDividend! < dividend,
                      _idivDivisor! < divisor,
                      If(
                        _idiv!.done,
                        then: [
                          alu < result,
                          _idivStart! < 0,
                          mopStep < mopStep + 1,
                        ],
                      ),
                    ]),
                  );
                } else if (mop is RiscVAlu) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      alu <
                          (switch (mop.funct) {
                            RiscVAluFunct.add =>
                              readField(mop.a) + readField(mop.b),
                            RiscVAluFunct.sub =>
                              readField(mop.a) - readField(mop.b),
                            RiscVAluFunct.and_ =>
                              readField(mop.a) & readField(mop.b),
                            RiscVAluFunct.or_ =>
                              readField(mop.a) | readField(mop.b),
                            RiscVAluFunct.xor_ =>
                              readField(mop.a) ^ readField(mop.b),
                            // Shift amount is masked to log2(XLEN) bits (so a
                            // 6-bit RV64 shamt / a shift-imm whose funct6 bits
                            // leak into the imm field don't over-shift), and srl
                            // is a *logical* (>>>) right shift.
                            RiscVAluFunct.sll =>
                              readField(mop.a) <<
                                  (readField(mop.b) &
                                      Const(mxlen.size - 1, width: mxlen.size)),
                            RiscVAluFunct.srl =>
                              readField(mop.a) >>>
                                  (readField(mop.b) &
                                      Const(mxlen.size - 1, width: mxlen.size)),
                            RiscVAluFunct.sra =>
                              readField(mop.a) >>
                                  (readField(mop.b) &
                                      Const(mxlen.size - 1, width: mxlen.size)),
                            RiscVAluFunct.slt => bmSignedLt(
                              readField(mop.a),
                              readField(mop.b),
                              mxlen.size,
                            ).zeroExtend(mxlen.size),
                            RiscVAluFunct.sltu => readField(
                              mop.a,
                            ).lt(readField(mop.b)).zeroExtend(mxlen.size),
                            // The whole mul family shares one multiplier per
                            // operand pair (see BmMulSet for the identity).
                            RiscVAluFunct.mul => _mulSetFor(
                              (mop.a, mop.b),
                              readField(mop.a),
                              readField(mop.b),
                              mxlen.size,
                            ).low,
                            RiscVAluFunct.mulw => _mulSetFor(
                              (mop.a, mop.b),
                              readField(mop.a),
                              readField(mop.b),
                              mxlen.size,
                            ).low.slice(31, 0).signExtend(mxlen.size),
                            RiscVAluFunct.mulh => _mulSetFor(
                              (mop.a, mop.b),
                              readField(mop.a),
                              readField(mop.b),
                              mxlen.size,
                            ).highSS,
                            RiscVAluFunct.mulhsu => _mulSetFor(
                              (mop.a, mop.b),
                              readField(mop.a),
                              readField(mop.b),
                              mxlen.size,
                            ).highSU,
                            RiscVAluFunct.mulhu => _mulSetFor(
                              (mop.a, mop.b),
                              readField(mop.a),
                              readField(mop.b),
                              mxlen.size,
                            ).highUU,
                            // div/rem are handled by the multi-cycle
                            // IterativeDivider in the branch above
                            // (_kIterativeDivRem), never this combinational
                            // switch, so no `/`/`%` tree is elaborated here.
                            RiscVAluFunct.div ||
                            RiscVAluFunct.divu ||
                            RiscVAluFunct.divw ||
                            RiscVAluFunct.divuw ||
                            RiscVAluFunct.rem ||
                            RiscVAluFunct.remu ||
                            RiscVAluFunct.remw ||
                            RiscVAluFunct.remuw => throw StateError(
                              'div/rem (${mop.funct.name}) must use the '
                              'iterative divider path, not the combinational '
                              'ALU switch',
                            ),
                            RiscVAluFunct.addw =>
                              (readField(mop.a) + readField(mop.b))
                                  .slice(31, 0)
                                  .signExtend(mxlen.size),
                            RiscVAluFunct.subw =>
                              (readField(mop.a) - readField(mop.b))
                                  .slice(31, 0)
                                  .signExtend(mxlen.size),
                            RiscVAluFunct.sllw =>
                              (readField(mop.a) << readField(mop.b).slice(4, 0))
                                  .slice(31, 0)
                                  .signExtend(mxlen.size),
                            RiscVAluFunct.srlw =>
                              (readField(mop.a).slice(31, 0) >>>
                                      readField(mop.b).slice(4, 0))
                                  .signExtend(mxlen.size),
                            RiscVAluFunct.sraw =>
                              (readField(mop.a).slice(31, 0) >>
                                      readField(mop.b).slice(4, 0))
                                  .signExtend(mxlen.size),
                            // Zbb/Zba/Zbs/Zicond/Zcb: full set, matching the
                            // emulator. (w = mxlen.size; helpers above build the
                            // min/max, rotate, clz/ctz/cpop, orc.b, rev8 HW.)
                            RiscVAluFunct.andn =>
                              readField(mop.a) & ~readField(mop.b),
                            RiscVAluFunct.orn =>
                              readField(mop.a) | ~readField(mop.b),
                            RiscVAluFunct.xnor =>
                              ~(readField(mop.a) ^ readField(mop.b)),
                            RiscVAluFunct.sextb => readField(
                              mop.a,
                            ).slice(7, 0).signExtend(mxlen.size),
                            RiscVAluFunct.sexth => readField(
                              mop.a,
                            ).slice(15, 0).signExtend(mxlen.size),
                            RiscVAluFunct.zexth => readField(
                              mop.a,
                            ).slice(15, 0).zeroExtend(mxlen.size),
                            RiscVAluFunct.zextb => readField(
                              mop.a,
                            ).slice(7, 0).zeroExtend(mxlen.size),
                            RiscVAluFunct.zextw => readField(
                              mop.a,
                            ).slice(31, 0).zeroExtend(mxlen.size),
                            RiscVAluFunct.notOp => ~readField(mop.a),
                            RiscVAluFunct.sh1add =>
                              (readField(mop.a) << 1) + readField(mop.b),
                            RiscVAluFunct.sh2add =>
                              (readField(mop.a) << 2) + readField(mop.b),
                            RiscVAluFunct.sh3add =>
                              (readField(mop.a) << 3) + readField(mop.b),
                            // min/max (signed and unsigned)
                            RiscVAluFunct.minOp => mux(
                              bmSignedLt(
                                readField(mop.a),
                                readField(mop.b),
                                mxlen.size,
                              ),
                              readField(mop.a),
                              readField(mop.b),
                            ),
                            RiscVAluFunct.maxOp => mux(
                              bmSignedLt(
                                readField(mop.a),
                                readField(mop.b),
                                mxlen.size,
                              ),
                              readField(mop.b),
                              readField(mop.a),
                            ),
                            RiscVAluFunct.minuOp => mux(
                              readField(mop.a).lt(readField(mop.b)),
                              readField(mop.a),
                              readField(mop.b),
                            ),
                            RiscVAluFunct.maxuOp => mux(
                              readField(mop.a).lt(readField(mop.b)),
                              readField(mop.b),
                              readField(mop.a),
                            ),
                            // rotates
                            RiscVAluFunct.rol => bmRotl(
                              readField(mop.a),
                              readField(mop.b),
                              mxlen.size,
                            ),
                            RiscVAluFunct.ror => bmRotr(
                              readField(mop.a),
                              readField(mop.b),
                              mxlen.size,
                            ),
                            RiscVAluFunct.rolw => bmRotl(
                              readField(mop.a).slice(31, 0),
                              readField(mop.b).slice(31, 0),
                              32,
                            ).signExtend(mxlen.size),
                            RiscVAluFunct.rorw => bmRotr(
                              readField(mop.a).slice(31, 0),
                              readField(mop.b).slice(31, 0),
                              32,
                            ).signExtend(mxlen.size),
                            // counts
                            RiscVAluFunct.clz => bmClz(
                              readField(mop.a),
                              mxlen.size,
                            ),
                            RiscVAluFunct.ctz => bmCtz(
                              readField(mop.a),
                              mxlen.size,
                            ),
                            RiscVAluFunct.cpop => bmPopcount(
                              readField(mop.a),
                              mxlen.size,
                            ),
                            RiscVAluFunct.clzw => bmClz(
                              readField(mop.a).slice(31, 0),
                              32,
                            ).zeroExtend(mxlen.size),
                            RiscVAluFunct.ctzw => bmCtz(
                              readField(mop.a).slice(31, 0),
                              32,
                            ).zeroExtend(mxlen.size),
                            RiscVAluFunct.cpopw => bmPopcount(
                              readField(mop.a).slice(31, 0),
                              32,
                            ).zeroExtend(mxlen.size),
                            // byte ops
                            RiscVAluFunct.orcb => bmOrcb(
                              readField(mop.a),
                              mxlen.size,
                            ),
                            RiscVAluFunct.rev8 => bmRev8(
                              readField(mop.a),
                              mxlen.size,
                            ),
                            // Zba unsigned-word shift-add
                            RiscVAluFunct.adduw =>
                              readField(
                                    mop.a,
                                  ).slice(31, 0).zeroExtend(mxlen.size) +
                                  readField(mop.b),
                            RiscVAluFunct.sh1adduw =>
                              (readField(
                                        mop.a,
                                      ).slice(31, 0).zeroExtend(mxlen.size) <<
                                      1) +
                                  readField(mop.b),
                            RiscVAluFunct.sh2adduw =>
                              (readField(
                                        mop.a,
                                      ).slice(31, 0).zeroExtend(mxlen.size) <<
                                      2) +
                                  readField(mop.b),
                            RiscVAluFunct.sh3adduw =>
                              (readField(
                                        mop.a,
                                      ).slice(31, 0).zeroExtend(mxlen.size) <<
                                      3) +
                                  readField(mop.b),
                            // Zbs single-bit (shift amount masked to width)
                            RiscVAluFunct.bset =>
                              readField(mop.a) |
                                  (Const(1, width: mxlen.size) <<
                                      (readField(mop.b) &
                                          Const(
                                            mxlen.size - 1,
                                            width: mxlen.size,
                                          ))),
                            RiscVAluFunct.bclr =>
                              readField(mop.a) &
                                  ~(Const(1, width: mxlen.size) <<
                                      (readField(mop.b) &
                                          Const(
                                            mxlen.size - 1,
                                            width: mxlen.size,
                                          ))),
                            RiscVAluFunct.binv =>
                              readField(mop.a) ^
                                  (Const(1, width: mxlen.size) <<
                                      (readField(mop.b) &
                                          Const(
                                            mxlen.size - 1,
                                            width: mxlen.size,
                                          ))),
                            RiscVAluFunct.bext =>
                              (readField(mop.a) >>>
                                      (readField(mop.b) &
                                          Const(
                                            mxlen.size - 1,
                                            width: mxlen.size,
                                          ))) &
                                  Const(1, width: mxlen.size),
                            // Zicond
                            RiscVAluFunct.czeroEqz => mux(
                              readField(mop.b).eq(Const(0, width: mxlen.size)),
                              Const(0, width: mxlen.size),
                              readField(mop.a),
                            ),
                            RiscVAluFunct.czeroNez => mux(
                              readField(mop.b).eq(Const(0, width: mxlen.size)),
                              readField(mop.a),
                              Const(0, width: mxlen.size),
                            ),
                          }).named(
                            'alu_${op.mnemonic}_${mop.funct.name}_${mop.a.name}_${mop.b.name}',
                          ),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is RiscVUpdatePc) {
                  Logic value = Const(mop.offset, width: mxlen.size);
                  if (mop.offsetField != null) {
                    value = readField(mop.offsetField!);
                  }
                  if (mop.offsetSource != null) {
                    value = readSource(mop.offsetSource!);
                  }
                  if (mop.align) value &= ~Const(1, width: mxlen.size);

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      nextPc < (mop.absolute ? value : (currentPc + value)),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is RiscVMemLoad) {
                  final base = readField(mop.base);
                  final addr = base + imm;

                  final unaligned =
                      (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(
                        0,
                      );

                  // Sub-word loads: the memory returns the aligned bus-word, so
                  // select the addressed lane by shifting right by the byte
                  // offset before slicing (lb/lbu/lh/lhu and Zcb c.lbu/lhu/lh).
                  final busBytes = mxlen.size ~/ 8;
                  final alignedAddr =
                      addr & ~Const(busBytes - 1, width: mxlen.size);
                  final byteOff = addr & Const(busBytes - 1, width: mxlen.size);
                  final shifted =
                      memRead.data >> (byteOff * Const(8, width: mxlen.size));
                  final raw = shifted.slice(mop.size.bits - 1, 0);

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
                          memRead.addr < alignedAddr,
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
                          memRead.en < 0,
                          mopStep < mopStep + 1,
                        ],
                      ),
                      // dport done & ~valid means the MMU walk faulted, the
                      // only ~valid source (PMP/physical access faults aren't
                      // modeled), so it is always a page fault (cause 13/15),
                      // matching the emulator's mmu.dart.
                      If(
                        memRead.en & memRead.done & ~memRead.valid,
                        then: [
                          memRead.en < 0,
                          // G-stage walk fault -> guest load page fault (21);
                          // VS/single-stage -> regular load page fault (13).
                          If(
                            memFaultGuest ?? Const(0),
                            then: doTrap(
                              Trap.loadGuestPageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                            orElse: doTrap(
                              Trap.loadPageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                          ),
                        ],
                      ),
                    ]),
                  );
                } else if (mop is RiscVMemStore) {
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
                          // Size prefix is the byte count (1<<log2size), which
                          // core.dart decodes back to log2size, not the bit
                          // count, or sb/sh/sd would mis-size (only sw worked).
                          memWrite.data <
                              [
                                Const(mop.size.bytes, width: 7),
                                value,
                              ].swizzle(),
                          If(
                            memWrite.done & memWrite.valid,
                            then: [memWrite.en < 0, mopStep < mopStep + 1],
                          ),
                          If(
                            memWrite.done & ~memWrite.valid,
                            then: [
                              memWrite.en < 0,
                              ...doTrap(
                                Trap.storePageFault,
                                addr,
                                '_${op.mnemonic}',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ]),
                  );
                } else if (mop is RiscVHypervisorMemOp) {
                  // HLV/HSV: load/store guest memory using the guest two-stage
                  // translation (asserts memGuest so the MMU routes through
                  // vsatp+hgatp even from HS-mode). Address is rs1 directly (no
                  // immediate). Mirrors RiscVMemLoad/Store otherwise.
                  final addr = readField(mop.base);
                  final unaligned =
                      (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(
                        0,
                      );
                  if (!mop.isStore) {
                    final busBytes = mxlen.size ~/ 8;
                    final alignedAddr =
                        addr & ~Const(busBytes - 1, width: mxlen.size);
                    final byteOff =
                        addr & Const(busBytes - 1, width: mxlen.size);
                    final shifted =
                        memRead.data >> (byteOff * Const(8, width: mxlen.size));
                    final raw = shifted.slice(mop.size.bits - 1, 0);
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
                            memRead.addr < alignedAddr,
                            output('memGuest') < 1,
                            mopStep < mopStep + 1,
                          ],
                        ),
                      ]),
                    );
                    steps.add(
                      CaseItem(Const(i + 1, width: maxLen.bitLength), [
                        output('memGuest') < 1, // hold across the walk
                        If(
                          memRead.en & memRead.done & memRead.valid,
                          then: [
                            // HLV's microcode has no trailing WriteRegister, so
                            // commit the loaded value directly to rd (like AMO).
                            rdWrite.en < 1,
                            rdWrite.addr < readField(mop.dest).slice(4, 0),
                            rdWrite.data <
                                (mop.unsigned
                                    ? raw.zeroExtend(mxlen.size)
                                    : raw.signExtend(mxlen.size)),
                            memRead.en < 0,
                            mopStep < mopStep + 1,
                          ],
                        ),
                        If(
                          memRead.en & memRead.done & ~memRead.valid,
                          then: [
                            memRead.en < 0,
                            If(
                              memFaultGuest ?? Const(0),
                              then: doTrap(
                                Trap.loadGuestPageFault,
                                addr,
                                '_${op.mnemonic}',
                              ),
                              orElse: doTrap(
                                Trap.loadPageFault,
                                addr,
                                '_${op.mnemonic}',
                              ),
                            ),
                          ],
                        ),
                      ]),
                    );
                  } else {
                    final value = readField(mop.dest); // rs2 = store data
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
                                [
                                  Const(mop.size.bytes, width: 7),
                                  value,
                                ].swizzle(),
                            output('memGuest') < 1,
                            If(
                              memWrite.done & memWrite.valid,
                              then: [memWrite.en < 0, mopStep < mopStep + 1],
                            ),
                            If(
                              memWrite.done & ~memWrite.valid,
                              then: [
                                memWrite.en < 0,
                                If(
                                  memFaultGuest ?? Const(0),
                                  then: doTrap(
                                    Trap.storeGuestPageFault,
                                    addr,
                                    '_${op.mnemonic}',
                                  ),
                                  orElse: doTrap(
                                    Trap.storePageFault,
                                    addr,
                                    '_${op.mnemonic}',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ]),
                    );
                  }
                } else if (mop is RiscVAtomicMemory) {
                  // AMO: read-modify-write. base=rs1 (addr, no imm), src=rs2,
                  // dest=rd (gets the sign-extended old value). Three steps:
                  // issue read, compute+issue write, complete.
                  final addr = readField(mop.base);
                  final bits = mop.size.bits;
                  final raw = memRead.data.slice(bits - 1, 0);
                  final src = readField(mop.src).slice(bits - 1, 0);
                  final newVal = (switch (mop.funct) {
                    RiscVAtomicFunct.add => raw + src,
                    RiscVAtomicFunct.swap => src,
                    RiscVAtomicFunct.xor_ => raw ^ src,
                    RiscVAtomicFunct.and_ => raw & src,
                    RiscVAtomicFunct.or_ => raw | src,
                    RiscVAtomicFunct.min => mux(
                      bmSignedLt(raw, src, bits),
                      raw,
                      src,
                    ),
                    RiscVAtomicFunct.max => mux(
                      bmSignedLt(raw, src, bits),
                      src,
                      raw,
                    ),
                    RiscVAtomicFunct.minu => mux(raw.lt(src), raw, src),
                    RiscVAtomicFunct.maxu => mux(raw.lt(src), src, raw),
                    // Zacas amocas: store src (rs2) iff the loaded value equals
                    // rd's current value; otherwise leave memory unchanged (store
                    // the loaded value back). rd still receives the loaded value.
                    // The compare operand is rd's VALUE, not its index: the rd
                    // latch holds the index (loaded at setup, never read back
                    // because the shared AMO microcode has no ReadRegister(rd)),
                    // so source the value over the otherwise-idle rs1 read port
                    // (its address is the latched rs1, not the port), driven for
                    // cas below.
                    RiscVAtomicFunct.cas => mux(
                      raw.eq(rs1Read.data.slice(bits - 1, 0)),
                      src,
                      raw,
                    ),
                  }).named('amo_${mop.funct.name}');
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
                          memRead.en < 1,
                          memRead.addr < addr,
                          // cas needs rd's VALUE as the compare operand: read it
                          // over the idle rs1 port (held through the compute step
                          // below). Harmless for other AMOs, so gate on cas.
                          if (mop.funct == RiscVAtomicFunct.cas) ...[
                            rs1Read.en < 1,
                            rs1Read.addr <
                                readField(
                                  mop.dest,
                                  register: false,
                                ).slice(4, 0),
                          ],
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
                          memRead.en < 0,
                          // Commit the (sign-extended) old value to rd, the AMO
                          // microcode has no trailing WriteRegister, so drive the
                          // regfile write port directly (as WriteRegister does).
                          rdWrite.addr <
                              readField(mop.dest, register: false).slice(4, 0),
                          rdWrite.data < raw.signExtend(mxlen.size),
                          rdWrite.en <
                              readField(
                                mop.dest,
                                register: false,
                              ).slice(4, 0).gt(0),
                          // Issue the modified-value store.
                          memWrite.en < 1,
                          memWrite.addr < addr,
                          memWrite.data <
                              [
                                Const(mop.size.bytes, width: 7),
                                newVal.zeroExtend(mxlen.size),
                              ].swizzle(),
                          mopStep < mopStep + 1,
                        ],
                      ),
                      If(
                        memRead.en & memRead.done & ~memRead.valid,
                        then: [
                          memRead.en < 0,
                          // G-stage walk fault -> guest load page fault (21);
                          // VS/single-stage -> regular load page fault (13).
                          If(
                            memFaultGuest ?? Const(0),
                            then: doTrap(
                              Trap.loadGuestPageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                            orElse: doTrap(
                              Trap.loadPageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                          ),
                        ],
                      ),
                    ]),
                  );

                  steps.add(
                    CaseItem(Const(i + 2, width: maxLen.bitLength), [
                      If(
                        memWrite.done & memWrite.valid,
                        then: [memWrite.en < 0, mopStep < mopStep + 1],
                      ),
                      If(
                        memWrite.done & ~memWrite.valid,
                        then: [
                          memWrite.en < 0,
                          // G-stage walk fault -> guest store page fault (23);
                          // VS/single-stage -> regular store page fault (15).
                          If(
                            memFaultGuest ?? Const(0),
                            then: doTrap(
                              Trap.storeGuestPageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                            orElse: doTrap(
                              Trap.storePageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                          ),
                        ],
                      ),
                    ]),
                  );
                } else if (mop is RiscVLoadReserved) {
                  // LR: load + set the address reservation.
                  final addr = readField(mop.base);
                  final bits = mop.size.bits;
                  final raw = memRead.data.slice(bits - 1, 0);
                  final rdIdx = readField(
                    mop.dest,
                    register: false,
                  ).slice(4, 0);
                  final unaligned =
                      (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(
                        0,
                      );
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
                          memRead.en < 0,
                          rdWrite.addr < rdIdx,
                          rdWrite.data < raw.signExtend(mxlen.size),
                          rdWrite.en < rdIdx.gt(0),
                          reservationValid < 1,
                          reservationAddr < addr,
                          mopStep < mopStep + 1,
                        ],
                      ),
                      If(
                        memRead.en & memRead.done & ~memRead.valid,
                        then: [
                          memRead.en < 0,
                          // G-stage walk fault -> guest load page fault (21);
                          // VS/single-stage -> regular load page fault (13).
                          If(
                            memFaultGuest ?? Const(0),
                            then: doTrap(
                              Trap.loadGuestPageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                            orElse: doTrap(
                              Trap.loadPageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                          ),
                        ],
                      ),
                    ]),
                  );
                } else if (mop is RiscVStoreConditional) {
                  // SC: store iff the reservation is still valid for this addr;
                  // rd=0 on success, 1 on failure. Always clears the reservation.
                  final addr = readField(mop.base);
                  final value = readField(mop.src);
                  final rdIdx = readField(
                    mop.dest,
                    register: false,
                  ).slice(4, 0);
                  final unaligned =
                      (addr & Const(mop.size.bytes - 1, width: mxlen.size)).neq(
                        0,
                      );
                  final hit = reservationValid & reservationAddr.eq(addr);
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
                          reservationValid < 0,
                          If(
                            hit,
                            then: [
                              memWrite.en < 1,
                              memWrite.addr < addr,
                              // Byte-count size prefix (see RiscVMemStore).
                              memWrite.data <
                                  [
                                    Const(mop.size.bytes, width: 7),
                                    value,
                                  ].swizzle(),
                              mopStep < mopStep + 1,
                            ],
                            orElse: [
                              rdWrite.addr < rdIdx,
                              rdWrite.data < Const(1, width: mxlen.size),
                              rdWrite.en < rdIdx.gt(0),
                              mopStep < mopStep + 2,
                            ],
                          ),
                        ],
                      ),
                    ]),
                  );
                  steps.add(
                    CaseItem(Const(i + 1, width: maxLen.bitLength), [
                      If(
                        memWrite.done & memWrite.valid,
                        then: [
                          memWrite.en < 0,
                          rdWrite.addr < rdIdx,
                          rdWrite.data < Const(0, width: mxlen.size),
                          rdWrite.en < rdIdx.gt(0),
                          mopStep < mopStep + 1,
                        ],
                      ),
                      If(
                        memWrite.done & ~memWrite.valid,
                        then: [
                          memWrite.en < 0,
                          // G-stage walk fault -> guest store page fault (23);
                          // VS/single-stage -> regular store page fault (15).
                          If(
                            memFaultGuest ?? Const(0),
                            then: doTrap(
                              Trap.storeGuestPageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                            orElse: doTrap(
                              Trap.storePageFault,
                              addr,
                              '_${op.mnemonic}',
                            ),
                          ),
                        ],
                      ),
                    ]),
                  );
                } else if (mop is RiscVFpuOp) {
                  // FP compute. Operands are in the rs1/rs2 latches (read
                  // FP-routed); the trailing WriteRegister commits rd per
                  // fpFields. fadd/sub/mul/sqrt use ROHD-HCL units; fcvt uses
                  // FixedToFloat/FloatToFixed/FloatingPointConverter; feq/flt/fle
                  // a manual comparator; fdiv a multi-cycle Newton-Raphson FSM.
                  if (mop.funct == RiscVFpuFunct.fdiv) {
                    // Multi-cycle Newton-Raphson divide: stay resident at this
                    // mopStep, sequencing _divStep 0..9 (seed, 4 iters of two
                    // phases, final a*x), then write a/b and advance. The reused
                    // multiplier/adder are selected combinationally by _divStep.
                    final dp = mop.doublePrecision;
                    final seed = dp ? _divSeedD! : _divSeedS!.zeroExtend(64);
                    final mulOut = dp
                        ? _divMulOutD!
                        : _divMulOutS!.zeroExtend(64);
                    final resultBits = dp
                        ? _divMulOutD!
                        : _divMulOutS!.zeroExtend(mxlen.size);
                    steps.add(
                      CaseItem(Const(i, width: maxLen.bitLength), [
                        Case(_divStep!, [
                          CaseItem(Const(0, width: 4), [
                            _recip! < seed,
                            _divStep! < Const(1, width: 4),
                          ]),
                          for (var sIdx = 1; sIdx <= 8; sIdx++)
                            CaseItem(Const(sIdx, width: 4), [
                              (sIdx.isOdd ? _divT! : _recip!) < mulOut,
                              _divStep! < Const(sIdx + 1, width: 4),
                            ]),
                          CaseItem(Const(9, width: 4), [
                            writeField(mop.dest, resultBits),
                            _divStep! < Const(0, width: 4),
                            mopStep < mopStep + 1,
                          ]),
                        ]),
                      ]),
                    );
                  } else {
                    // FP compares (feq/flt/fle) write a 0/1 to an integer reg;
                    // computed manually since ROHD-HCL has no FP comparator.
                    final aOp = mop.doublePrecision ? rs1 : rs1.slice(31, 0);
                    final bOp = mop.doublePrecision ? rs2 : rs2.slice(31, 0);
                    final cmp = fpCompare(
                      aOp,
                      bOp,
                      mop.doublePrecision ? 64 : 32,
                      mop.doublePrecision ? 11 : 8,
                    );
                    final cmpEq = (cmp.ordered & cmp.eq).zeroExtend(mxlen.size);
                    final cmpLt = (cmp.ordered & cmp.lt).zeroExtend(mxlen.size);
                    final cmpLe = (cmp.ordered & (cmp.lt | cmp.eq)).zeroExtend(
                      mxlen.size,
                    );

                    // Bit-level FP ops (sign-inject, min/max, classify),
                    // combinational, matching the emulator's RiscVFpuFunct
                    // semantics. min/max select the raw bit pattern using the
                    // same ordered compare the emulator's `a<b`/`a>b` uses
                    // (NaN compares false → returns the second operand).
                    final w = mop.doublePrecision ? 64 : 32;
                    final manBits = mop.doublePrecision ? 52 : 23;
                    final aF = rs1.slice(w - 1, 0);
                    final bF = rs2.slice(w - 1, 0);
                    final signF = Const(1, width: w) << (w - 1);
                    final magMask = ~signF;
                    final fsgnj = (aF & magMask) | (bF & signF);
                    final fsgnjn = (aF & magMask) | ((~bF) & signF);
                    final fsgnjx = (aF & magMask) | ((aF ^ bF) & signF);
                    final ltOrdered = cmp.ordered & cmp.lt;
                    final gtOrdered = cmp.ordered & ~(cmp.lt | cmp.eq);
                    final fmin = mux(ltOrdered, aF, bF);
                    final fmax = mux(gtOrdered, aF, bF);
                    // fclass: 10-bit classification of operand a.
                    final expF = aF.slice(w - 2, manBits);
                    final manF = aF.slice(manBits - 1, 0);
                    final signBit = aF[w - 1];
                    final expAll1 = expF.eq(
                      Const(
                        (1 << (w - 1 - manBits)) - 1,
                        width: w - 1 - manBits,
                      ),
                    );
                    final exp0 = ~expF.or();
                    final man0 = ~manF.or();
                    final isInf = expAll1 & man0;
                    final isNaN = expAll1 & ~man0;
                    final isQNaN = isNaN & manF[manBits - 1];
                    final isSNaN = isNaN & ~manF[manBits - 1];
                    final isZero = exp0 & man0;
                    final isSub = exp0 & ~man0;
                    final isNorm = ~expAll1 & ~exp0;
                    // fcvt width/sign select: rs2 bit1 = 64-bit (L) vs 32-bit
                    // (W), rs2 bit0 = unsigned vs signed (decoder ignores rs2
                    // otherwise). cvtSel picks among {w, wu, l, lu}.
                    final cvtIsL = fields['rs2']![1];
                    final cvtUns = fields['rs2']![0];
                    Logic cvtSel(Logic wv, Logic wu, Logic lv, Logic lu) =>
                        mux(cvtIsL, mux(cvtUns, lu, lv), mux(cvtUns, wu, wv));
                    // fp -> int with per-rm rounding + RISC-V saturation. magP is
                    // the Q64.fracW magnitude of |operand| (lossless); ovf flags
                    // |operand| >= 2^64. Reads rs2 (W/L, signed/unsigned) and
                    // funct3 (rm; DYN=7 -> RNE, matching the emulator). Replaces
                    // the per-variant cvtSel for fp->int.
                    final ones64 = Const(
                      BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16),
                      width: 64,
                    );
                    Logic roundSatFpToInt(Logic magP, Logic ovf, int fracW) {
                      final intMag = magP.slice(fracW + 63, fracW);
                      final roundBit = magP[fracW - 1];
                      final sticky = magP.slice(fracW - 2, 0).or();
                      final rm = fields['funct3']!;
                      final rne = roundBit & (sticky | intMag[0]);
                      final rdn = signBit & (roundBit | sticky);
                      final rup = ~signBit & (roundBit | sticky);
                      final roundUp = mux(
                        rm.eq(Const(1, width: 3)), // RTZ
                        Const(0),
                        mux(
                          rm.eq(Const(2, width: 3)), // RDN
                          rdn,
                          mux(
                            rm.eq(Const(3, width: 3)), // RUP
                            rup,
                            mux(rm.eq(Const(4, width: 3)), roundBit, rne),
                          ),
                        ),
                      );
                      final rounded =
                          (intMag.zeroExtend(65) + roundUp.zeroExtend(65))
                              .slice(64, 0);
                      final magOvf = ovf | rounded[64];
                      final rMag = rounded.slice(63, 0);
                      final neg = (~rMag + Const(1, width: 64)).slice(63, 0);
                      final isL = fields['rs2']![1];
                      final uns = fields['rs2']![0];
                      final special = isNaN | isInf;
                      // W signed (sign-extended to xlen)
                      final wsPos = mux(
                        magOvf | rMag.gt(Const(0x7FFFFFFF, width: 64)),
                        Const(0x7FFFFFFF, width: 32),
                        rMag.slice(31, 0),
                      );
                      final wsNeg = mux(
                        magOvf | rMag.gt(Const(0x80000000, width: 64)),
                        Const(0x80000000, width: 32),
                        neg.slice(31, 0),
                      );
                      final ws = mux(
                        special,
                        mux(
                          isNaN,
                          Const(0x7FFFFFFF, width: 32),
                          mux(
                            signBit,
                            Const(0x80000000, width: 32),
                            Const(0x7FFFFFFF, width: 32),
                          ),
                        ),
                        mux(signBit, wsNeg, wsPos),
                      ).signExtend(mxlen.size);
                      // W unsigned (sign-extended to xlen)
                      final wuPos = mux(
                        magOvf | rMag.gt(Const(0xFFFFFFFF, width: 64)),
                        Const(0xFFFFFFFF, width: 32),
                        rMag.slice(31, 0),
                      );
                      final wu = mux(
                        special,
                        mux(
                          isNaN | (isInf & ~signBit),
                          Const(0xFFFFFFFF, width: 32),
                          Const(0, width: 32),
                        ),
                        mux(signBit, Const(0, width: 32), wuPos),
                      ).signExtend(mxlen.size);
                      // L signed
                      final c63 = Const(
                        BigInt.parse('7FFFFFFFFFFFFFFF', radix: 16),
                        width: 64,
                      );
                      final c63n = Const(
                        BigInt.parse('8000000000000000', radix: 16),
                        width: 64,
                      );
                      final lsPos = mux(magOvf | rMag.gt(c63), c63, rMag);
                      final lsNeg = mux(magOvf | rMag.gt(c63n), c63n, neg);
                      final ls = mux(
                        special,
                        mux(isNaN, c63, mux(signBit, c63n, c63)),
                        mux(signBit, lsNeg, lsPos),
                      );
                      // L unsigned
                      final lu = mux(
                        special,
                        mux(
                          isNaN | (isInf & ~signBit),
                          ones64,
                          Const(0, width: 64),
                        ),
                        mux(
                          signBit,
                          Const(0, width: 64),
                          mux(magOvf, ones64, rMag),
                        ),
                      );
                      // ws/wu are mxlen-wide; ls/lu are 64 (the L=fcvt.l.* form
                      // is rv64-only, dead on rv32). Coerce the L side to mxlen so
                      // the W/L mux is uniform width (no-op on rv64). #71.
                      return mux(
                        isL,
                        mux(uns, lu, ls).getRange(0, mxlen.size),
                        mux(uns, wu, ws),
                      );
                    }

                    final fclassBits = [
                      isQNaN,
                      isSNaN,
                      ~signBit & isInf,
                      ~signBit & isNorm,
                      ~signBit & isSub,
                      ~signBit & isZero,
                      signBit & isZero,
                      signBit & isSub,
                      signBit & isNorm,
                      signBit & isInf,
                    ].swizzle().zeroExtend(mxlen.size);

                    // Coerce a result arm to mxlen so the switch builds with a
                    // uniform width. The double-conversion arms produce FLEN=64
                    // values that are DEAD in the single-precision path (a single
                    // op never has those functs) but still elaborate; on rv32 that
                    // 64-bit width clashed with the 32-bit single arms (#71).
                    Logic fitM(Logic x) => x.width == mxlen.size
                        ? x
                        : (x.width > mxlen.size
                              ? x.getRange(0, mxlen.size)
                              : x.zeroExtend(mxlen.size));
                    final Logic result;
                    if (!mop.doublePrecision) {
                      result = switch (mop.funct) {
                        RiscVFpuFunct.fadd => _fpAddS!.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fsub => _fpSubS!.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fmul => _fpMulS!.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fsqrt => _fpSqrtS!.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fmadd => _fmaddS!.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fmsub => _fmsubS!.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fnmsub => _fnmsubS!.zeroExtend(
                          mxlen.size,
                        ),
                        RiscVFpuFunct.fnmadd => _fnmaddS!.zeroExtend(
                          mxlen.size,
                        ),
                        RiscVFpuFunct.feq => fitM(cmpEq),
                        RiscVFpuFunct.flt => fitM(cmpLt),
                        RiscVFpuFunct.fle => fitM(cmpLe),
                        RiscVFpuFunct.fcvtWS => fitM(
                          roundSatFpToInt(_cvtMagS!, _cvtOvfS!, 24),
                        ),
                        RiscVFpuFunct.fcvtSW => cvtSel(
                          _fcvtSW!.zeroExtend(mxlen.size),
                          _fcvtSWu!.zeroExtend(mxlen.size),
                          _fcvtSL!.zeroExtend(mxlen.size),
                          _fcvtSLu!.zeroExtend(mxlen.size),
                        ),
                        RiscVFpuFunct.fcvtWD => fitM(
                          roundSatFpToInt(_cvtMagD!, _cvtOvfD!, 53),
                        ),
                        RiscVFpuFunct.fcvtDW => fitM(
                          cvtSel(_fcvtDW!, _fcvtDWu!, _fcvtDL!, _fcvtDLu!),
                        ),
                        RiscVFpuFunct.fcvtSD => fitM(_fcvtSD!),
                        RiscVFpuFunct.fcvtDS => fitM(_fcvtDS!),
                        RiscVFpuFunct.fsgnj => fsgnj.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fsgnjn => fsgnjn.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fsgnjx => fsgnjx.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fmin => fmin.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fmax => fmax.zeroExtend(mxlen.size),
                        RiscVFpuFunct.fclass => fclassBits,
                        _ => readField(mop.a),
                      };
                    } else {
                      result = switch (mop.funct) {
                        RiscVFpuFunct.fadd => _fpAddD!,
                        RiscVFpuFunct.fsub => _fpSubD!,
                        RiscVFpuFunct.fmul => _fpMulD!,
                        RiscVFpuFunct.fsqrt => _fpSqrtD!,
                        RiscVFpuFunct.fmadd => _fmaddD!,
                        RiscVFpuFunct.fmsub => _fmsubD!,
                        RiscVFpuFunct.fnmsub => _fnmsubD!,
                        RiscVFpuFunct.fnmadd => _fnmaddD!,
                        RiscVFpuFunct.feq => cmpEq,
                        RiscVFpuFunct.flt => cmpLt,
                        RiscVFpuFunct.fle => cmpLe,
                        RiscVFpuFunct.fcvtWS => roundSatFpToInt(
                          _cvtMagS!,
                          _cvtOvfS!,
                          24,
                        ),
                        RiscVFpuFunct.fcvtSW => cvtSel(
                          _fcvtSW!.zeroExtend(mxlen.size),
                          _fcvtSWu!.zeroExtend(mxlen.size),
                          _fcvtSL!.zeroExtend(mxlen.size),
                          _fcvtSLu!.zeroExtend(mxlen.size),
                        ),
                        RiscVFpuFunct.fcvtWD => roundSatFpToInt(
                          _cvtMagD!,
                          _cvtOvfD!,
                          53,
                        ),
                        RiscVFpuFunct.fcvtDW => cvtSel(
                          _fcvtDW!,
                          _fcvtDWu!,
                          _fcvtDL!,
                          _fcvtDLu!,
                        ),
                        RiscVFpuFunct.fcvtSD => _fcvtSD!,
                        RiscVFpuFunct.fcvtDS => _fcvtDS!,
                        RiscVFpuFunct.fsgnj => fsgnj,
                        RiscVFpuFunct.fsgnjn => fsgnjn,
                        RiscVFpuFunct.fsgnjx => fsgnjx,
                        RiscVFpuFunct.fmin => fmin,
                        RiscVFpuFunct.fmax => fmax,
                        RiscVFpuFunct.fclass => fclassBits,
                        _ => readField(mop.a),
                      };
                    }
                    steps.add(
                      CaseItem(Const(i, width: maxLen.bitLength), [
                        writeField(mop.dest, result),
                        mopStep < mopStep + 1,
                      ]),
                    );
                  }
                } else if (mop is RiscVTrapOp) {
                  // The micro-op's modeCause bit decides: ecall re-encodes its
                  // cause by privilege (U/VU=8, HS=9, VS=10, M=11); ebreak and
                  // the rest keep their fixed cause. Same switch the microcode
                  // path uses, driven by the same flag.
                  steps.add(
                    CaseItem(
                      Const(i, width: maxLen.bitLength),
                      rawTrap(
                        Const(mop.isInterrupt ? 1 : 0),
                        Const(mop.causeCode, width: 6),
                        null,
                        '_${op.mnemonic}',
                        Const(mop.modeCause ? 1 : 0),
                      ),
                    ),
                  );
                } else if (mop is RiscVBranch) {
                  final value = mop.offsetField != null
                      ? readField(mop.offsetField!)
                      : Const(mop.offset, width: mxlen.size);

                  // Compare the two source registers directly. ROHD `.lt`/`.gte`
                  // are UNSIGNED, so the old sign-of-difference test (target.lt(0))
                  // was always false and broke blt/bge/bltu/bgeu. Signed needs
                  // bmSignedLt; unsigned needs a real unsigned compare. Mirrors
                  // fu_branch.dart.
                  final lhs = readField(RiscVMicroOpField.rs1);
                  final rhs = readField(RiscVMicroOpField.rs2);
                  final condition = switch (mop.condition) {
                    RiscVBranchCondition.eq => lhs.eq(rhs),
                    RiscVBranchCondition.ne => lhs.neq(rhs),
                    RiscVBranchCondition.lt => bmSignedLt(lhs, rhs, mxlen.size),
                    RiscVBranchCondition.ge => ~bmSignedLt(
                      lhs,
                      rhs,
                      mxlen.size,
                    ),
                    RiscVBranchCondition.ltu => lhs.lt(rhs),
                    RiscVBranchCondition.geu => ~lhs.lt(rhs),
                  };

                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        condition,
                        // Taken: target is PC-RELATIVE (pc + offset). `value` is
                        // the offset alone; omitting `currentPc +` collapsed the
                        // target to the offset (the in-order taken-branch wedge,
                        // #69). Jumps already do currentPc + value.
                        then: [
                          nextPc < (currentPc + value),
                          done < 1,
                          valid < 1,
                        ],
                        orElse: [mopStep < mopStep + 1],
                      ),
                    ]),
                  );
                } else if (mop is RiscVWriteLinkRegister) {
                  final value = nextPc + Const(mop.pcOffset, width: mxlen.size);
                  final reg = readField(mop.dest).slice(4, 0);

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
                } else if (mop is RiscVFenceOp) {
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
                } else if (mop is RiscVInterruptHold) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      interruptHold < 1,
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is RiscVCopyField) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      writeField(mop.dest, readField(mop.src)),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is RiscVSetField) {
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      writeField(mop.dest, readSource(mop.src)),
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is RiscVReadCsr && csrRead != null) {
                  final rdCsrAddr = readField(mop.source).slice(11, 0);
                  // VS-mode access to an HS-only hypervisor CSR (addr[11:8]==0x6,
                  // the 0x6xx range), OR a VS-mode sstateen access that mstateen
                  // allows but hstateen0.SE0 blocks, raises a virtual-instruction
                  // exception (mstateen-blocked is illegal, handled by the CSR
                  // legality path).
                  final rdVViol =
                      ((virtIn ?? Const(0)) &
                          rdCsrAddr.slice(11, 8).eq(Const(0x6, width: 4))) |
                      _stateenVsViol(rdCsrAddr);
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        rdVViol,
                        then: doTrap(
                          Trap.virtualInstruction,
                          null,
                          '_${op.mnemonic}',
                        ),
                        orElse: [
                          If(
                            currentMode.eq(
                              Const(PrivilegeMode.user.id, width: 3),
                            ),
                            then: doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                            orElse: [
                              csrRead.en < 1,
                              csrRead.addr < rdCsrAddr,
                              mopStep < mopStep + 1,
                            ],
                          ),
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
                } else if (mop is RiscVWriteCsr && csrWrite != null) {
                  final wrCsrAddr = readField(mop.dest).slice(11, 0);
                  // csrrs/csrrc with rs1=x0 (and csrr*i with uimm=0) must NOT
                  // write the CSR and must NOT trap on a read-only CSR. funct3[1]
                  // marks the set/clear forms (RS/RC/RSI/RCI); instr[19:15] (the
                  // rs1 / uimm field) == 0 is the no-write case. The write still
                  // fires harmlessly on a writable CSR (unchanged value); only
                  // the read-only trap (valid=0) must be suppressed.
                  final csrNoWrite =
                      (fields['funct3']![1] &
                              fields['rs1']!.eq(
                                Const(0, width: fields['rs1']!.width),
                              ))
                          .named('csrNoWrite_${op.mnemonic}');
                  final wrVViol =
                      ((virtIn ?? Const(0)) &
                          wrCsrAddr.slice(11, 8).eq(Const(0x6, width: 4))) |
                      _stateenVsViol(wrCsrAddr);
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      If(
                        wrVViol,
                        then: doTrap(
                          Trap.virtualInstruction,
                          null,
                          '_${op.mnemonic}',
                        ),
                        orElse: [
                          If(
                            currentMode.eq(
                              Const(PrivilegeMode.user.id, width: 3),
                            ),
                            then: doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                            orElse: [
                              csrWrite.en < 1,
                              csrWrite.addr < wrCsrAddr,
                              csrWrite.data < readSource(mop.source),
                              mopStep < mopStep + 1,
                            ],
                          ),
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
                        // Read-only CSR via csrrs/csrrc x0 (csrr*i 0): no trap,
                        // just complete (the read already delivered rd).
                        Iff(
                          csrWrite.en &
                              csrWrite.done &
                              ~csrWrite.valid &
                              csrNoWrite,
                          [mopStep < mopStep + 1],
                        ),
                        Iff(
                          csrWrite.en &
                              csrWrite.done &
                              ~csrWrite.valid &
                              ~csrNoWrite,
                          doTrap(Trap.illegal, null, '_${op.mnemonic}'),
                        ),
                      ]),
                    ]),
                  );
                } else if (mop is RiscVReturnOp) {
                  // MRET (privilegeLevel 3) / SRET (1). Terminal single-step:
                  // signal the return; core.dart restores PC←{m,s}epc and
                  // mode←{m,s}status.xPP and pops the status stack.
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      output('isReturn') < 1,
                      output('returnLevel') <
                          Const(mop.privilegeLevel, width: 3),
                      done < 1,
                      valid < 1,
                    ]),
                  );
                } else if (mop is RiscVTlbFenceOp) {
                  // sfence.vma: pulse fence -> MMU fetch-TLB flush (see static
                  // path). Over-flushes the icache harmlessly.
                  steps.add(
                    CaseItem(Const(i, width: maxLen.bitLength), [
                      fence < 1,
                      mopStep < mopStep + 1,
                    ]),
                  );
                } else if (mop is RiscVTlbInvalidateOp) {
                  // TODO: once MMU has a TLB
                } else {
                  // Unhandled micro-op, generate a no-op step that advances
                  steps.add(
                    CaseItem(Const(steps.length + 1, width: maxLen.bitLength), [
                      mopStep < mopStep + 1,
                    ]),
                  );
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
