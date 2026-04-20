import 'package:river/river.dart';

import '../core.dart';
import 'csr_plugin.dart';

class TrapPlugin extends FiberPlugin {
  late CsrPlugin csr;

  @override
  String get name => 'trap';

  @override
  Set<Type> get dependencies => {CsrPlugin};

  int encodeCause(Trap trap, int xlen) {
    final interruptBit = trap.interrupt ? (1 << (xlen - 1)) : 0;
    return interruptBit | trap.causeCode;
  }

  PrivilegeMode selectTrapTargetMode(Trap trap, RiverCoreConfig config) {
    if (csr.mode == PrivilegeMode.machine) return PrivilegeMode.machine;
    if (!config.hasSupervisor) return PrivilegeMode.machine;

    if (trap.interrupt) {
      final mideleg = csr.read(CsrAddress.mideleg.address);
      return ((mideleg >> trap.causeCode) & 1) != 0
          ? PrivilegeMode.supervisor
          : PrivilegeMode.machine;
    } else {
      final medeleg = csr.read(CsrAddress.medeleg.address);
      return ((medeleg >> trap.causeCode) & 1) != 0
          ? PrivilegeMode.supervisor
          : PrivilegeMode.machine;
    }
  }

  /// H: whether hedeleg (exceptions) / hideleg (interrupts) further delegate a
  /// medeleg-delegated trap from HS down to VS-mode.
  bool _hDelegates(Trap trap) {
    final reg = trap.interrupt
        ? csr.read(CsrAddress.hideleg.address)
        : csr.read(CsrAddress.hedeleg.address);
    return ((reg >> trap.causeCode) & 1) != 0;
  }

  int trap(int pc, TrapException e, RiverCoreConfig config) {
    final oldMode = csr.mode;
    final oldVirt = csr.virt;
    final targetMode = selectTrapTargetMode(e.trap, config);
    final xlen = config.mxlen.size;
    final causeValue = encodeCause(e.trap, xlen);

    // H: a trap taken in VS-mode (virt=1) that medeleg delegates to S AND
    // hedeleg/hideleg further delegates stays virtualized -> VS-mode: it uses the
    // vs* trap CSRs, vectors through vstvec, pushes vsstatus, and keeps virt=1.
    // Otherwise the trap de-virtualizes (HS or M) and clears virt.
    final toVS =
        config.hasHypervisor &&
        oldVirt &&
        targetMode == PrivilegeMode.supervisor &&
        _hDelegates(e.trap);

    late final CsrAddress causeCsr, epcCsr, tvalCsr, tvecCsr;

    if (toVS) {
      causeCsr = CsrAddress.vscause;
      epcCsr = CsrAddress.vsepc;
      tvalCsr = CsrAddress.vstval;
      tvecCsr = CsrAddress.vstvec;
    } else {
      switch (targetMode) {
        case PrivilegeMode.machine:
          causeCsr = CsrAddress.mcause;
          epcCsr = CsrAddress.mepc;
          tvalCsr = CsrAddress.mtval;
          tvecCsr = CsrAddress.mtvec;
        case PrivilegeMode.supervisor:
          causeCsr = CsrAddress.scause;
          epcCsr = CsrAddress.sepc;
          tvalCsr = CsrAddress.stval;
          tvecCsr = CsrAddress.stvec;
        case PrivilegeMode.user:
          causeCsr = CsrAddress.ucause;
          epcCsr = CsrAddress.uepc;
          tvalCsr = CsrAddress.utval;
          tvecCsr = CsrAddress.utvec;
      }
    }

    if (toVS) {
      // Push the VS status stack (vsstatus.SPP/SPIE/SIE): SPP=0 from VU, 1 from VS.
      var vsstatus = csr.read(CsrAddress.vsstatus.address);
      final spp = (oldMode == PrivilegeMode.user) ? 0 : 1;
      vsstatus = (vsstatus & ~(1 << 8)) | (spp << 8);
      final sie = (vsstatus >> 1) & 1;
      vsstatus = (vsstatus & ~(1 << 5)) | (sie << 5);
      vsstatus &= ~(1 << 1);
      csr.write(CsrAddress.vsstatus.address, vsstatus);
    } else {
      var mstatus = csr.read(CsrAddress.mstatus.address);
      switch (targetMode) {
        case PrivilegeMode.machine:
          final mpp = oldMode.id;
          mstatus = (mstatus & ~(0x3 << 11)) | (mpp << 11);
          final mie = (mstatus >> 3) & 1;
          mstatus = (mstatus & ~(1 << 7)) | (mie << 7);
          mstatus &= ~(1 << 3);
        case PrivilegeMode.supervisor:
          final spp = (oldMode == PrivilegeMode.user) ? 0 : 1;
          mstatus = (mstatus & ~(1 << 8)) | (spp << 8);
          final sie = (mstatus >> 1) & 1;
          mstatus = (mstatus & ~(1 << 5)) | (sie << 5);
          mstatus &= ~(1 << 1);
        case PrivilegeMode.user:
          final uie = mstatus & 1;
          mstatus = (mstatus & ~(1 << 4)) | (uie << 4);
          mstatus &= ~1;
      }
      csr.write(CsrAddress.mstatus.address, mstatus);
    }

    csr.write(causeCsr.address, causeValue);
    csr.write(epcCsr.address, pc);
    csr.write(tvalCsr.address, e.tval ?? 0);

    // VS-mode keeps virt=1; HS/M traps de-virtualize.
    csr.mode = toVS ? PrivilegeMode.supervisor : targetMode;
    if (config.hasHypervisor) csr.virt = toVS;
    final tvec = csr.read(tvecCsr.address);

    if (tvec == 0) {
      throw AbortException.illegalInstruction(
        'Double fault due to $tvecCsr being invalid ($tvec): $e',
        e.stack,
      );
    }

    final base = tvec & ~0x3;
    final vecMode = tvec & 0x3;

    if (vecMode == 1 && e.trap.interrupt) {
      return base + 4 * e.trap.causeCode;
    } else {
      return base;
    }
  }

  @override
  void init() {
    during.setup(() async {
      csr = host.apply<CsrPlugin>();
    });
  }

  @override
  Map<String, dynamic> toJson() => {'name': name};
}
