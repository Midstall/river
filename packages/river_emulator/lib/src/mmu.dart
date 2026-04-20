import 'package:river/river.dart';
import 'core.dart' show TrapException;
import 'decoded_instruction.dart';
import 'dev.dart';
import 'tlb.dart';

enum MemoryAccess { instr, read, write }

const kPageSize = 4096;

Trap _pageFault(MemoryAccess access) => switch (access) {
  MemoryAccess.instr => Trap.instructionPageFault,
  MemoryAccess.read => Trap.loadPageFault,
  MemoryAccess.write => Trap.storePageFault,
};

/// Guest (second/G-stage) page-fault cause, used when a two-stage walk faults in
/// the hgatp G-stage rather than the VS-stage. Cf. instruction/load/storePageFault.
Trap _guestPageFault(MemoryAccess access) => switch (access) {
  MemoryAccess.instr => Trap.instructionGuestPageFault,
  MemoryAccess.read => Trap.loadGuestPageFault,
  MemoryAccess.write => Trap.storeGuestPageFault,
};

class Mmu {
  final HarborMmuConfig config;
  final Map<BusAddressRange, DeviceAccessor> devices;
  RiscVPagingMode mode;
  bool _pagingEnabled;
  int _pageTable;
  final Tlb tlb;

  Mmu(this.config, this.devices, {int tlbEntries = 32})
    : _pagingEnabled = false,
      _pageTable = 0,
      mode = RiscVPagingMode.bare,
      tlb = Tlb(entries: tlbEntries);

  bool get pagingEnabled => config.hasPaging && _pagingEnabled;

  set pagingEnabled(bool value) {
    if (config.hasPaging) {
      _pagingEnabled = value;
    } else {
      throw TrapException.illegalInstruction(StackTrace.current);
    }
  }

  int get pageTable => _pageTable;

  set pageTable(int value) {
    if (config.hasPaging) {
      _pageTable = value;
    } else {
      throw TrapException.illegalInstruction(StackTrace.current);
    }
  }

  void configure(int modeId, int ppn) {
    final pmode =
        pagingModeFromId(modeId) ??
        (throw TrapException.illegalInstruction(StackTrace.current));

    if (!pmode.isSupported(config.mxlen)) {
      throw TrapException.illegalInstruction(StackTrace.current);
    }

    mode = pmode;
    pageTable = ppn * kPageSize;
    pagingEnabled = mode != RiscVPagingMode.bare;
  }

  void reset() {
    mode = RiscVPagingMode.bare;
    _pagingEnabled = false;
    _pageTable = 0;
    tlb.reset();
  }

  void flushTlb({int? asid, int? vaddr}) {
    tlb.flush(asid: asid, vaddr: vaddr, mode: mode);
  }

  Future<int> translate(
    int addr,
    MemoryAccess access, {
    PrivilegeMode privilege = PrivilegeMode.machine,
    bool sum = false,
    bool mxr = false,
  }) async {
    if (!pagingEnabled || mode == RiscVPagingMode.bare) return addr;

    sum = sum && config.hasSupervisorUserMemory;
    mxr = mxr && config.hasMakeExecutableReadable;

    // TLB lookup
    final tlbResult = tlb.lookup(addr, access, mode);
    if (tlbResult.hit) {
      final entry = tlbResult.entry!;
      bool allowed = false;
      switch (access) {
        case MemoryAccess.read:
          allowed = entry.read || (mxr && entry.execute);
        case MemoryAccess.write:
          allowed = entry.write;
        case MemoryAccess.instr:
          allowed = entry.execute;
      }
      if (privilege == PrivilegeMode.user && !entry.user) allowed = false;
      if (privilege == PrivilegeMode.supervisor &&
          entry.user &&
          !sum &&
          access != MemoryAccess.instr) {
        allowed = false;
      }

      if (!allowed) {
        throw TrapException(_pageFault(access), addr);
      }
      return tlbResult.physAddr;
    }

    // TLB miss - full page table walk
    final levels = mode.levels;
    final vpnBits = mode.vpnBits;
    final vpnMask = (1 << vpnBits) - 1;
    final vpn = List<int>.generate(
      levels,
      (i) => (addr >> (12 + vpnBits * i)) & vpnMask,
    );

    var a = pageTable;
    var i = levels - 1;

    int buildPhys(int pte, int level) {
      int phys = addr & 0xfff;

      for (int i = 0; i < mode.ppnBits.length; i++) {
        final bits = mode.ppnBits[i];
        final mask = (1 << bits) - 1;

        int value;
        if (i < level) {
          value = (addr >> (12 + mode.vpnBits * i)) & mask;
        } else {
          value = (pte >> mode.ppnShift(i)) & mask;
        }

        phys |= value << mode.ppnPhysShift(i);
      }

      return phys;
    }

    while (true) {
      final pte = await read(
        a + vpn[i] * config.mxlen.bytes,
        config.mxlen.bytes,
        pageTranslate: false,
        privilege: privilege,
      );

      final v = pte & 1;
      final r = (pte >> 1) & 1;
      final w = (pte >> 2) & 1;
      final x = (pte >> 3) & 1;
      final u = (pte >> 4) & 1;

      if (v == 0 || (r == 0 && w == 1)) {
        throw TrapException(_pageFault(access), addr, StackTrace.current);
      }

      if (privilege == PrivilegeMode.user && u == 0) {
        throw TrapException(_pageFault(access), addr, StackTrace.current);
      }

      if (privilege == PrivilegeMode.supervisor && u == 1) {
        final isExec = access == MemoryAccess.instr;
        if (!sum && !isExec) {
          throw TrapException(_pageFault(access), addr, StackTrace.current);
        }
      }

      final isLeaf = (r == 1) || (x == 1);
      if (isLeaf) {
        bool allowed = false;
        switch (access) {
          case MemoryAccess.read:
            allowed = (r == 1) || (mxr && x == 1);
            break;
          case MemoryAccess.write:
            allowed = (w == 1);
            break;
          case MemoryAccess.instr:
            allowed = (x == 1);
            break;
        }

        if (!allowed) {
          throw TrapException(_pageFault(access), addr);
        }

        // Set Accessed bit, and Dirty bit on writes
        final aSet = (pte >> 6) & 1;
        final dSet = (pte >> 7) & 1;
        final needA = aSet == 0;
        final needD = access == MemoryAccess.write && dSet == 0;
        if (needA || needD) {
          var newPte = pte | (1 << 6);
          if (needD) newPte |= (1 << 7);
          await write(
            a + vpn[i] * config.mxlen.bytes,
            newPte,
            config.mxlen.bytes,
            pageTranslate: false,
            privilege: privilege,
          );
        }

        final physAddr = buildPhys(pte, i);

        final g = (pte >> 5) & 1;
        tlb.insert(
          addr,
          physAddr,
          i,
          mode,
          read: r == 1,
          write: w == 1,
          execute: x == 1,
          user: u == 1,
          global: g == 1,
        );

        return physAddr;
      }

      i -= 1;

      if (i < 0) {
        throw TrapException(_pageFault(access), addr);
      }

      final nextPpn = (pte >> 10);
      a = nextPpn * kPageSize;
    }
  }

  /// Two-stage (Hypervisor) translation: a guest virtual address [gva] is
  /// translated through the VS-stage page tables ([vsatpVal]) and then the
  /// G-stage page tables ([hgatpVal]) to a host physical address. Used by the
  /// HLV/HSV instructions. A `bare` stage is the identity for that stage.
  ///
  /// The G-stage uses the "x4" page-table layout: the root index is widened by
  /// two bits (a 16 KiB root table) and every leaf must be user-accessible.
  Future<int> translateGuest(
    int gva,
    MemoryAccess access, {
    required int vsatpVal,
    required int hgatpVal,
  }) async {
    final modeShift = config.mxlen.satpModeShift;
    final modeMask = config.mxlen.satpModeMask;
    final ppnMask = config.mxlen.satpPpnMask;

    final vsMode =
        pagingModeFromId((vsatpVal >> modeShift) & modeMask) ??
        RiscVPagingMode.bare;
    final gMode =
        pagingModeFromId((hgatpVal >> modeShift) & modeMask) ??
        RiscVPagingMode.bare;
    final gBase = (hgatpVal & ppnMask) * kPageSize;

    // G-stage translator: guest physical -> host physical (identity if bare).
    Future<int> gtrans(int gpa, MemoryAccess acc) async =>
        gMode == RiscVPagingMode.bare
        ? gpa
        : _walkStage(gBase, gMode, gpa, acc, gStage: true);

    if (vsMode == RiscVPagingMode.bare) {
      return gtrans(gva, access); // GPA == GVA
    }
    final vsBase = (vsatpVal & ppnMask) * kPageSize;
    return _walkStage(vsBase, vsMode, gva, access, gtrans: gtrans);
  }

  /// One page-table walk for [translateGuest]. When [gtrans] is non-null this
  /// is the VS-stage: each guest-physical PTE/table address (including the
  /// root) is mapped through it before the host read. [gStage] selects the
  /// G-stage "x4" widening of the root index and the user-page requirement.
  Future<int> _walkStage(
    int rootBase,
    RiscVPagingMode mode,
    int va,
    MemoryAccess access, {
    Future<int> Function(int gpa, MemoryAccess acc)? gtrans,
    bool gStage = false,
  }) async {
    final size = config.mxlen.bytes;
    final levels = mode.levels;
    final vpnBits = mode.vpnBits;

    Future<int> readPte(int gpa) async {
      final host = gtrans != null ? await gtrans(gpa, MemoryAccess.read) : gpa;
      return read(host, size, pageTranslate: false);
    }

    int vpnIndex(int i) {
      final extra = (gStage && i == levels - 1) ? 2 : 0;
      final width = vpnBits + extra;
      return (va >> (12 + vpnBits * i)) & ((1 << width) - 1);
    }

    int buildPhys(int pte, int level) {
      var phys = va & 0xfff;
      for (var i = 0; i < mode.ppnBits.length; i++) {
        final extra = (gStage && i == mode.ppnBits.length - 1) ? 2 : 0;
        final mask = (1 << (mode.ppnBits[i] + extra)) - 1;
        final value = i < level
            ? (va >> (12 + mode.vpnBits * i)) & mask
            : (pte >> mode.ppnShift(i)) & mask;
        phys |= value << mode.ppnPhysShift(i);
      }
      return phys;
    }

    var a = rootBase;
    var i = levels - 1;
    while (true) {
      final pte = await readPte(a + vpnIndex(i) * size);
      final v = pte & 1;
      final r = (pte >> 1) & 1;
      final w = (pte >> 2) & 1;
      final x = (pte >> 3) & 1;
      final u = (pte >> 4) & 1;

      if (v == 0 || (r == 0 && w == 1)) {
        throw TrapException(
          gStage ? _guestPageFault(access) : _pageFault(access),
          va,
          StackTrace.current,
        );
      }

      if (r == 1 || x == 1) {
        // Every G-stage *leaf* page must be user-accessible (non-leaf PTEs
        // carry no meaningful U bit).
        if (gStage && u == 0) {
          throw TrapException(
            gStage ? _guestPageFault(access) : _pageFault(access),
            va,
            StackTrace.current,
          );
        }
        final allowed = switch (access) {
          MemoryAccess.read => r == 1,
          MemoryAccess.write => w == 1,
          MemoryAccess.instr => x == 1,
        };
        if (!allowed) {
          throw TrapException(
            gStage ? _guestPageFault(access) : _pageFault(access),
            va,
            StackTrace.current,
          );
        }
        return buildPhys(pte, i);
      }

      i -= 1;
      if (i < 0) {
        throw TrapException(
          gStage ? _guestPageFault(access) : _pageFault(access),
          va,
          StackTrace.current,
        );
      }
      a = (pte >> 10) * kPageSize; // next table (guest-physical in VS-stage)
    }
  }

  Future<bool> canCache(
    int addr, {
    PrivilegeMode privilege = PrivilegeMode.machine,
    bool pageTranslate = true,
    bool sum = false,
    bool mxr = false,
  }) async {
    final entry = await getDevice(
      addr,
      privilege: privilege,
      pageTranslate: pageTranslate,
      sum: sum,
      mxr: mxr,
    );

    if (entry != null) {
      return entry.value.type == DeviceAccessorType.memory;
    }

    return false;
  }

  Future<MapEntry<BusAddressRange, DeviceAccessor>?> getDevice(
    int addr, {
    PrivilegeMode privilege = PrivilegeMode.machine,
    bool pageTranslate = true,
    bool sum = false,
    bool mxr = false,
  }) async {
    if (pageTranslate) {
      addr = await translate(
        addr,
        MemoryAccess.read,
        privilege: privilege,
        sum: sum,
        mxr: mxr,
      );
    }

    for (final entry in devices.entries) {
      final block = entry.key;

      if (addr >= block.start && addr < block.end) {
        return entry;
      }
    }

    return null;
  }

  Future<int> read(
    int addr,
    int width, {
    PrivilegeMode privilege = PrivilegeMode.machine,
    bool pageTranslate = true,
    bool sum = false,
    bool mxr = false,
  }) async {
    final entry = await getDevice(
      addr,
      privilege: privilege,
      pageTranslate: pageTranslate,
      sum: sum,
      mxr: mxr,
    );

    if (entry != null) {
      final block = entry.key;
      final dev = entry.value;
      try {
        return await dev.read(addr - block.start, width);
      } on TrapException catch (e) {
        throw e.relocate(block.start);
      }
    }

    throw TrapException(Trap.loadAccess, addr, StackTrace.current);
  }

  Future<void> write(
    int addr,
    int value,
    int width, {
    PrivilegeMode privilege = PrivilegeMode.machine,
    bool pageTranslate = true,
    bool sum = false,
    bool mxr = false,
  }) async {
    final entry = await getDevice(
      addr,
      privilege: privilege,
      pageTranslate: pageTranslate,
      sum: sum,
      mxr: mxr,
    );

    if (entry != null) {
      final block = entry.key;
      final dev = entry.value;

      try {
        await dev.write(addr - block.start, value, width);
      } on TrapException catch (e) {
        throw e.relocate(block.start);
      }
      return;
    }

    throw TrapException(Trap.storeAccess, addr, StackTrace.current);
  }

  Future<List<int>> readBlock(
    int addr,
    int length, {
    PrivilegeMode privilege = PrivilegeMode.machine,
    bool pageTranslate = true,
    bool sum = false,
    bool mxr = false,
  }) async {
    final result = List<int>.filled(length, 0);
    for (int i = 0; i < length; i++) {
      result[i] = await read(
        addr + i,
        1,
        privilege: privilege,
        pageTranslate: pageTranslate,
        sum: sum,
        mxr: mxr,
      );
    }
    return result;
  }

  @override
  String toString() =>
      'Mmu(config: $config, devices: $devices, pagingEnabled: $pagingEnabled, pageTable: $pageTable)';
}
