import 'debug_module.dart';

/// IEEE 1149.1 TAP states.
enum TapState {
  testLogicReset,
  runTestIdle,
  selectDr,
  captureDr,
  shiftDr,
  exit1Dr,
  pauseDr,
  exit2Dr,
  updateDr,
  selectIr,
  captureIr,
  shiftIr,
  exit1Ir,
  pauseIr,
  exit2Ir,
  updateIr,
}

/// A software JTAG TAP + Debug Transport Module. It runs the standard TAP
/// finite state machine, shifts the IR and the per-instruction DRs (LSB-first),
/// and bridges the DMI access instruction to a [SoftDebugModule].
///
/// Instructions (IR width 5, RISC-V convention): IDCODE=0x01, DTMCS=0x10,
/// DMI=0x11, BYPASS=0x1F. The DMI data register is `abits + 34` = 41 bits:
/// `{address[6:0], data[31:0], op[1:0]}`.
class SoftJtagDtm {
  final SoftDebugModule dm;
  final int idcode;
  final int irWidth;

  static const int abits = 7;
  static const int dmiWidth = abits + 34; // 41

  TapState _state = TapState.testLogicReset;
  int _ir = 0x01; // IDCODE is the reset default (IEEE 1149.1)
  int _irShift = 0;
  int _dr = 0;
  int _drLen = 1;

  // Latched result of the previous DMI transaction (captured on the next scan).
  int _dmiData = 0;
  int _dmiAddr = 0;
  int _dmiStatus = DmiStatus.success;

  SoftJtagDtm(this.dm, {this.idcode = 0x10000001, this.irWidth = 5});

  /// The current TDO value (0/1) presented to the host. Combinational: it is
  /// the shift register's current LSB so a host that samples TDO while TCK is
  /// low (the OpenOCD remote_bitbang convention) reads the bit that the next
  /// rising edge will shift out. Latching it inside [clock] instead presents it
  /// one clock late (IDCODE comes back as `idcode << 1`).
  int get tdo {
    if (_state == TapState.shiftIr) return _irShift & 1;
    if (_state == TapState.shiftDr) return _dr & 1;
    return 0;
  }

  TapState get state => _state;

  void reset() {
    _state = TapState.testLogicReset;
    _ir = 0x01;
  }

  /// Advance one TCK rising edge with the given TMS and TDI pin levels.
  Future<void> clock(int tms, int tdi) async {
    // While shifting, shift TDI in at the MSB. TDO is presented combinationally
    // by the [tdo] getter (the current LSB), read by the host before this edge.
    if (_state == TapState.shiftIr) {
      _irShift = (_irShift >> 1) | ((tdi & 1) << (irWidth - 1));
    } else if (_state == TapState.shiftDr) {
      _dr = (_dr >> 1) | ((tdi & 1) << (_drLen - 1));
    }

    final next = _nextState(_state, tms & 1);
    switch (next) {
      case TapState.testLogicReset:
        _ir = 0x01;
      case TapState.captureIr:
        _irShift = 0x01; // low two bits read back as 01 per spec
      case TapState.updateIr:
        _ir = _irShift & ((1 << irWidth) - 1);
      case TapState.captureDr:
        _loadDr();
      case TapState.updateDr:
        await _updateDr();
      default:
        break;
    }
    _state = next;
  }

  void _loadDr() {
    switch (_ir) {
      case 0x01: // IDCODE
        _dr = idcode & 0xFFFFFFFF;
        _drLen = 32;
      case 0x10: // DTMCS
        _dr = _dtmcs();
        _drLen = 32;
      case 0x11: // DMI: present the previous transaction's result.
        _dr =
            (_dmiAddr << 34) |
            ((_dmiData & 0xFFFFFFFF) << 2) |
            (_dmiStatus & 0x3);
        _drLen = dmiWidth;
      default: // BYPASS
        _dr = 0;
        _drLen = 1;
    }
  }

  int _dtmcs() =>
      1 | // version = 1 (debug 0.13)
      (abits << 4) | // abits = 7
      (_dmiStatus << 10) | // dmistat
      (1 << 12); // idle hint

  Future<void> _updateDr() async {
    if (_ir == 0x10) {
      // DTMCS write: dmireset (bit16) / dmihardreset (bit17) clear sticky state.
      if (((_dr >> 16) & 1) == 1 || ((_dr >> 17) & 1) == 1) {
        _dmiStatus = DmiStatus.success;
      }
    } else if (_ir == 0x11) {
      final op = _dr & 0x3;
      final data = (_dr >> 2) & 0xFFFFFFFF;
      _dmiAddr = (_dr >> 34) & ((1 << abits) - 1);
      if (op == DmiOp.read.index) {
        _dmiData = await dm.dmiRead(_dmiAddr);
        _dmiStatus = DmiStatus.success;
      } else if (op == DmiOp.write.index) {
        await dm.dmiWrite(_dmiAddr, data);
        _dmiStatus = DmiStatus.success;
      }
    }
  }

  TapState _nextState(TapState s, int tms) => switch (s) {
    TapState.testLogicReset =>
      tms == 1 ? TapState.testLogicReset : TapState.runTestIdle,
    TapState.runTestIdle => tms == 1 ? TapState.selectDr : TapState.runTestIdle,
    TapState.selectDr => tms == 1 ? TapState.selectIr : TapState.captureDr,
    TapState.captureDr => tms == 1 ? TapState.exit1Dr : TapState.shiftDr,
    TapState.shiftDr => tms == 1 ? TapState.exit1Dr : TapState.shiftDr,
    TapState.exit1Dr => tms == 1 ? TapState.updateDr : TapState.pauseDr,
    TapState.pauseDr => tms == 1 ? TapState.exit2Dr : TapState.pauseDr,
    TapState.exit2Dr => tms == 1 ? TapState.updateDr : TapState.shiftDr,
    TapState.updateDr => tms == 1 ? TapState.selectDr : TapState.runTestIdle,
    TapState.selectIr =>
      tms == 1 ? TapState.testLogicReset : TapState.captureIr,
    TapState.captureIr => tms == 1 ? TapState.exit1Ir : TapState.shiftIr,
    TapState.shiftIr => tms == 1 ? TapState.exit1Ir : TapState.shiftIr,
    TapState.exit1Ir => tms == 1 ? TapState.updateIr : TapState.pauseIr,
    TapState.pauseIr => tms == 1 ? TapState.exit2Ir : TapState.pauseIr,
    TapState.exit2Ir => tms == 1 ? TapState.updateIr : TapState.shiftIr,
    TapState.updateIr => tms == 1 ? TapState.selectDr : TapState.runTestIdle,
  };
}
