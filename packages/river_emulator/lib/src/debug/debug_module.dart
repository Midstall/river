/// A software RISC-V Debug Module (DM) for the emulator, reachable over the
/// OpenOCD `remote_bitbang` protocol (see [RemoteBitbangServer]). It lets an
/// external debugger / Heimdall halt the core and inspect registers and memory
/// exactly as it would real silicon.
///
/// This follows the RISC-V External Debug Support spec (version 0.13.2,
/// reported in `dmstatus.version`). DMI addresses use the standard map
/// (dmstatus=0x11, dmcontrol=0x10, data0=0x04, command=0x17, sbcs=0x38).
/// Note this intentionally differs from Harbor's HDL `HarborDebugModule`,
/// which mis-maps dmstatus to 0x04.
library;

/// What the Debug Module needs from the core it debugs. The emulator's
/// `RiverCore` is adapted to this by `RiverDebugTarget`.
abstract class DebugTarget {
  /// Whether the hart is currently halted (in debug mode).
  bool get halted;

  /// Request the hart enter/leave debug mode. The emulator's run loop honours
  /// [halted]; while halted the core does not retire instructions.
  void requestHalt();
  void requestResume();

  int readGpr(int index);
  void writeGpr(int index, int value);

  int readCsr(int address);
  void writeCsr(int address, int value);

  /// Read/write [size] bytes (1/2/4/8) of physical memory.
  Future<int> readMem(int address, int size);
  Future<void> writeMem(int address, int value, int size);
}

/// The DMI operation field (dmi register bits [1:0]).
enum DmiOp { nop, read, write }

/// DMI operation status returned in the capture (bits [1:0]).
class DmiStatus {
  static const success = 0;
  static const failed = 2;
  static const busy = 3;
}

/// The software Debug Module: a DMI (Debug Module Interface) register file
/// backed by a [DebugTarget]. [dmiRead]/[dmiWrite] are the only entry points;
/// the DTM drives them from JTAG scans.
class SoftDebugModule {
  final DebugTarget target;

  // Abstract-command data registers (data0/data1) hold the 64-bit operand.
  int _data0 = 0;
  int _data1 = 0;

  // Abstract command status: cmderr (bits 10:8).
  int _cmderr = 0;

  // System-bus access registers. _sbdata is sbdata0 (low 32 bits); _sbdata1 is
  // sbdata1 (high 32) used for 64-bit (sbaccess=3) accesses.
  int _sbcs = _sbcsDefault;
  int _sbaddress = 0;
  int _sbdata = 0;
  int _sbdata1 = 0;

  // dmcontrol latched bits we care about.
  bool _dmactive = false;

  SoftDebugModule(this.target);

  // sbcs defaults: sbversion=1, 32-bit access selected, 8/16/32/64 supported,
  // sbasize=32.
  static const int _sbcsDefault =
      (1 << 29) | // sbversion = 1
      (2 << 17) | // sbaccess = 2 (32-bit)
      (32 << 5) | // sbasize = 32
      (1 << 0) | // sbaccess8
      (1 << 1) | // sbaccess16
      (1 << 2) | // sbaccess32
      (1 << 3); // sbaccess64

  /// Read a DMI register (RISC-V Debug Spec addresses). Some reads (sbdata0
  /// with sbreadondata) have side effects, hence the Future.
  Future<int> dmiRead(int address) async {
    switch (address) {
      case 0x11: // dmstatus
        return _dmstatusValue();
      case 0x10: // dmcontrol (haltreq/resumereq read back 0)
        return _dmactive ? 0x1 : 0x0;
      case 0x16: // abstractcs: datacount=2, cmderr[10:8], busy=0, progbuf=0
        return 0x2 | (_cmderr << 8);
      case 0x04: // data0
        return _data0 & 0xFFFFFFFF;
      case 0x05: // data1
        return _data1 & 0xFFFFFFFF;
      case 0x38: // sbcs
        return _sbcs;
      case 0x39: // sbaddress0
        return _sbaddress & 0xFFFFFFFF;
      case 0x3c: // sbdata0
        final v = _sbdata & 0xFFFFFFFF;
        if ((_sbcs >> 15) & 1 == 1) await _sbAccess(read: true); // sbreadondata
        return v;
      case 0x3d: // sbdata1 (high 32 bits of a 64-bit system-bus access)
        return _sbdata1 & 0xFFFFFFFF;
      default:
        return 0;
    }
  }

  /// Write a DMI register, possibly triggering an action (halt, abstract
  /// command, system-bus access).
  Future<void> dmiWrite(int address, int value) async {
    switch (address) {
      case 0x10: // dmcontrol
        final dmactive = (value & 0x1) == 1;
        // dmactive is the DM's reset signal: while it is low the whole module
        // takes its reset values (Debug Spec 0.13.2). A debugger reconnecting
        // for the next fuzz iteration toggles it low to clear sticky state from
        // the prior session. Without honouring it, a leftover sbcs.sberror or
        // cmderr from iteration N makes iteration N+1's system-bus memory write
        // report "unsupported size" and fall back to a failing abstract access.
        if (!dmactive) _resetDmState();
        _dmactive = dmactive;
        if ((value >> 31) & 1 == 1) target.requestHalt(); // haltreq
        if ((value >> 30) & 1 == 1) target.requestResume(); // resumereq
      case 0x04: // data0
        _data0 = value & 0xFFFFFFFF;
      case 0x05: // data1
        _data1 = value & 0xFFFFFFFF;
      case 0x17: // command
        await _runCommand(value);
      case 0x38: // sbcs
        // Only the control fields are writable. The capability fields
        // (sbversion[31:29], sbasize[11:5], sbaccessN[4:0]) are read-only: if a
        // debugger's write is allowed to clear them, a later reconnect reads
        // sbcs back, sees no supported access size, and abandons the system bus
        // (the "unsupported size" memory-write failure). sberror[14:12] and
        // sbbusyerror[22] are write-1-clear.
        const sbcsRoMask = 0xE0000FFF;
        const sbcsRwMask =
            0x001F8000; // sbreadonaddr|sbaccess|sbautoinc|sbreadondata
        const sbcsW1cMask = (1 << 22) | (0x7 << 12);
        final sbcsKeptW1c = _sbcs & sbcsW1cMask & ~value;
        _sbcs =
            (_sbcsDefault & sbcsRoMask) | (value & sbcsRwMask) | sbcsKeptW1c;
      case 0x39: // sbaddress0
        _sbaddress = value & 0xFFFFFFFF;
        if ((_sbcs >> 20) & 1 == 1) await _sbAccess(read: true); // sbreadonaddr
      case 0x3d: // sbdata1: high 32 bits, staged before the sbdata0 write
        _sbdata1 = value & 0xFFFFFFFF;
      case 0x3c: // sbdata0
        _sbdata = value & 0xFFFFFFFF;
        await _sbAccess(read: false);
    }
  }

  /// Reset the Debug Module's register state to its defaults. Triggered by
  /// dmcontrol.dmactive=0 (the spec's DM reset) so each debugger session starts
  /// clean even though this module object outlives a single connection.
  void _resetDmState() {
    _cmderr = 0;
    _data0 = 0;
    _data1 = 0;
    _sbcs = _sbcsDefault;
    _sbaddress = 0;
    _sbdata = 0;
    _sbdata1 = 0;
  }

  int _dmstatusValue() {
    final halted = target.halted;
    return 2 | // version = 2 (0.13.2)
        (1 << 7) | // authenticated
        (halted ? (1 << 9) | (1 << 8) : 0) | // all/anyhalted
        (halted ? 0 : (1 << 11) | (1 << 10)) | // all/anyrunning
        (1 << 17) |
        (1 << 16); // all/anyresumeack
  }

  /// Execute an abstract command (cmdtype in bits [31:24]). Only "access
  /// register" (0) is supported; memory uses the system bus instead.
  Future<void> _runCommand(int command) async {
    _cmderr = 0;
    final cmdtype = (command >> 24) & 0xFF;
    if (cmdtype != 0) {
      _cmderr = 2; // not supported -> debugger falls back to system bus
      return;
    }
    final aarsize = (command >> 20) & 0x7;
    final transfer = (command >> 17) & 1;
    final write = (command >> 16) & 1;
    final regno = command & 0xFFFF;
    final is64 = aarsize == 3;
    if (transfer == 0) return;

    try {
      if (write == 1) {
        final v = is64 ? (_data0 & 0xFFFFFFFF) | (_data1 << 32) : _data0;
        _writeReg(regno, v);
      } else {
        final v = _readReg(regno);
        _data0 = v & 0xFFFFFFFF;
        _data1 = is64 ? (v >> 32) & 0xFFFFFFFF : 0;
      }
    } catch (_) {
      _cmderr = 3; // exception
    }
  }

  int _readReg(int regno) {
    if (regno >= 0x1000 && regno <= 0x101F)
      return target.readGpr(regno - 0x1000);
    if (regno <= 0x0FFF) return target.readCsr(regno);
    throw StateError('unsupported regno 0x${regno.toRadixString(16)}');
  }

  void _writeReg(int regno, int value) {
    if (regno >= 0x1000 && regno <= 0x101F) {
      target.writeGpr(regno - 0x1000, value);
    } else if (regno <= 0x0FFF) {
      target.writeCsr(regno, value);
    } else {
      throw StateError('unsupported regno 0x${regno.toRadixString(16)}');
    }
  }

  /// Perform one system-bus access at [_sbaddress], honouring sbaccess size and
  /// autoincrement.
  Future<void> _sbAccess({required bool read}) async {
    final size =
        1 << ((_sbcs >> 17) & 0x7); // sbaccess: 0->1B,1->2B,2->4B,3->8B
    try {
      if (read) {
        final v = await target.readMem(_sbaddress, size);
        _sbdata = v & 0xFFFFFFFF;
        _sbdata1 = size > 4 ? (v >> 32) & 0xFFFFFFFF : 0;
      } else {
        // A 64-bit access spans sbdata1 (high) + sbdata0 (low); the debugger
        // writes sbdata1 first, then sbdata0 (which triggers this). Without
        // combining them a 64-bit write stores only the low word and zeroes the
        // high 4 bytes, corrupting every other word of a downloaded image.
        final v = size > 4
            ? (_sbdata & 0xFFFFFFFF) | (_sbdata1 << 32)
            : _sbdata;
        await target.writeMem(_sbaddress, v, size);
      }
      if ((_sbcs >> 16) & 1 == 1) _sbaddress += size; // sbautoincrement
    } catch (_) {
      _sbcs |= (2 << 12); // sberror = 2 (alignment/bus)
    }
  }
}
