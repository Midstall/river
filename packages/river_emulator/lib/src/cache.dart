import 'package:river/river.dart';

typedef CacheFill = Future<List<int>> Function(int addr, int size);
typedef CacheWriteback = Future<void> Function(int addr, int value, int size);

class CacheLine {
  final List<int> data;
  int tag;
  int lru;
  bool valid;
  bool locked;

  CacheLine({
    required this.data,
    required this.tag,
    this.lru = 0,
    this.valid = true,
    this.locked = false,
  });

  @override
  String toString() =>
      'CacheLine(tag: $tag, lru: $lru, valid: $valid, locked: $locked)';
}

class Cache {
  final HarborCacheConfig config;
  final CacheFill fill;
  final CacheWriteback writeback;
  final Map<int, List<CacheLine>> _lines;

  int get _sets => (config.size ~/ config.lineSize) ~/ config.ways;

  Cache(this.config, {required this.fill, required this.writeback})
    : _lines = Map.fromEntries(
        List.generate(
          (config.size ~/ config.lineSize) ~/ config.ways,
          (i) => MapEntry(
            i,
            List.generate(
              config.ways,
              (_) => CacheLine(
                tag: 0,
                data: List.filled(config.lineSize, 0),
                valid: false,
              ),
            ),
          ),
        ),
      );

  int _unsigned(int addr) => addr & 0xFFFFFFFF;

  int _setIndex(int addr) => (_unsigned(addr) ~/ config.lineSize) % _sets;

  int _tag(int addr) => _unsigned(addr) ~/ config.lineSize ~/ _sets;

  int _offset(int addr) => _unsigned(addr) % config.lineSize;

  CacheLine? _findLine(int addr) {
    final set = _lines[_setIndex(addr)]!;
    final t = _tag(addr);

    for (final line in set) {
      if (line.valid && line.tag == t) {
        return line;
      }
    }

    return null;
  }

  CacheLine _allocateLine(int addr) {
    final set = _lines[_setIndex(addr)]!;
    final t = _tag(addr);

    final candidates = set.where((l) => !l.locked).toList();
    if (candidates.isEmpty) {
      throw StateError('All cache lines in set ${_setIndex(addr)} are locked');
    }
    candidates.sort((a, b) => a.lru.compareTo(b.lru));
    final victim = candidates.last;

    victim.tag = t;
    victim.valid = true;
    victim.lru = 0;

    return victim;
  }

  void _markUsed(CacheLine line) {
    final set = _lines.values.firstWhere((s) => s.contains(line));
    for (final l in set) {
      l.lru++;
    }
    line.lru = 0;
  }

  void reset() {
    for (final set in _lines.values) {
      for (final line in set) {
        if (!line.locked) {
          line.valid = false;
        }
        line.lru = 0;
      }
    }
  }

  void fullReset() {
    for (final set in _lines.values) {
      for (final line in set) {
        line.valid = false;
        line.locked = false;
        line.lru = 0;
      }
    }
  }

  Future<int>? read(int addr, int size) async {
    // A read straddling a cache-line boundary (e.g. a 4-byte fetch split 2/2
    // across lines with RVC-aligned code) would index past this line's data.
    // Split into per-byte reads so each resolves against the correct line.
    if (_offset(addr) + size > config.lineSize) {
      int value = 0;
      for (int i = 0; i < size; i++) {
        final byte = (await read(addr + i, 1)) ?? 0;
        value |= (byte & 0xFF) << (8 * i);
      }
      return value;
    }

    final line = _findLine(addr);
    if (line != null) {
      _markUsed(line);

      final off = _offset(addr);

      int value = 0;
      for (int i = 0; i < size; i++) {
        value |= (line.data[off + i] & 0xFF) << (8 * i);
      }
      return value;
    }

    final newLine = _allocateLine(addr);
    final base = addr - _offset(addr);
    final block = await fill(base, config.lineSize);
    newLine.data.setAll(0, block);

    _markUsed(newLine);

    final off = _offset(addr);
    int value = 0;
    for (int i = 0; i < size; i++) {
      value |= (newLine.data[off + i] & 0xFF) << (8 * i);
    }
    return value;
  }

  Future<void> write(int addr, int value, int size) async {
    final off = _offset(addr);

    if (off + size > config.lineSize) {
      for (int i = 0; i < size; i++) {
        final byte = (value >> (8 * i)) & 0xFF;
        await write(addr + i, byte, 1);
      }
      return;
    }

    CacheLine? line = _findLine(addr);

    if (line == null) {
      line = _allocateLine(addr);
      final base = addr - _offset(addr);

      final block = await fill(base, config.lineSize);
      line.data.setAll(0, block);
    }

    final safeOff = _offset(addr);
    for (int i = 0; i < size; i++) {
      final byte = (value >> (8 * i)) & 0xFF;
      line.data[safeOff + i] = byte;
    }

    _markUsed(line);

    if (!line.locked) {
      await writeback(addr, value, size);
    }
  }

  bool invalidate(int addr) {
    final line = _findLine(addr);
    if (line != null && !line.locked) {
      line.valid = false;
      return true;
    }
    return false;
  }

  CacheLine? findLockedLine(int addr) {
    final line = _findLine(addr);
    if (line != null && line.locked) return line;
    return null;
  }

  void lockRange(int addr, int size) {
    addr = _unsigned(addr);
    final end = addr + size;
    for (var a = addr; a < end; a += config.lineSize) {
      var line = _findLine(a);
      if (line == null) {
        line = _allocateLine(a);
        line.data.fillRange(0, config.lineSize, 0);
      }
      line.locked = true;
    }
  }

  void unlockRange(int addr, int size) {
    for (var a = addr; a < addr + size; a += config.lineSize) {
      final line = _findLine(a);
      if (line != null) line.locked = false;
    }
  }

  void unlockAll() {
    for (final set in _lines.values) {
      for (final line in set) {
        line.locked = false;
      }
    }
  }

  @override
  String toString() => 'Cache($config)';
}
