import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:rohd_hcl/rohd_hcl.dart' as hcl show DataPortInterface;
import 'package:river/river.dart';
import '../data_port.dart';

class RiscVMstatusCsr extends CsrConfig {
  // [hyp] adds the MPV field (bit 39, RV64 hypervisor) so the V-bit can be
  // pushed/popped on trap/MRET. Only declared field bits are read back, so MPV
  // must be a field to be readable/writable.
  RiscVMstatusCsr({bool hyp = false})
    : super(
        name: 'mstatus',
        access: CsrAccess.readWrite,
        fields: [
          CsrFieldConfig(
            start: 3,
            width: 1,
            name: 'mie',
            access: CsrFieldAccess.readWrite,
          ),
          CsrFieldConfig(
            start: 7,
            width: 1,
            name: 'mpie',
            access: CsrFieldAccess.readWrite,
          ),
          CsrFieldConfig(
            start: 11,
            width: 2,
            name: 'mpp',
            access: CsrFieldAccess.readWrite,
          ),
          if (hyp)
            CsrFieldConfig(
              start: 39,
              width: 1,
              name: 'mpv',
              access: CsrFieldAccess.readWrite,
            ),
        ],
      );
}

class ReadOnlyNoFieldCsr extends CsrConfig {
  // A full-width read-only field is needed for the value to be readable: a
  // CsrTop register with no fields reads back as X (only declared field bits are
  // reconstructed). The reset value still drives the bits.
  ReadOnlyNoFieldCsr(String name, int width)
    : super(
        name: name,
        access: CsrAccess.readOnly,
        fields: [
          CsrFieldConfig(
            start: 0,
            width: width,
            name: 'value',
            access: CsrFieldAccess.readOnly,
          ),
        ],
      );
}

class SimpleRwCsr extends CsrConfig {
  // Full-width read/write field so csrr reads back the stored value (a no-field
  // register reads as X). Per-CSR WARL masking is applied in _maskWriteData.
  SimpleRwCsr(String name, int width)
    : super(
        name: name,
        access: CsrAccess.readWrite,
        fields: [
          CsrFieldConfig(
            start: 0,
            width: width,
            name: 'value',
            access: CsrFieldAccess.readWrite,
          ),
        ],
      );
}

class CounterCsr extends CsrConfig {
  CounterCsr(String name)
    : super(name: name, access: CsrAccess.readOnly, fields: const []);
}

class RiscVCsrFile extends Module {
  final RiscVMxlen mxlen;

  final int misaValue;
  final int mvendoridValue;
  final int marchidValue;
  final int mimpidValue;
  final int mhartidValue;
  final int rpipelineCapValue;

  final bool hasSupervisor;
  final bool hasUser;
  final bool hasPaging;
  final bool hasMxr;
  final bool hasSum;
  final bool hasHypervisor;
  final bool hasStateen;

  late final Logic clk;
  late final Logic reset;
  late final Logic mode;

  late final DataPortInterface csrRead;
  late final DataPortInterface csrWrite;

  late final CsrTop _csrTop;

  late final hcl.DataPortInterface _fdRead;
  late final hcl.DataPortInterface _fdWrite;

  late final List<int> _implementedAddrs;
  late final Set<int> _frontdoorWritableAddrs;

  CsrBackdoorInterface? _mcycleBd;
  CsrBackdoorInterface? _minstretBd;

  // Trap save-state / xRET restore controls (driven by core.dart). All
  // optional; when null the trap CSRs are not hardware-written (csrr/csrw work).
  Logic? _trapActive; // 1-cycle pulse: a synchronous trap is retiring
  Logic? _trapTargetIsM; // 1 = trap delegated/routed to M, 0 = to S
  Logic? _trapPc; // PC of the trapping instruction → {m,s}epc
  Logic? _trapCauseVal; // full mcause value (interrupt<<xlen-1 | cause)
  Logic? _trapTval; // → {m,s}tval
  Logic? _returnActive; // 1-cycle pulse: an xRET is retiring
  Logic? _returnFromM; // 1 = MRET, 0 = SRET
  Logic?
  _virtInput; // current V-bit: in VS-mode, S-CSR accesses redirect to vs*
  Logic? _trapToVS; // pulse: a trap is being delegated to VS-mode (save to vs*)

  RiscVCsrFile(
    Logic clk,
    Logic reset,
    Logic mode, {
    required this.mxlen,
    required int misa,
    int mvendorid = 0,
    int marchid = riverArchId,
    int mimpid = 0,
    int mhartid = 0,
    int rpipelineCap = 0,
    Logic? externalPending,
    this.hasSupervisor = false,
    this.hasUser = false,
    this.hasPaging = false,
    this.hasMxr = false,
    this.hasSum = false,
    this.hasHypervisor = false,
    this.hasStateen = false,
    Logic? trapActive,
    Logic? trapTargetIsM,
    Logic? trapPc,
    Logic? trapCauseVal,
    Logic? trapTval,
    Logic? returnActive,
    Logic? returnFromM,
    Logic? virtInput,
    Logic? trapToVS,
    required DataPortInterface csrRead,
    required DataPortInterface csrWrite,
    super.name = 'riscv_csr_file',
  }) : misaValue = misa,
       mvendoridValue = mvendorid,
       marchidValue = marchid,
       mimpidValue = mimpid,
       mhartidValue = mhartid,
       rpipelineCapValue = rpipelineCap {
    this.clk = addInput('clk', clk);
    this.reset = addInput('reset', reset);
    this.mode = addInput('mode', mode, width: 3);

    if (externalPending != null) {
      externalPending = addInput(
        'externalPending',
        externalPending,
        width: externalPending.width,
      );
    }

    _trapActive = trapActive == null
        ? null
        : addInput('trapActive', trapActive);
    _trapTargetIsM = trapTargetIsM == null
        ? null
        : addInput('trapTargetIsM', trapTargetIsM);
    _trapPc = trapPc == null
        ? null
        : addInput('trapPc', trapPc, width: mxlen.size);
    _trapCauseVal = trapCauseVal == null
        ? null
        : addInput('trapCauseVal', trapCauseVal, width: mxlen.size);
    _trapTval = trapTval == null
        ? null
        : addInput('trapTval', trapTval, width: mxlen.size);
    _returnActive = returnActive == null
        ? null
        : addInput('returnActive', returnActive);
    _returnFromM = returnFromM == null
        ? null
        : addInput('returnFromM', returnFromM);
    _virtInput = virtInput == null ? null : addInput('virtIn', virtInput);
    _trapToVS = trapToVS == null ? null : addInput('trapToVS', trapToVS);

    addOutput('mstatus', width: mxlen.size);
    addOutput('mie', width: mxlen.size);
    addOutput('mip', width: mxlen.size);
    addOutput('mideleg', width: mxlen.size);
    addOutput('medeleg', width: mxlen.size);
    addOutput('mtvec', width: mxlen.size);
    // Exposed for the core's xRET PC/mode restore (output port, not a raw
    // backdoor read, to respect ROHD module boundaries).
    addOutput('mepc', width: mxlen.size);
    // Speculation/pipeline control. The core slices its low bits (DTLBFC + the
    // pipeline specCtl), so it must be a real output port (same boundary reason).
    addOutput('rpipelinectl', width: mxlen.size);
    // Microcode-update staging inputs: the core reads these stored CSR values
    // (the patch address/data) and drives the ROM write port on a ctl pulse.
    addOutput('rmicrocodeaddr', width: mxlen.size);
    addOutput('rmicrocodedata', width: mxlen.size);

    if (hasSupervisor) {
      addOutput('stvec', width: mxlen.size);
      addOutput('satp', width: mxlen.size);
      addOutput('sepc', width: mxlen.size);
      addOutput('sstatus', width: mxlen.size);
    }

    if (hasHypervisor) {
      addOutput('hstatus', width: mxlen.size);
      addOutput('hedeleg', width: mxlen.size);
      addOutput('vstvec', width: mxlen.size);
    }

    // Smstateen SE0 bits, exposed so the pipeline raises the correct exception
    // for a VS-mode state-enable access: mstateen0.SE0 clear -> illegal (below
    // M); set but hstateen0.SE0 clear in VS -> virtual.
    if (hasStateen) {
      addOutput('mstateen0_se0');
      if (hasHypervisor) addOutput('hstateen0_se0');
    }

    void checkFits(String n, int v) {
      if (mxlen.size < 64 && v < 0) {
        throw ArgumentError('$n must be non-negative, got $v');
      }
      if (mxlen.size < 63) {
        final max = 1 << mxlen.size;
        if (v >= max) {
          throw ArgumentError(
            '$n (0x${v.toRadixString(16)}) does not fit in XLEN=${mxlen.size}',
          );
        }
      }
    }

    checkFits('misa', misaValue);
    checkFits('mvendorid', mvendoridValue);
    checkFits('marchid', marchidValue);
    checkFits('mimpid', mimpidValue);
    checkFits('mhartid', mhartidValue);

    this.csrRead = csrRead.clone()
      ..connectIO(
        this,
        csrRead,
        outputTags: {DataPortGroup.data, DataPortGroup.integrity},
        inputTags: {DataPortGroup.control},
        uniquify: (og) => 'csrRead_$og',
      );

    this.csrWrite = csrWrite.clone()
      ..connectIO(
        this,
        csrWrite,
        outputTags: {DataPortGroup.integrity},
        inputTags: {DataPortGroup.control, DataPortGroup.data},
        uniquify: (og) => 'csrWrite_$og',
      );

    final cfg = _buildConfig(mxlen);

    _fdRead = hcl.DataPortInterface(mxlen.size, 12);
    _fdWrite = hcl.DataPortInterface(mxlen.size, 12);

    _csrTop = CsrTop(
      config: cfg,
      clk: this.clk,
      reset: this.reset,
      frontRead: _fdRead,
      frontWrite: _fdWrite,
      allowLargerRegisters: true,
    );

    _implementedAddrs = cfg.blocks.single.registers
        .map((r) => r.addr)
        .toList(growable: false);

    _frontdoorWritableAddrs = <int>{};
    for (final r in cfg.blocks.single.registers) {
      if (r.arch.access == CsrAccess.readWrite) {
        _frontdoorWritableAddrs.add(r.addr);
      }
    }

    _wireLegalityAndFrontdoor();

    _bindBackdoorForCounters();
    _wireCounters();
    _wireTrapState();

    mstatus <=
        _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mstatus.address).rdData!;
    mie <= _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mie.address).rdData!;
    mip <= _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mip.address).rdData!;
    mideleg <=
        _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mideleg.address).rdData!;
    medeleg <=
        _csrTop.getBackdoorPortsByAddr(0, CsrAddress.medeleg.address).rdData!;
    mtvec <=
        _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mtvec.address).rdData!;
    mepc <= _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mepc.address).rdData!;
    output('rpipelinectl') <=
        _csrTop
            .getBackdoorPortsByAddr(0, CsrAddress.rpipelinectl.address)
            .rdData!;
    output('rmicrocodeaddr') <=
        _csrTop
            .getBackdoorPortsByAddr(0, CsrAddress.rmicrocodeaddr.address)
            .rdData!;
    output('rmicrocodedata') <=
        _csrTop
            .getBackdoorPortsByAddr(0, CsrAddress.rmicrocodedata.address)
            .rdData!;

    if (hasSupervisor) {
      stvec! <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.stvec.address).rdData!;

      satp! <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.satp.address).rdData!;

      output('sepc') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.sepc.address).rdData!;
      output('sstatus') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.sstatus.address).rdData!;
    }

    if (hasHypervisor) {
      output('hstatus') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.hstatus.address).rdData!;
      output('hedeleg') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.hedeleg.address).rdData!;
      output('vstvec') <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.vstvec.address).rdData!;
    }

    if (hasStateen) {
      output('mstateen0_se0') <=
          _csrTop
              .getBackdoorPortsByAddr(0, CsrAddress.mstateen0.address)
              .rdData![mxlen.size - 1];
      if (hasHypervisor) {
        output('hstateen0_se0') <=
            _csrTop
                .getBackdoorPortsByAddr(0, CsrAddress.hstateen0.address)
                .rdData![mxlen.size - 1];
      }
    }

    final mipBd = _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mip.address);
    if (externalPending != null) {
      mipBd.wrEn! <= Const(1);
      mipBd.wrData! <= mip.withSet(11, externalPending);
    } else {
      // Must still drive the backdoor write port: an undriven wrEn floats to X
      // and the CsrBlock's ElseIf(backdoorWrEn) corrupts mip to X.
      mipBd.wrEn! <= Const(0);
      mipBd.wrData! <= Const(0, width: mxlen.size);
    }

    // mscratch has no hardware writer but is backdoor-writable so tests can seed
    // it via setData. Tie wrEn to 0 (as for mip) so it never floats to X;
    // setData's inject overrides this during seeding.
    final mscratchBd = _csrTop.getBackdoorPortsByAddr(
      0,
      CsrAddress.mscratch.address,
    );
    mscratchBd.wrEn! <= Const(0);
    mscratchBd.wrData! <= Const(0, width: mxlen.size);
  }

  CsrTopConfig _buildConfig(RiscVMxlen mxlen) {
    const sstatusMask = 0x800DE133;
    const ustatusMask = 0x11;
    const supervisorInterruptMask = 0x222;
    const userInterruptMask = 0x111;

    final regs = <CsrInstanceConfig>[
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mvendorid', mxlen.size),
        addr: CsrAddress.mvendorid.address,
        width: mxlen.size,
        resetValue: mvendoridValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('marchid', mxlen.size),
        addr: CsrAddress.marchid.address,
        width: mxlen.size,
        resetValue: marchidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mimpid', mxlen.size),
        addr: CsrAddress.mimpid.address,
        width: mxlen.size,
        resetValue: mimpidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mhartid', mxlen.size),
        addr: CsrAddress.mhartid.address,
        width: mxlen.size,
        resetValue: mhartidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('misa', mxlen.size),
        addr: CsrAddress.misa.address,
        width: mxlen.size,
        resetValue: misaValue,
        isBackdoorWritable: false,
      ),

      CsrInstanceConfig(
        arch: RiscVMstatusCsr(hyp: hasHypervisor),
        addr: CsrAddress.mstatus.address,
        resetValue: 0,
        width: mxlen.size,
        // Hardware-written on trap entry / xRET; wrEn driven in _wireTrapState.
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mie', mxlen.size),
        addr: CsrAddress.mie.address,
        resetValue: 0,
        width: mxlen.size,
        // No hardware writer, must be false or the undriven backdoor wrEn floats
        // to X and corrupts the register.
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mip', mxlen.size),
        addr: CsrAddress.mip.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mtvec', mxlen.size),
        addr: CsrAddress.mtvec.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mscratch', mxlen.size),
        addr: CsrAddress.mscratch.address,
        resetValue: 0,
        width: mxlen.size,
        // Backdoor-writable so tests can seed it via setData; its wrEn is tied
        // to 0 below (see mip) so it never floats to X in normal operation.
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mepc', mxlen.size),
        addr: CsrAddress.mepc.address,
        resetValue: 0,
        width: mxlen.size,
        // Hardware-written on trap entry (wrEn driven in _wireTrapState).
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mcause', mxlen.size),
        addr: CsrAddress.mcause.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mtval', mxlen.size),
        addr: CsrAddress.mtval.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('medeleg', mxlen.size),
        addr: CsrAddress.medeleg.address,
        resetValue: 0,
        width: mxlen.size,
        // No hardware writer, must be false (undriven backdoor wrEn -> X, which
        // silently broke S/VS-mode trap delegation when medeleg[cause] read X).
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mideleg', mxlen.size),
        addr: CsrAddress.mideleg.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),

      // Smstateen machine-level state-enable CSRs. Only SE0 (bit 63) is writable
      // (masked in _maskWriteData); the access gating lives in the legality path.
      if (hasStateen)
        for (final a in [
          CsrAddress.mstateen0,
          CsrAddress.mstateen1,
          CsrAddress.mstateen2,
          CsrAddress.mstateen3,
        ])
          CsrInstanceConfig(
            arch: SimpleRwCsr(a.name, mxlen.size),
            addr: a.address,
            resetValue: 0,
            width: mxlen.size,
            isBackdoorWritable: false,
          ),

      if (hasSupervisor) ...[
        CsrInstanceConfig(
          arch: SimpleRwCsr('sstatus', mxlen.size),
          addr: CsrAddress.sstatus.address,
          resetValue: 0,
          width: mxlen.size,
          // Hardware-written on S-trap entry / SRET (wrEn in _wireTrapState).
          isBackdoorWritable: true,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sie', mxlen.size),
          addr: CsrAddress.sie.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sip', mxlen.size),
          addr: CsrAddress.sip.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        // Ssstateen supervisor-level state-enable CSRs. No U-accessible
        // state-enabled features in River, so all bits are WARL-0 (mask 0).
        if (hasStateen)
          for (final a in [
            CsrAddress.sstateen0,
            CsrAddress.sstateen1,
            CsrAddress.sstateen2,
            CsrAddress.sstateen3,
          ])
            CsrInstanceConfig(
              arch: SimpleRwCsr(a.name, mxlen.size),
              addr: a.address,
              resetValue: 0,
              width: mxlen.size,
              isBackdoorWritable: false,
            ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('stvec', mxlen.size),
          addr: CsrAddress.stvec.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sscratch', mxlen.size),
          addr: CsrAddress.sscratch.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sepc', mxlen.size),
          addr: CsrAddress.sepc.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: true,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('scause', mxlen.size),
          addr: CsrAddress.scause.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: true,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('stval', mxlen.size),
          addr: CsrAddress.stval.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: true,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('satp', mxlen.size),
          addr: CsrAddress.satp.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
      ],

      // Hypervisor (H) + VS-shadow CSRs. Gated on hasHypervisor. hgeip is
      // read-only.
      if (hasHypervisor) ...[
        // hstatus is hardware-touched (SRET clears SPV), so backdoor-writable
        // and exposed as an output; the rest are plain RW CSRs.
        CsrInstanceConfig(
          arch: SimpleRwCsr('hstatus', mxlen.size),
          addr: CsrAddress.hstatus.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: true,
        ),
        // Hypervisor state-enable CSRs (only SE0 writable on hstateen0).
        if (hasStateen)
          for (final a in [
            CsrAddress.hstateen0,
            CsrAddress.hstateen1,
            CsrAddress.hstateen2,
            CsrAddress.hstateen3,
          ])
            CsrInstanceConfig(
              arch: SimpleRwCsr(a.name, mxlen.size),
              addr: a.address,
              resetValue: 0,
              width: mxlen.size,
              isBackdoorWritable: false,
            ),
        for (final name in const [
          'hedeleg',
          'hideleg',
          'hie',
          'hcounteren',
          'hgeie',
          'htval',
          'hip',
          'hvip',
          'htinst',
          'henvcfg',
          'htimedelta',
          'hgatp',
          'vsie',
          'vstvec',
          'vsscratch',
          'vsip',
          'vsatp',
        ])
          CsrInstanceConfig(
            arch: SimpleRwCsr(name, mxlen.size),
            addr: CsrAddress.values.firstWhere((a) => a.name == name).address,
            resetValue: 0,
            width: mxlen.size,
            isBackdoorWritable: false,
          ),
        // VS trap save-state CSRs: hardware-written when a trap is delegated to
        // VS-mode (vsepc/vscause/vstval + vsstatus push), so backdoor-writable.
        for (final name in const ['vsstatus', 'vsepc', 'vscause', 'vstval'])
          CsrInstanceConfig(
            arch: SimpleRwCsr(name, mxlen.size),
            addr: CsrAddress.values.firstWhere((a) => a.name == name).address,
            resetValue: 0,
            width: mxlen.size,
            isBackdoorWritable: true,
          ),
        CsrInstanceConfig(
          arch: ReadOnlyNoFieldCsr('hgeip', mxlen.size),
          addr: CsrAddress.hgeip.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
      ],

      if (hasUser) ...[
        CsrInstanceConfig(
          arch: SimpleRwCsr('ustatus', mxlen.size),
          addr: CsrAddress.ustatus.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uie', mxlen.size),
          addr: CsrAddress.uie.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uip', mxlen.size),
          addr: CsrAddress.uip.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('utvec', mxlen.size),
          addr: CsrAddress.utvec.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uscratch', mxlen.size),
          addr: CsrAddress.uscratch.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uepc', mxlen.size),
          addr: CsrAddress.uepc.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('ucause', mxlen.size),
          addr: CsrAddress.ucause.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('utval', mxlen.size),
          addr: CsrAddress.utval.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
      ],

      CsrInstanceConfig(
        arch: CounterCsr('mcycle'),
        addr: CsrAddress.mcycle.address,
        width: mxlen.size,
        resetValue: 0,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: CounterCsr('minstret'),
        addr: CsrAddress.minstret.address,
        width: mxlen.size,
        resetValue: 0,
        isBackdoorWritable: true,
      ),

      // River custom cache control CSRs
      CsrInstanceConfig(
        arch: SimpleRwCsr('rcachectl', mxlen.size),
        addr: CsrAddress.rcachectl.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      // Pipeline / speculation control. WARL bits [3:0]
      // (SSBD/BPD/SERIALIZE/DTLBFC), masked in _maskWriteData. Read back through
      // the rpipelinectl output port.
      CsrInstanceConfig(
        arch: SimpleRwCsr('rpipelinectl', mxlen.size),
        addr: CsrAddress.rpipelinectl.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      // Read-only pipeline feature-discovery bitmap (writes trap, RO address).
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('rpipelinecap', mxlen.size),
        addr: CsrAddress.rpipelinecap.address,
        width: mxlen.size,
        resetValue: rpipelineCapValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('rcacheaddr', mxlen.size),
        addr: CsrAddress.rcacheaddr.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('rcachesize', mxlen.size),
        addr: CsrAddress.rcachesize.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      // Microcode update: addr/data are plain RW (their stored values feed the
      // core's ROM-patch staging); ctl is RW too but the core acts on the
      // csrWrite write-pulse for its address, not the stored bits (so the
      // strobes self-clear and never re-fire).
      CsrInstanceConfig(
        arch: SimpleRwCsr('rmicrocodeaddr', mxlen.size),
        addr: CsrAddress.rmicrocodeaddr.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('rmicrocodedata', mxlen.size),
        addr: CsrAddress.rmicrocodedata.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('rmicrocodectl', mxlen.size),
        addr: CsrAddress.rmicrocodectl.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
    ];

    final block = CsrBlockConfig(name: 'csr', baseAddr: 0, registers: regs);

    final top = CsrTopConfig(
      name: 'riscv_csr_top_cfg',
      blockOffsetWidth: 12,
      blocks: [block],
    );

    _sstatusMask = sstatusMask;
    _ustatusMask = ustatusMask;
    _sieSipMask = supervisorInterruptMask;
    _uieUipMask = userInterruptMask;

    return top;
  }

  late final int _sstatusMask;
  late final int _ustatusMask;
  late final int _sieSipMask;
  late final int _uieUipMask;

  Logic _privOk(Logic addr12) {
    final privBits = addr12.getRange(8, 10);

    // CSR address bits[9:8] encode the lowest privilege: 00=user, 01=supervisor,
    // 10=hypervisor (accessible from HS-mode or M), 11=machine. Hypervisor (2)
    // maps to supervisor-level for the mode check; its existence is gated on
    // hasHypervisor via _addrExists.
    final req = mux(
      privBits.eq(Const(0, width: 2)),
      Const(PrivilegeMode.user.id, width: 3),
      mux(
        privBits.eq(Const(3, width: 2)),
        Const(PrivilegeMode.machine.id, width: 3),
        Const(PrivilegeMode.supervisor.id, width: 3), // 01 and 10
      ),
    );

    final isUser = req.eq(Const(PrivilegeMode.user.id, width: 3));
    final isSup = req.eq(Const(PrivilegeMode.supervisor.id, width: 3));
    final userOk = mux(isUser, Const(hasUser ? 1 : 0), Const(1));
    final supOk = mux(isSup, Const(hasSupervisor ? 1 : 0), Const(1));

    return mode.gte(req) & userOk & supOk;
  }

  // Smstateen access gating: deny a lower-level state-enable CSR
  // (sstateen*/hstateen*) from any mode below M when mstateen0.SE0 (MSB) is
  // clear, else allow. Only SE0 is implemented; the VS-mode virtual-instruction
  // distinction (hstateen0.SE0) is not modelled here.
  Logic _stateenOk(Logic addr12) {
    if (!hasStateen) return Const(1);
    Logic inRange(int lo, int hi) =>
        addr12.gte(Const(lo, width: 12)) & addr12.lte(Const(hi, width: 12));
    final isSstateen = inRange(0x10C, 0x10F);
    final isHstateen = hasHypervisor ? inRange(0x60C, 0x60F) : Const(0);
    final isGated = isSstateen | isHstateen;
    final belowM = ~mode.gte(
      Const(PrivilegeMode.machine.id, width: mode.width),
    );
    final mse0 = _csrTop
        .getBackdoorPortsByAddr(0, CsrAddress.mstateen0.address)
        .rdData![mxlen.size - 1];
    return ~(isGated & belowM & ~mse0);
  }

  Logic _addrExists(Logic addr12) {
    Logic hit = Const(0, width: 1);
    for (final a in _implementedAddrs) {
      hit |= addr12.eq(Const(a, width: addr12.width));
    }
    return hit;
  }

  Logic _isFrontdoorWritable(Logic addr12) {
    Logic hit = Const(0, width: 1);
    for (final a in _frontdoorWritableAddrs) {
      hit |= addr12.eq(Const(a, width: addr12.width));
    }
    return hit;
  }

  Logic _maskWriteData(Logic addr12, Logic data) {
    Logic out = data;

    final vecMask = Const(0xFFFFFFFC, width: mxlen.size);
    final fullMask = Const(~0, width: mxlen.size);

    Logic applyMask(int addr, Logic mask) {
      final hit = addr12.eq(Const(addr, width: addr12.width));
      final current = _csrTop.getBackdoorPortsByAddr(0, addr).rdData!;
      final masked = (current & ~mask) | (data & mask);
      out = mux(hit, masked, out);
      return out;
    }

    out = applyMask(CsrAddress.mtvec.address, vecMask);
    if (hasSupervisor) out = applyMask(CsrAddress.stvec.address, vecMask);
    if (hasUser) out = applyMask(CsrAddress.utvec.address, vecMask);

    if (hasSupervisor) {
      out = applyMask(
        CsrAddress.sstatus.address,
        Const(_sstatusMask, width: mxlen.size),
      );
      out = applyMask(
        CsrAddress.sie.address,
        Const(_sieSipMask, width: mxlen.size),
      );
      out = applyMask(
        CsrAddress.sip.address,
        Const(_sieSipMask, width: mxlen.size),
      );
      out = applyMask(CsrAddress.satp.address, fullMask);
    }

    if (hasUser) {
      out = applyMask(
        CsrAddress.ustatus.address,
        Const(_ustatusMask, width: mxlen.size),
      );
      out = applyMask(
        CsrAddress.uie.address,
        Const(_uieUipMask, width: mxlen.size),
      );
      out = applyMask(
        CsrAddress.uip.address,
        Const(_uieUipMask, width: mxlen.size),
      );
    }

    if (hasStateen) {
      // Only SE0 (bit 63) is writable on *stateen0; everything else is WARL-0
      // (gates features River does not implement).
      final se0Mask = (Const(1, width: mxlen.size) << (mxlen.size - 1)).named(
        'stateenSe0Mask',
      );
      final zeroMask = Const(0, width: mxlen.size);
      out = applyMask(CsrAddress.mstateen0.address, se0Mask);
      out = applyMask(CsrAddress.mstateen1.address, zeroMask);
      out = applyMask(CsrAddress.mstateen2.address, zeroMask);
      out = applyMask(CsrAddress.mstateen3.address, zeroMask);
      if (hasSupervisor) {
        out = applyMask(CsrAddress.sstateen0.address, zeroMask);
        out = applyMask(CsrAddress.sstateen1.address, zeroMask);
        out = applyMask(CsrAddress.sstateen2.address, zeroMask);
        out = applyMask(CsrAddress.sstateen3.address, zeroMask);
      }
      if (hasHypervisor) {
        out = applyMask(CsrAddress.hstateen0.address, se0Mask);
        out = applyMask(CsrAddress.hstateen1.address, zeroMask);
        out = applyMask(CsrAddress.hstateen2.address, zeroMask);
        out = applyMask(CsrAddress.hstateen3.address, zeroMask);
      }
    }

    // rpipelinectl: only the low 4 control bits are writable (WARL).
    out = applyMask(
      CsrAddress.rpipelinectl.address,
      Const(0xF, width: mxlen.size),
    );

    return out;
  }

  void _wireLegalityAndFrontdoor() {
    final rdAddr12 = Logic(width: 12, name: 'csrReadAddr12');
    final wrAddr12 = Logic(width: 12, name: 'csrWriteAddr12');

    // VS-mode CSR redirect: when virt=1, a supervisor-CSR access (addr[9:8]==01,
    // 0x1xx) is redirected to the VS shadow CSR (0x2xx) by adding 0x100
    // (sstatus->vsstatus, satp->vsatp, …).
    Logic vsRedirect(Logic a, String tag) {
      if (_virtInput == null) return a;
      final isSup = a.slice(9, 8).eq(Const(1, width: 2)).named('csrIsSup_$tag');
      return mux(
        _virtInput! & isSup,
        a + Const(0x100, width: 12),
        a,
      ).named('csrVsRed_$tag');
    }

    rdAddr12 <= vsRedirect(csrRead.addr.slice(11, 0), 'rd');
    wrAddr12 <= vsRedirect(csrWrite.addr.slice(11, 0), 'wr');

    final rdLegal =
        _addrExists(rdAddr12) & _privOk(rdAddr12) & _stateenOk(rdAddr12);
    // _isFrontdoorWritable is a strict subset of _addrExists (same register
    // list, readWrite regs only), so it implies _addrExists. Dropping the
    // redundant existence term removes the _addrExists OR-tree from
    // write-legality (area diet). Read-legality still uses _addrExists.
    final wrLegal =
        _privOk(wrAddr12) &
        _stateenOk(wrAddr12) &
        _isFrontdoorWritable(wrAddr12);

    _fdRead.addr <= rdAddr12;
    _fdRead.en <= csrRead.en & rdLegal;
    csrRead.data <= _fdRead.data;
    csrRead.done <= csrRead.en;
    csrRead.valid <= csrRead.en & rdLegal;

    _fdWrite.addr <= wrAddr12;

    final maskedWriteData = _maskWriteData(wrAddr12, csrWrite.data);
    _fdWrite.data <= maskedWriteData;

    _fdWrite.en <= csrWrite.en & wrLegal;
    csrWrite.done <= csrWrite.en;
    csrWrite.valid <= csrWrite.en & wrLegal;
  }

  void _bindBackdoorForCounters() {
    _mcycleBd = _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mcycle.address);
    _minstretBd = _csrTop.getBackdoorPortsByAddr(
      0,
      CsrAddress.minstret.address,
    );

    if (_mcycleBd!.hasWrite) {
      _mcycleBd!.wrEn!.put(0);
      _mcycleBd!.wrData!.put(0);
    }
    if (_minstretBd!.hasWrite) {
      _minstretBd!.wrEn!.put(0);
      _minstretBd!.wrData!.put(0);
    }
  }

  void _wireCounters() {
    Sequential(clk, [
      If(
        reset,
        then: [
          if (_mcycleBd != null && _mcycleBd!.hasWrite) _mcycleBd!.wrEn! < 0,
          if (_minstretBd != null && _minstretBd!.hasWrite)
            _minstretBd!.wrEn! < 0,
        ],
        orElse: [
          if (_mcycleBd != null && _mcycleBd!.hasWrite) ...[
            _mcycleBd!.wrEn! < 1,
            _mcycleBd!.wrData! <
                (_mcycleBd!.rdData! + Const(1, width: mxlen.size)),
          ],
          if (_minstretBd != null && _minstretBd!.hasWrite) ...[
            _minstretBd!.wrEn! < 1,
            _minstretBd!.wrData! <
                (_minstretBd!.rdData! + Const(1, width: mxlen.size)),
          ],
        ],
      ),
    ], reset: reset);
  }

  /// Hardware trap save-state and xRET restore, driven by core.dart's
  /// retire-cycle controls. On a synchronous trap: {m,s}epc←pc, {m,s}cause←cause,
  /// {m,s}tval←tval, and the status privilege stack is pushed (xPP←currentMode,
  /// xPIE←xIE, xIE←0). On xRET: xIE←xPIE, xPIE←1, xPP←U. All backdoor wrEn lines
  /// are driven every cycle (0 when idle). PC/mode restore itself is in
  /// core.dart; this method only manages the CSR contents.
  void _wireTrapState() {
    if (_trapActive == null) return;

    final trapToM = _trapActive! & _trapTargetIsM!;
    final retFromM = _returnActive! & _returnFromM!;

    CsrBackdoorInterface bd(int addr) =>
        getBackdoor(LogicValue.ofInt(addr, 12));

    final mstatusBd = bd(CsrAddress.mstatus.address);
    final mepcBd = bd(CsrAddress.mepc.address);
    final mcauseBd = bd(CsrAddress.mcause.address);
    final mtvalBd = bd(CsrAddress.mtval.address);

    final mcur = mstatusBd.rdData!;
    // mstatus bits: MIE=3, MPIE=7, MPP=[12:11].
    final mTrap = mcur
        .withSet(3, Const(0, width: 1)) // MIE <- 0
        .withSet(7, mcur[3]) // MPIE <- old MIE
        .withSet(11, mode.slice(1, 0)); // MPP <- current mode
    final mRet = mcur
        .withSet(3, mcur[7]) // MIE <- MPIE
        .withSet(7, Const(1, width: 1)) // MPIE <- 1
        .withSet(11, Const(0, width: 2)); // MPP <- U

    mstatusBd.wrEn! <= (trapToM | retFromM);
    mstatusBd.wrData! <= mux(trapToM, mTrap, mRet);
    mepcBd.wrEn! <= trapToM;
    mepcBd.wrData! <= _trapPc!;
    mcauseBd.wrEn! <= trapToM;
    mcauseBd.wrData! <= _trapCauseVal!;
    mtvalBd.wrEn! <= trapToM;
    mtvalBd.wrData! <= _trapTval!;

    if (hasSupervisor) {
      // A trap delegated to VS-mode (vsTrap) saves to the vs* CSRs below, not the
      // HS s* CSRs, so exclude it from trapToS.
      final vsTrap = _trapToVS ?? Const(0);
      final trapToS = _trapActive! & ~_trapTargetIsM! & ~vsTrap;
      final retFromS = _returnActive! & ~_returnFromM!;

      final sstatusBd = bd(CsrAddress.sstatus.address);
      final sepcBd = bd(CsrAddress.sepc.address);
      final scauseBd = bd(CsrAddress.scause.address);
      final stvalBd = bd(CsrAddress.stval.address);

      final scur = sstatusBd.rdData!;
      // sstatus bits: SIE=1, SPIE=5, SPP=8.
      final sTrap = scur
          .withSet(1, Const(0, width: 1)) // SIE <- 0
          .withSet(5, scur[1]) // SPIE <- old SIE
          .withSet(8, mode[0]); // SPP <- current mode (S=1/U=0)
      final sRet = scur
          .withSet(1, scur[5]) // SIE <- SPIE
          .withSet(5, Const(1, width: 1)) // SPIE <- 1
          .withSet(8, Const(0, width: 1)); // SPP <- U

      sstatusBd.wrEn! <= (trapToS | retFromS);
      sstatusBd.wrData! <= mux(trapToS, sTrap, sRet);
      sepcBd.wrEn! <= trapToS;
      sepcBd.wrData! <= _trapPc!;
      scauseBd.wrEn! <= trapToS;
      scauseBd.wrData! <= _trapCauseVal!;
      stvalBd.wrEn! <= trapToS;
      stvalBd.wrData! <= _trapTval!;

      if (hasHypervisor) {
        // An SRET from HS-mode (the guest-entry case) clears hstatus.SPV (bit 7)
        // after the V-bit has captured it. Other bits preserved.
        final hstatusBd = bd(CsrAddress.hstatus.address);
        hstatusBd.wrEn! <= retFromS;
        hstatusBd.wrData! <= hstatusBd.rdData!.withSet(7, Const(0, width: 1));

        // Trap delegated to VS-mode: save VS state (vsepc/vscause/vstval) and
        // push the VS status stack (vsstatus: SPP<-mode, SPIE<-SIE, SIE<-0).
        final vsstatusBd = bd(CsrAddress.vsstatus.address);
        final vsepcBd = bd(CsrAddress.vsepc.address);
        final vscauseBd = bd(CsrAddress.vscause.address);
        final vstvalBd = bd(CsrAddress.vstval.address);
        final vcur = vsstatusBd.rdData!;
        vsstatusBd.wrEn! <= vsTrap;
        vsstatusBd.wrData! <=
            vcur
                .withSet(1, Const(0, width: 1)) // SIE <- 0
                .withSet(5, vcur[1]) // SPIE <- old SIE
                .withSet(8, mode[0]); // SPP <- current mode
        vsepcBd.wrEn! <= vsTrap;
        vsepcBd.wrData! <= _trapPc!;
        vscauseBd.wrEn! <= vsTrap;
        vscauseBd.wrData! <= _trapCauseVal!;
        vstvalBd.wrEn! <= vsTrap;
        vstvalBd.wrData! <= _trapTval!;
      }
    }
  }

  void setData(LogicValue address, LogicValue data) {
    assert(address.width == 12);

    _csrTop.getBackdoorPortsByAddr(0, address.toInt()).wrEn!.inject(1);
    _csrTop.getBackdoorPortsByAddr(0, address.toInt()).wrData!.inject(data);
  }

  LogicValue? getData(LogicValue address) {
    assert(address.width == 12);
    return _csrTop.getBackdoorPortsByAddr(0, address.toInt()).rdData?.value;
  }

  CsrBackdoorInterface getBackdoor(LogicValue address) {
    assert(address.width == 12);

    return _csrTop.getBackdoorPortsByAddr(0, address.toInt());
  }

  Logic get mvendorid =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mvendorid.address).rdData!;
  Logic get marchid =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.marchid.address).rdData!;
  Logic get mimpid =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mimpid.address).rdData!;
  Logic get mhartid =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mhartid.address).rdData!;
  Logic get misa =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.misa.address).rdData!;

  Logic get mstatus => output('mstatus');
  Logic get mie => output('mie');
  Logic get mip => output('mip');
  Logic get mtvec => output('mtvec');
  Logic get mscratch =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mscratch.address).rdData!;
  Logic get mepc => output('mepc');
  Logic get mcause =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mcause.address).rdData!;
  Logic get mtval =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mtval.address).rdData!;
  Logic get medeleg => output('medeleg');
  Logic get mideleg => output('mideleg');

  Logic? get stvec => hasSupervisor ? output('stvec') : null;
  Logic? get sstatus => hasSupervisor ? output('sstatus') : null;
  Logic? get hstatus => hasHypervisor ? output('hstatus') : null;
  Logic? get hedeleg => hasHypervisor ? output('hedeleg') : null;
  Logic? get vstvec => hasHypervisor ? output('vstvec') : null;
  Logic? get mstateen0Se0 => hasStateen ? output('mstateen0_se0') : null;
  Logic? get hstateen0Se0 =>
      (hasStateen && hasHypervisor) ? output('hstateen0_se0') : null;
  Logic get sepc => output('sepc');
  Logic get scause =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.scause.address).rdData!;
  Logic get stval =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.stval.address).rdData!;
  Logic? get satp => hasSupervisor ? output('satp') : null;

  Logic get rcachectl =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.rcachectl.address).rdData!;
  Logic get rcacheaddr =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.rcacheaddr.address).rdData!;
  Logic get rcachesize =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.rcachesize.address).rdData!;
  Logic get rpipelinectl => output('rpipelinectl');
  Logic get rmicrocodeaddr => output('rmicrocodeaddr');
  Logic get rmicrocodedata => output('rmicrocodedata');
}
