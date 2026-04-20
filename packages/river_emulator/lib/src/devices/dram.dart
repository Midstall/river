import 'dart:async';
import 'package:river/river.dart';

import '../dev.dart';
import '../soc.dart';

/// DRAM model with an optional CPU-driven read-training control window, mirroring
/// the HDL [HarborDdrController] trainable path. When [trainable], an MMIO
/// register window sits just above the array (offsets `>= [arraySize]`). The
/// array is unusable until the read tap is walked into the valid eye:
///   0x00 RDTAP_TARGET (RW, 7b)  tap the controller walks to
///   0x08 CTL          (W)       [0] SET (walk to target), [1] LOAD (reload 0)
///   0x10 RDSLACK      (RW)      runtime read-window slack
///   0x18 STATUS       (RO)      [0] busy (always 0, instant walk), [8:1] tap
/// Array reads are correct only while `currentTap` is in [[eyeLo], [eyeHi]];
/// outside the eye a read returns a deterministically wrong value so a training
/// sweep can find it. Writes always land (read training, not write training).
class Dram extends Device {
  /// Size of the training control-register window above the array (matches the
  /// HDL [HarborDdrController.trainCtrlSize]).
  static const int trainCtrlSize = 0x1000;

  // Register indices within the control window (8-byte strided for 64-bit-bus
  // lane alignment, matching the HDL).
  static const int _regRdTap = 0;
  static const int _regCtl = 1;
  static const int _regRdSlack = 2;
  static const int _regStatus = 3;
  static const int _regMpr = 4; // MPRCTL (0x20): bit0 = MPR mode

  /// The fixed multi-purpose-register pattern a DDR3 part returns in MPR mode
  /// (what a read-training read sees instead of array data). Matches Weir's
  /// FSBL (src/fsbl/ddr.zig MPR_PATTERN).
  static const int _mprPattern = 0xFFFF0000;

  final bool trainable;
  final int arraySize;
  final int eyeLo;
  final int eyeHi;

  List<int> data;

  int currentTap = 0;
  int targetTap = 0;
  int rdSlack = 1;

  /// MPR (multi-purpose register) read-training mode. A trainable part boots in
  /// MPR mode so a sweep that has not written real data yet reads the fixed
  /// training pattern; the first real array WRITE drops it (the controller is
  /// now serving array data). Software can also toggle it via MPRCTL.
  bool mprMode;

  Dram(super.config, {this.trainable = false, this.eyeLo = 8, this.eyeHi = 40})
    : arraySize = trainable
          ? config.range!.size - trainCtrlSize
          : config.range!.size,
      data = List.filled(
        trainable ? config.range!.size - trainCtrlSize : config.range!.size,
        0,
      ),
      mprMode = trainable;

  /// True when the read tap sits inside the valid eye, so array reads are
  /// reliable. Untrainable DRAM is always reliable.
  bool get trained =>
      !trainable || (currentTap >= eyeLo && currentTap <= eyeHi);

  @override
  void reset() {
    data.fillRange(0, data.length, 0);
    currentTap = 0;
    targetTap = 0;
    rdSlack = 1;
    mprMode = trainable;
  }

  @override
  DeviceAccessor? get memAccessor => DramAccessor(this);

  static Device create(
    RiverDevice config,
    Map<String, String> options,
    RiverSoC soc,
  ) {
    final trainable = options.containsKey('train');
    return Dram(
      config,
      trainable: trainable,
      eyeLo: int.tryParse(options['eye-lo'] ?? '') ?? 8,
      eyeHi: int.tryParse(options['eye-hi'] ?? '') ?? 40,
    );
  }
}

class DramAccessor extends DeviceAccessor {
  final Dram dram;

  DramAccessor(this.dram);

  bool _isCtrl(int addr) => dram.trainable && addr >= dram.arraySize;

  int _widthMask(int width) =>
      width >= 8 ? -1 : (1 << (8 * width)) - 1; // -1 == all 64 bits set

  @override
  Future<int> read(int addr, int width) async {
    if (_isCtrl(addr)) {
      final reg = (addr - dram.arraySize) >> 3;
      switch (reg) {
        case Dram._regRdTap:
          return dram.targetTap;
        case Dram._regRdSlack:
          return dram.rdSlack;
        case Dram._regStatus:
          // [0] busy (instant walk -> always 0), [8:1] current tap.
          return dram.currentTap << 1;
        case Dram._regMpr:
          return dram.mprMode ? 1 : 0;
        default:
          return 0;
      }
    }

    // Array read. In MPR (read-training) mode the part returns its fixed MPR
    // pattern instead of array data; otherwise it returns what was stored.
    int value;
    if (dram.mprMode) {
      value = width >= 8
          ? (Dram._mprPattern << 32) | Dram._mprPattern
          : Dram._mprPattern & _widthMask(width);
    } else {
      if (addr + width > dram.data.length) return 0;
      value = 0;
      for (int i = 0; i < width; i++) {
        value |= (dram.data[addr + i] & 0xFF) << (8 * i);
      }
    }
    // Outside the read eye the captured data is garbage: corrupt it
    // deterministically so a training sweep can tell a bad tap from a good one.
    if (!dram.trained) value = (~value) & _widthMask(width);
    return value;
  }

  @override
  Future<void> write(int addr, int value, int width) async {
    if (_isCtrl(addr)) {
      final reg = (addr - dram.arraySize) >> 3;
      switch (reg) {
        case Dram._regRdTap:
          dram.targetTap = value & 0x7F;
          break;
        case Dram._regCtl:
          if (value & 0x1 != 0) dram.currentTap = dram.targetTap; // SET (walk)
          if (value & 0x2 != 0) dram.currentTap = 0; // LOAD (reload)
          break;
        case Dram._regRdSlack:
          dram.rdSlack = value & 0x7;
          break;
        case Dram._regMpr:
          dram.mprMode = value & 0x1 != 0;
          break;
        // STATUS is read-only.
      }
      return;
    }

    // The first real array write takes the part out of MPR/training mode (it is
    // now serving array data). Writes always land (read training does not
    // corrupt the write path).
    dram.mprMode = false;
    if (addr + width > dram.data.length) return;
    for (int i = 0; i < width; i++) {
      final byte = (value >> (8 * i)) & 0xFF;
      dram.data[addr + i] = byte;
    }
  }
}
