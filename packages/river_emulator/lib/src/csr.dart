import 'package:river/river.dart';
import 'core.dart';
import 'mmu.dart';

abstract class CsrContext {
  RiverCoreConfig get config;
  PrivilegeMode get mode;
  Mmu get mmu;
}

abstract class Csr {
  final int address;

  const Csr(this.address);

  int read(CsrContext context);
  void write(CsrContext context, int value);
}

class SimpleCsr extends Csr {
  int value = 0;

  SimpleCsr(super.address);

  @override
  int read(CsrContext context) => value;

  @override
  void write(CsrContext context, int newValue) {
    value = newValue;
  }
}

class ReadOnlyCsr extends Csr {
  final int value;

  const ReadOnlyCsr(super.address, this.value);

  @override
  int read(CsrContext context) => value;

  @override
  void write(CsrContext context, int value) {
    throw TrapException.illegalInstruction();
  }
}

class MaskedCsr extends Csr {
  int value = 0;
  final int writableMask;

  MaskedCsr(super.address, this.writableMask);

  @override
  int read(CsrContext context) => value;

  @override
  void write(CsrContext context, int newValue) {
    value = (value & ~writableMask) | (newValue & writableMask);
  }
}

class LinkCsr extends Csr {
  final Csr target;
  final int? mask;
  final bool writable;

  const LinkCsr(super.address, this.target, {this.mask, this.writable = true});

  @override
  int read(CsrContext context) {
    final value = target.read(context);
    return mask != null ? (value & mask!) : value;
  }

  @override
  void write(CsrContext context, int newValue) {
    if (!writable) {
      throw TrapException.illegalInstruction();
    }

    if (mask != null) {
      final masked = newValue & mask!;
      final preserved = target.read(context) & ~mask!;
      target.write(context, preserved | masked);
    } else {
      target.write(context, newValue);
    }
  }
}

/// A CSR whose value is backed by live state elsewhere in the core (e.g. the
/// vector unit's vl/vtype, which are not a plain register in the CSR file).
/// [readValue] returns the current value; [writeValue] applies a write, or is
/// null for a read-only CSR (writes raise illegal-instruction).
class CallbackCsr extends Csr {
  final int Function() readValue;
  final void Function(int value)? writeValue;

  const CallbackCsr(super.address, this.readValue, [this.writeValue]);

  @override
  int read(CsrContext context) => readValue();

  @override
  void write(CsrContext context, int value) {
    final w = writeValue;
    if (w == null) {
      throw TrapException.illegalInstruction();
    }
    w(value);
  }
}

class IdCsr extends Csr {
  const IdCsr(super.address);

  @override
  int read(CsrContext context) => switch (CsrAddress.find(address)) {
    CsrAddress.mvendorid => context.config.vendorId,
    CsrAddress.marchid => context.config.archId,
    CsrAddress.mimpid => context.config.impId,
    CsrAddress.mhartid => context.config.hartId,
    CsrAddress.misa =>
      context.config.extensions
              .map((ext) => ext.mask)
              .fold(0, (t, i) => t | i) |
          context.config.mxlen.misa |
          ((context.config.hasSupervisor ? 1 : 0) << 18) |
          ((context.config.hasUser ? 1 : 0) << 20),
    _ => throw TrapException.illegalInstruction(),
  };

  @override
  void write(CsrContext context, int value) {
    throw TrapException.illegalInstruction();
  }

  static const List<CsrAddress> registers = [
    CsrAddress.mvendorid,
    CsrAddress.marchid,
    CsrAddress.mimpid,
    CsrAddress.mhartid,
    CsrAddress.misa,
  ];
}

class CsrFile {
  final RiscVMxlen mxlen;
  final Map<int, Csr> csrs = {};

  CsrFile(
    this.mxlen, {
    bool hasSupervisor = false,
    bool hasUser = false,
    bool hasHypervisor = false,
    bool hasStateen = false,
    int rpipelineCap = 0,
  }) {
    for (final csr in IdCsr.registers) {
      csrs[csr.address] = IdCsr(csr.address);
    }

    final fullMask = mxlen == RiscVMxlen.rv64 ? -1 : 0xFFFFFFFF;
    final tvecMask = mxlen == RiscVMxlen.rv64 ? -4 : 0xFFFFFFFC;

    csrs[CsrAddress.mstatus.address] = MaskedCsr(
      CsrAddress.mstatus.address,
      fullMask,
    );

    csrs[CsrAddress.mie.address] = SimpleCsr(CsrAddress.mie.address);
    csrs[CsrAddress.mip.address] = SimpleCsr(CsrAddress.mip.address);

    csrs[CsrAddress.mtvec.address] = MaskedCsr(
      CsrAddress.mtvec.address,
      tvecMask,
    );
    csrs[CsrAddress.mscratch.address] = SimpleCsr(CsrAddress.mscratch.address);
    csrs[CsrAddress.mepc.address] = SimpleCsr(CsrAddress.mepc.address);
    csrs[CsrAddress.mcause.address] = SimpleCsr(CsrAddress.mcause.address);
    csrs[CsrAddress.mtval.address] = SimpleCsr(CsrAddress.mtval.address);

    csrs[CsrAddress.satp.address] = MaskedCsr(
      CsrAddress.satp.address,
      fullMask,
    );

    csrs[CsrAddress.mcounteren.address] = SimpleCsr(
      CsrAddress.mcounteren.address,
    );

    csrs[CsrAddress.mideleg.address] = SimpleCsr(CsrAddress.mideleg.address);
    csrs[CsrAddress.medeleg.address] = SimpleCsr(CsrAddress.medeleg.address);

    csrs[CsrAddress.mcycle.address] = SimpleCsr(CsrAddress.mcycle.address);
    csrs[CsrAddress.minstret.address] = SimpleCsr(CsrAddress.minstret.address);

    // River custom cache control CSRs
    csrs[CsrAddress.rcachectl.address] = SimpleCsr(
      CsrAddress.rcachectl.address,
    );
    csrs[CsrAddress.rcacheaddr.address] = SimpleCsr(
      CsrAddress.rcacheaddr.address,
    );
    csrs[CsrAddress.rcachesize.address] = SimpleCsr(
      CsrAddress.rcachesize.address,
    );
    // Pipeline/speculation control. WARL: only bits [3:0] are writable
    // (SSBD/BPD/SERIALIZE/DTLBFC). The emulator is an in-order architectural
    // model with no speculation, so these bits have no behavioural effect here;
    // they exist so software reads back what it wrote and stays in parity with
    // the HDL, where the bits gate real micro-architecture.
    csrs[CsrAddress.rpipelinectl.address] = MaskedCsr(
      CsrAddress.rpipelinectl.address,
      0xF,
    );
    // Read-only pipeline feature-discovery bitmap (writes trap, RO address).
    csrs[CsrAddress.rpipelinecap.address] = ReadOnlyCsr(
      CsrAddress.rpipelinecap.address,
      rpipelineCap,
    );

    _initCounters();

    if (hasSupervisor) _initSupervisor();
    if (hasUser) _initUser();
    if (hasHypervisor) _initHypervisor();
    if (hasStateen) _initStateen(hasSupervisor, hasHypervisor);
  }

  /// State-enable CSRs (Smstateen/Ssstateen). Only SE0 (bit 63), which gates
  /// access to the lower-level state-enable CSRs, is implemented; the other
  /// architecturally-defined bits (envcfg/AIA/IMSIC/CSRIND/scontext/custom) gate
  /// features River does not implement, so they are WARL-0. The actual access
  /// denial is enforced in the CSR read/write path (see RiverCore).
  void _initStateen(bool hasSupervisor, bool hasHypervisor) {
    const se0 = 1 << 63; // bit 63 = SE0
    csrs[CsrAddress.mstateen0.address] = MaskedCsr(
      CsrAddress.mstateen0.address,
      se0,
    );
    for (final a in [
      CsrAddress.mstateen1,
      CsrAddress.mstateen2,
      CsrAddress.mstateen3,
    ]) {
      csrs[a.address] = MaskedCsr(a.address, 0);
    }
    if (hasSupervisor) {
      // No U-accessible state-enabled features in River, so sstateen* read 0.
      for (final a in [
        CsrAddress.sstateen0,
        CsrAddress.sstateen1,
        CsrAddress.sstateen2,
        CsrAddress.sstateen3,
      ]) {
        csrs[a.address] = MaskedCsr(a.address, 0);
      }
    }
    if (hasHypervisor) {
      csrs[CsrAddress.hstateen0.address] = MaskedCsr(
        CsrAddress.hstateen0.address,
        se0,
      );
      for (final a in [
        CsrAddress.hstateen1,
        CsrAddress.hstateen2,
        CsrAddress.hstateen3,
      ]) {
        csrs[a.address] = MaskedCsr(a.address, 0);
      }
    }
  }

  /// Hypervisor (H) CSRs plus the virtual-supervisor (VS-mode) shadow CSRs.
  /// Only registered when the H extension is configured.
  void _initHypervisor() {
    const writable = [
      CsrAddress.hstatus,
      CsrAddress.hedeleg,
      CsrAddress.hideleg,
      CsrAddress.hie,
      CsrAddress.hcounteren,
      CsrAddress.hgeie,
      CsrAddress.htval,
      CsrAddress.hip,
      CsrAddress.hvip,
      CsrAddress.htinst,
      CsrAddress.henvcfg,
      CsrAddress.htimedelta,
      CsrAddress.hgatp,
      CsrAddress.vsstatus,
      CsrAddress.vsie,
      CsrAddress.vstvec,
      CsrAddress.vsscratch,
      CsrAddress.vsepc,
      CsrAddress.vscause,
      CsrAddress.vstval,
      CsrAddress.vsip,
      CsrAddress.vsatp,
    ];
    for (final addr in writable) {
      csrs[addr.address] = SimpleCsr(addr.address);
    }
    // hgeip (guest external interrupt pending) is read-only.
    csrs[CsrAddress.hgeip.address] = ReadOnlyCsr(CsrAddress.hgeip.address, 0);
  }

  void _initSupervisor() {
    final mstatus = csrs[CsrAddress.mstatus.address]!;
    final mie = csrs[CsrAddress.mie.address]!;
    final mip = csrs[CsrAddress.mip.address]!;
    final fullMask = mxlen == RiscVMxlen.rv64 ? -1 : 0xFFFFFFFF;
    final tvecMask = mxlen == RiscVMxlen.rv64 ? -4 : 0xFFFFFFFC;

    final sstatusMask = mxlen == RiscVMxlen.rv64
        ? 0x80000003000DE133
        : 0x800DE133;
    csrs[CsrAddress.sstatus.address] = LinkCsr(
      CsrAddress.sstatus.address,
      mstatus,
      mask: sstatusMask,
      writable: true,
    );

    const supervisorInterruptMask = 0x222;
    csrs[CsrAddress.sie.address] = LinkCsr(
      CsrAddress.sie.address,
      mie,
      mask: supervisorInterruptMask,
    );

    csrs[CsrAddress.sip.address] = LinkCsr(
      CsrAddress.sip.address,
      mip,
      mask: supervisorInterruptMask,
    );

    csrs[CsrAddress.stvec.address] = MaskedCsr(
      CsrAddress.stvec.address,
      tvecMask,
    );
    csrs[CsrAddress.sscratch.address] = SimpleCsr(CsrAddress.sscratch.address);
    csrs[CsrAddress.sepc.address] = SimpleCsr(CsrAddress.sepc.address);
    csrs[CsrAddress.scause.address] = SimpleCsr(CsrAddress.scause.address);
    csrs[CsrAddress.stval.address] = SimpleCsr(CsrAddress.stval.address);

    csrs[CsrAddress.scounteren.address] = SimpleCsr(
      CsrAddress.scounteren.address,
    );

    // senvcfg/menvcfg: River implements none of the envcfg-controlled features
    // (Zicbo, pointer-masking, Sstc, Svpbmt), so every field is WARL-0 (writes
    // drop, reads return 0). They exist so Linux's csrw/csrr (envcfg_update_bits
    // context switch, try_to_set_pmm probe) do not trap illegal. Mirrors the HDL
    // (csr.dart applyMask(.., 0)).
    csrs[CsrAddress.senvcfg.address] = MaskedCsr(CsrAddress.senvcfg.address, 0);
    csrs[CsrAddress.menvcfg.address] = MaskedCsr(CsrAddress.menvcfg.address, 0);

    csrs[CsrAddress.satp.address] = MaskedCsr(
      CsrAddress.satp.address,
      fullMask,
    );
  }

  void _initUser() {
    final mstatus = csrs[CsrAddress.mstatus.address]!;
    final tvecMask = mxlen == RiscVMxlen.rv64 ? -4 : 0xFFFFFFFC;

    const ustatusMask = 0x11;
    csrs[CsrAddress.ustatus.address] = LinkCsr(
      CsrAddress.ustatus.address,
      mstatus,
      mask: ustatusMask,
      writable: true,
    );

    csrs[CsrAddress.utvec.address] = MaskedCsr(
      CsrAddress.utvec.address,
      tvecMask,
    );

    csrs[CsrAddress.uscratch.address] = SimpleCsr(CsrAddress.uscratch.address);
    csrs[CsrAddress.uepc.address] = SimpleCsr(CsrAddress.uepc.address);
    csrs[CsrAddress.ucause.address] = SimpleCsr(CsrAddress.ucause.address);
    csrs[CsrAddress.utval.address] = SimpleCsr(CsrAddress.utval.address);

    final mie = csrs[CsrAddress.mie.address]!;
    final mip = csrs[CsrAddress.mip.address]!;

    const userInterruptMask = 0x111;
    csrs[CsrAddress.uie.address] = LinkCsr(
      CsrAddress.uie.address,
      mie,
      mask: userInterruptMask,
    );
    csrs[CsrAddress.uip.address] = LinkCsr(
      CsrAddress.uip.address,
      mip,
      mask: userInterruptMask,
    );
  }

  void _initCounters() {
    final mcycle = csrs[CsrAddress.mcycle.address]!;
    final minstret = csrs[CsrAddress.minstret.address]!;

    csrs[CsrAddress.cycle.address] = LinkCsr(
      CsrAddress.cycle.address,
      mcycle,
      mask: -1,
      writable: false,
    );
    csrs[CsrAddress.instret.address] = LinkCsr(
      CsrAddress.instret.address,
      minstret,
      mask: -1,
      writable: false,
    );
    // time has no separate mtime here; mirror the cycle counter.
    csrs[CsrAddress.time.address] = LinkCsr(
      CsrAddress.time.address,
      mcycle,
      mask: -1,
      writable: false,
    );
  }

  void reset() {
    for (final csr in csrs.values) {
      if (csr is SimpleCsr) {
        csr.value = 0;
      } else if (csr is MaskedCsr) {
        csr.value = 0;
      }
    }
  }

  Csr operator [](int address) {
    if (!csrs.containsKey(address)) {
      throw TrapException.illegalInstruction();
    }
    return csrs[address]!;
  }

  int read(int address, CsrContext context) {
    return this[address].read(context);
  }

  void write(int address, int value, CsrContext context) {
    this[address].write(context, value);

    if (address == CsrAddress.satp.address) {
      final modeId = (value >> mxlen.satpModeShift) & mxlen.satpModeMask;
      final ppn = value & mxlen.satpPpnMask;
      context.mmu.configure(modeId, ppn);
    }

    onWrite?.call(address, value, context);
  }

  void Function(int address, int value, CsrContext context)? onWrite;

  void increment() {
    final mcycle = csrs[CsrAddress.mcycle.address];
    if (mcycle is SimpleCsr) mcycle.value++;
  }

  void retireInstruction() {
    final minstret = csrs[CsrAddress.minstret.address];
    if (minstret is SimpleCsr) minstret.value++;
  }

  String toStringWithCore(CsrContext context) =>
      'CsrFile(${Map.fromEntries(csrs.entries.map((entry) => MapEntry(CsrAddress.find(entry.key), entry.value.read(context))))})';

  @override
  String toString() => 'CsrFile()';
}
