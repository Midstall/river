import 'package:riscv/riscv.dart';
import 'package:river/river.dart';
import 'core.dart';
import 'dev.dart';

const kPageSize = 4096;

class MmuEmulator {
  final Mmu config;
  final Map<MemoryBlock, DeviceAccessorEmulator> devices;
  PagingMode mode;
  bool _pagingEnabled;
  int _pageTable;

  MmuEmulator(this.config, this.devices)
    : _pagingEnabled = false,
      _pageTable = 0,
      mode = PagingMode.bare;

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
        PagingMode.fromId(modeId) ??
        (throw TrapException.illegalInstruction(StackTrace.current));

    if (!pmode.isSupported(config.mxlen)) {
      throw TrapException.illegalInstruction(StackTrace.current);
    }

    mode = pmode;
    pageTable = ppn * kPageSize;
    pagingEnabled = mode != PagingMode.bare;
  }

  void reset() {
    mode = PagingMode.bare;
    _pagingEnabled = false;
    _pageTable = 0;
  }

  Future<int> translate(
    int addr,
    MemoryAccess access, {
    PrivilegeMode privilege = PrivilegeMode.machine,
    bool sum = false,
    bool mxr = false,
  }) async {
    if (!pagingEnabled || mode == PagingMode.bare) return addr;

    sum = sum && config.hasSum;
    mxr = mxr && config.hasMxr;

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
        a + vpn[i] * config.mxlen.width,
        config.mxlen.width,
        pageTranslate: false,
        privilege: privilege,
      );

      final v = pte & 1;
      final r = (pte >> 1) & 1;
      final w = (pte >> 2) & 1;
      final x = (pte >> 3) & 1;
      final u = (pte >> 4) & 1;

      if (v == 0 || (r == 0 && w == 1)) {
        throw TrapException(
          access == MemoryAccess.read ? Trap.loadAccess : Trap.storeAccess,
          addr,
          StackTrace.current,
        );
      }

      if (privilege == PrivilegeMode.user && u == 0) {
        throw TrapException(
          access == MemoryAccess.read ? Trap.loadAccess : Trap.storeAccess,
          addr,
          StackTrace.current,
        );
      }

      if (privilege == PrivilegeMode.supervisor && u == 1) {
        final isExec = access == MemoryAccess.instr;
        if (!sum && !isExec) {
          throw TrapException(
            access == MemoryAccess.read ? Trap.loadAccess : Trap.storeAccess,
            addr,
            StackTrace.current,
          );
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
          throw TrapException(
            access == MemoryAccess.read ? Trap.loadAccess : Trap.storeAccess,
            addr,
          );
        }

        return buildPhys(pte, i);
      }

      i -= 1;

      if (i < 0) {
        throw TrapException(
          access == MemoryAccess.read ? Trap.loadAccess : Trap.storeAccess,
          addr,
        );
      }

      final nextPpn = (pte >> 10);
      a = nextPpn * kPageSize;
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
      if (entry.value.config.type == DeviceAccessorType.mixed) {
        final laddr = addr - entry.key.start;
        if (entry.value.config.ioRange != null) {
          if (laddr >= entry.value.config.ioRange!.start &&
              laddr <= entry.value.config.ioRange!.end)
            return false;
        }
        if (entry.value.config.memoryRange != null) {
          if (laddr >= entry.value.config.memoryRange!.start &&
              laddr <= entry.value.config.memoryRange!.end)
            return true;
        }
      }
      return entry.value.config.type == DeviceAccessorType.memory;
    }

    return false;
  }

  Future<MapEntry<MemoryBlock, DeviceAccessorEmulator>?> getDevice(
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
      'MmuEmulator(config: $config, devices: $devices, pagingEnabled: $pagingEnabled, pageTable: $pageTable)';
}
