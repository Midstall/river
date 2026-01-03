import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:riscv/riscv.dart';

class RiscVMstatusCsr extends CsrConfig {
  RiscVMstatusCsr()
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
        ],
      );
}

class ReadOnlyNoFieldCsr extends CsrConfig {
  ReadOnlyNoFieldCsr(String name)
    : super(name: name, access: CsrAccess.readOnly, fields: const []);
}

class SimpleRwCsr extends CsrConfig {
  SimpleRwCsr(String name)
    : super(name: name, access: CsrAccess.readWrite, fields: const []);
}

class CounterCsr extends CsrConfig {
  CounterCsr(String name)
    : super(name: name, access: CsrAccess.readOnly, fields: const []);
}

class RiscVCsrFile extends Module {
  final Mxlen mxlen;

  final int misaValue;
  final int mvendoridValue;
  final int marchidValue;
  final int mimpidValue;
  final int mhartidValue;

  final bool hasSupervisor;
  final bool hasUser;
  final bool hasPaging;
  final bool hasMxr;
  final bool hasSum;

  late final Logic clk;
  late final Logic reset;
  late final Logic mode;

  late final DataPortInterface csrRead;
  late final DataPortInterface csrWrite;

  late final CsrTop _csrTop;

  late final DataPortInterface _fdRead;
  late final DataPortInterface _fdWrite;

  late final List<int> _implementedAddrs;
  late final Set<int> _frontdoorWritableAddrs;

  CsrBackdoorInterface? _mcycleBd;
  CsrBackdoorInterface? _minstretBd;

  RiscVCsrFile(
    Logic clk,
    Logic reset,
    Logic mode, {
    required this.mxlen,
    required int misa,
    int mvendorid = 0,
    int marchid = 0,
    int mimpid = 0,
    int mhartid = 0,
    Logic? externalPending,
    this.hasSupervisor = false,
    this.hasUser = false,
    this.hasPaging = false,
    this.hasMxr = false,
    this.hasSum = false,
    required DataPortInterface csrRead,
    required DataPortInterface csrWrite,
    super.name = 'riscv_csr_file',
  }) : misaValue = misa,
       mvendoridValue = mvendorid,
       marchidValue = marchid,
       mimpidValue = mimpid,
       mhartidValue = mhartid {
    this.clk = addInput('clk', clk);
    this.reset = addInput('reset', reset);
    this.mode = addInput('mode', mode, width: 3);

    if (externalPending != null)
      externalPending = addInput(
        'externalPending',
        externalPending!,
        width: externalPending!.width,
      );

    addOutput('mstatus', width: mxlen.size);
    addOutput('mie', width: mxlen.size);
    addOutput('mip', width: mxlen.size);
    addOutput('mideleg', width: mxlen.size);
    addOutput('medeleg', width: mxlen.size);
    addOutput('mtvec', width: mxlen.size);

    if (hasSupervisor) {
      addOutput('stvec', width: mxlen.size);
      addOutput('satp', width: mxlen.size);
    }

    void _checkFits(String n, int v) {
      final max = (mxlen.size >= 63) ? null : (1 << mxlen.size);
      if (v < 0) {
        throw ArgumentError('$n must be non-negative, got $v');
      }
      if (max != null && v >= max) {
        throw ArgumentError(
          '$n (0x${v.toRadixString(16)}) does not fit in XLEN=${mxlen.size}',
        );
      }
    }

    _checkFits('misa', misaValue);
    _checkFits('mvendorid', mvendoridValue);
    _checkFits('marchid', marchidValue);
    _checkFits('mimpid', mimpidValue);
    _checkFits('mhartid', mhartidValue);

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

    _fdRead = DataPortInterface(mxlen.size, 12);
    _fdWrite = DataPortInterface(mxlen.size, 12);

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

    if (hasSupervisor) {
      stvec! <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.stvec.address).rdData!;

      satp! <=
          _csrTop.getBackdoorPortsByAddr(0, CsrAddress.satp.address).rdData!;
    }

    if (externalPending != null) {
      final mip = _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mip.address);
      mip.wrEn! <= Const(1);
      mip.wrData! <= this.mip.withSet(11, externalPending);
    }
  }

  CsrTopConfig _buildConfig(Mxlen mxlen) {
    const sstatusMask = 0x800DE133;
    const ustatusMask = 0x11;
    const supervisorInterruptMask = 0x222;
    const userInterruptMask = 0x111;

    final regs = <CsrInstanceConfig>[
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mvendorid'),
        addr: CsrAddress.mvendorid.address,
        width: mxlen.size,
        resetValue: mvendoridValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('marchid'),
        addr: CsrAddress.marchid.address,
        width: mxlen.size,
        resetValue: marchidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mimpid'),
        addr: CsrAddress.mimpid.address,
        width: mxlen.size,
        resetValue: mimpidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('mhartid'),
        addr: CsrAddress.mhartid.address,
        width: mxlen.size,
        resetValue: mhartidValue,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: ReadOnlyNoFieldCsr('misa'),
        addr: CsrAddress.misa.address,
        width: mxlen.size,
        resetValue: misaValue,
        isBackdoorWritable: false,
      ),

      CsrInstanceConfig(
        arch: RiscVMstatusCsr(),
        addr: CsrAddress.mstatus.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mie'),
        addr: CsrAddress.mie.address,
        resetValue: 0,
        width: mxlen.size,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mip'),
        addr: CsrAddress.mip.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mtvec'),
        addr: CsrAddress.mtvec.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mscratch'),
        addr: CsrAddress.mscratch.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: true,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mepc'),
        addr: CsrAddress.mepc.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mcause'),
        addr: CsrAddress.mcause.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mtval'),
        addr: CsrAddress.mtval.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('medeleg'),
        addr: CsrAddress.medeleg.address,
        resetValue: 0,
        width: mxlen.size,
      ),
      CsrInstanceConfig(
        arch: SimpleRwCsr('mideleg'),
        addr: CsrAddress.mideleg.address,
        resetValue: 0,
        width: mxlen.size,
        isBackdoorWritable: false,
      ),

      if (hasSupervisor) ...[
        CsrInstanceConfig(
          arch: SimpleRwCsr('sstatus'),
          addr: CsrAddress.sstatus.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sie'),
          addr: CsrAddress.sie.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sip'),
          addr: CsrAddress.sip.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('stvec'),
          addr: CsrAddress.stvec.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sscratch'),
          addr: CsrAddress.sscratch.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('sepc'),
          addr: CsrAddress.sepc.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('scause'),
          addr: CsrAddress.scause.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('stval'),
          addr: CsrAddress.stval.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('satp'),
          addr: CsrAddress.satp.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
      ],

      if (hasUser) ...[
        CsrInstanceConfig(
          arch: SimpleRwCsr('ustatus'),
          addr: CsrAddress.ustatus.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uie'),
          addr: CsrAddress.uie.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uip'),
          addr: CsrAddress.uip.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('utvec'),
          addr: CsrAddress.utvec.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uscratch'),
          addr: CsrAddress.uscratch.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('uepc'),
          addr: CsrAddress.uepc.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('ucause'),
          addr: CsrAddress.ucause.address,
          resetValue: 0,
          width: mxlen.size,
          isBackdoorWritable: false,
        ),
        CsrInstanceConfig(
          arch: SimpleRwCsr('utval'),
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

    final req = mux(
      privBits.eq(Const(0, width: 2)),
      Const(PrivilegeMode.user.id, width: 3),
      mux(
        privBits.eq(Const(1, width: 2)),
        Const(PrivilegeMode.supervisor.id, width: 3),
        mux(
          privBits.eq(Const(3, width: 2)),
          Const(PrivilegeMode.machine.id, width: 3),
          Const(7, width: 3),
        ),
      ),
    );

    final isUser = req.eq(Const(PrivilegeMode.user.id, width: 3));
    final isSup = req.eq(Const(PrivilegeMode.supervisor.id, width: 3));
    final userOk = mux(isUser, Const(hasUser ? 1 : 0), Const(1));
    final supOk = mux(isSup, Const(hasSupervisor ? 1 : 0), Const(1));

    return mode.gte(req) & userOk & supOk;
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

    return out;
  }

  void _wireLegalityAndFrontdoor() {
    final rdAddr12 = Logic(width: 12, name: 'csrReadAddr12');
    final wrAddr12 = Logic(width: 12, name: 'csrWriteAddr12');

    rdAddr12 <= csrRead.addr.slice(11, 0);
    wrAddr12 <= csrWrite.addr.slice(11, 0);

    final rdLegal = _addrExists(rdAddr12) & _privOk(rdAddr12);
    final wrLegal =
        _addrExists(wrAddr12) &
        _privOk(wrAddr12) &
        _isFrontdoorWritable(wrAddr12);

    _fdRead.addr <= rdAddr12;
    _fdRead.en <= csrRead.en & rdLegal;
    csrRead.data <= _fdRead.data;
    csrRead.done <= _fdRead.done & csrRead.en;
    csrRead.valid <= _fdRead.valid & csrRead.en & rdLegal;

    _fdWrite.addr <= wrAddr12;

    final maskedWriteData = _maskWriteData(wrAddr12, csrWrite.data);
    _fdWrite.data <= maskedWriteData;

    _fdWrite.en <= csrWrite.en & wrLegal;
    csrWrite.done <= _fdWrite.done & csrWrite.en;
    csrWrite.valid <= _fdWrite.valid & csrWrite.en & wrLegal;
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
  Logic get mepc =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mepc.address).rdData!;
  Logic get mcause =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mcause.address).rdData!;
  Logic get mtval =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.mtval.address).rdData!;
  Logic get medeleg => output('medeleg');
  Logic get mideleg => output('mideleg');

  Logic? get stvec => hasSupervisor ? output('stvec') : null;
  Logic get sepc =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.sepc.address).rdData!;
  Logic get scause =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.scause.address).rdData!;
  Logic get stval =>
      _csrTop.getBackdoorPortsByAddr(0, CsrAddress.stval.address).rdData!;
  Logic? get satp => hasSupervisor ? output('satp') : null;
}
