import 'package:river/river.dart';
import 'mmu.dart';

class TlbEntry {
  final int vpn;
  final int ppn;
  final int level;
  final int asid;
  final bool valid;
  final bool read;
  final bool write;
  final bool execute;
  final bool user;
  final bool global;
  int lastAccess;

  TlbEntry({
    required this.vpn,
    required this.ppn,
    required this.level,
    this.asid = 0,
    this.valid = true,
    this.read = false,
    this.write = false,
    this.execute = false,
    this.user = false,
    this.global = false,
    this.lastAccess = 0,
  });
}

class TlbLookupResult {
  final int physAddr;
  final bool hit;
  final TlbEntry? entry;

  const TlbLookupResult.hit(this.physAddr, this.entry) : hit = true;
  const TlbLookupResult.miss() : physAddr = 0, hit = false, entry = null;
}

class Tlb {
  final int entries;
  final List<TlbEntry?> _table;
  int _accessCounter = 0;
  int _hits = 0;
  int _misses = 0;

  int get hits => _hits;
  int get misses => _misses;

  Tlb({this.entries = 32}) : _table = List.filled(entries, null);

  TlbLookupResult lookup(
    int vaddr,
    MemoryAccess access,
    RiscVPagingMode mode, {
    int asid = 0,
  }) {
    _accessCounter++;

    final vpnBits = mode.vpnBits;

    for (var i = 0; i < _table.length; i++) {
      final entry = _table[i];
      if (entry == null || !entry.valid) continue;
      if (!entry.global && entry.asid != asid) continue;

      final pageBits = 12 + vpnBits * entry.level;
      final entryVpn = vaddr >> pageBits;
      if (entryVpn != entry.vpn) continue;

      final offset = vaddr & ((1 << pageBits) - 1);
      final physAddr = (entry.ppn << pageBits) | offset;

      entry.lastAccess = _accessCounter;
      _hits++;
      return TlbLookupResult.hit(physAddr, entry);
    }

    _misses++;
    return const TlbLookupResult.miss();
  }

  void insert(
    int vaddr,
    int paddr,
    int level,
    RiscVPagingMode mode, {
    int asid = 0,
    bool read = false,
    bool write = false,
    bool execute = false,
    bool user = false,
    bool global = false,
  }) {
    final vpnBits = mode.vpnBits;
    final pageBits = 12 + vpnBits * level;
    final vpn = vaddr >> pageBits;
    final ppn = paddr >> pageBits;

    int victimIdx = 0;
    int oldestAccess = _accessCounter + 1;

    for (var i = 0; i < _table.length; i++) {
      if (_table[i] == null || !_table[i]!.valid) {
        victimIdx = i;
        break;
      }
      if (_table[i]!.lastAccess < oldestAccess) {
        oldestAccess = _table[i]!.lastAccess;
        victimIdx = i;
      }
    }

    _table[victimIdx] = TlbEntry(
      vpn: vpn,
      ppn: ppn,
      level: level,
      asid: asid,
      read: read,
      write: write,
      execute: execute,
      user: user,
      global: global,
      lastAccess: _accessCounter,
    );
  }

  void flush({int? asid, int? vaddr, RiscVPagingMode? mode}) {
    for (var i = 0; i < _table.length; i++) {
      final entry = _table[i];
      if (entry == null) continue;

      if (asid != null && !entry.global && entry.asid != asid) continue;

      if (vaddr != null && mode != null) {
        final vpnBits = mode.vpnBits;
        final pageBits = 12 + vpnBits * entry.level;
        final entryVpn = vaddr >> pageBits;
        if (entryVpn != entry.vpn) continue;
      }

      _table[i] = null;
    }
  }

  void reset() {
    for (var i = 0; i < _table.length; i++) {
      _table[i] = null;
    }
    _hits = 0;
    _misses = 0;
    _accessCounter = 0;
  }
}
