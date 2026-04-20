import 'dart:async';
import 'dart:io';
import 'package:river/river.dart';
import '../dev.dart';
import '../soc.dart';

class Uart extends Device {
  final Stream<List<int>> input;
  final StreamSink<List<int>> output;

  final List<int> _rxFifo = [];
  final List<int> _txFifo = [];
  bool _txPending = false;

  int dll = 0;
  int dlm = 0;
  int ier = 0;
  int iir = 0x01;
  int lcr = 0;
  int mcr = 0;
  int lsr = 0x60;
  int msr = 0;
  int scr = 0;
  int fcr = 0;

  Uart(super.config, {required this.input, required this.output}) {
    input.listen((data) {
      _rxFifo.addAll(data);
      _updateLineStatus();
      _updateIIR();
    });
  }

  bool get dlab => (lcr & 0x80) != 0;

  int get divisor => (dlm << 8) | dll;

  int get baud {
    if (divisor == 0) return 0;
    return (config.clockFrequency ?? 0) ~/ divisor;
  }

  void _updateLineStatus() {
    lsr = 0;

    if (_rxFifo.isNotEmpty) lsr |= 0x01;
    if (_txFifo.isEmpty) lsr |= 0x20;

    lsr |= 0x40;
  }

  Future<void> flush() async {
    while (_txFifo.isNotEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
  }

  void _updateIIR() {
    if ((ier & 0x04) != 0 && (_lineStatusInterrupt())) {
      iir = 0x06;
      return;
    }

    if ((ier & 0x01) != 0 && _rxFifo.isNotEmpty) {
      iir = 0x04;
      return;
    }

    if ((ier & 0x02) != 0 && (_txFifo.isEmpty)) {
      iir = 0x02;
      return;
    }

    iir = 0x01;
  }

  bool _lineStatusInterrupt() {
    return false;
  }

  Duration txDelay() {
    if (baud == 0) return Duration.zero;
    final seconds = 10 / baud;
    return Duration(microseconds: (seconds * 1e6).toInt());
  }

  int _readRBR() {
    if (_rxFifo.isEmpty) {
      return 0;
    }
    final byte = _rxFifo.removeAt(0);
    _updateLineStatus();
    _updateIIR();
    return byte;
  }

  void _writeTHR(int value) {
    _txFifo.add(value & 0xFF);
    _updateLineStatus();
    _updateIIR();
    _scheduleNextTx();
  }

  void _scheduleNextTx() {
    // Only one drain may be in flight; otherwise multiple timers race and
    // capture a stale head, dropping/duplicating bytes.
    if (_txPending || _txFifo.isEmpty) return;
    _txPending = true;

    Future.delayed(txDelay(), () {
      _txPending = false;
      if (_txFifo.isEmpty) return;

      final byte = _txFifo.removeAt(0);
      output.add([byte]);

      _updateLineStatus();
      _updateIIR();

      _scheduleNextTx();
    });
  }

  @override
  Map<int, bool> interrupts(int hart) {
    final pending = (iir & 0x01) == 0;
    return {0: pending};
  }

  @override
  void reset() {
    dll = 0;
    dlm = 0;
    ier = 0;
    iir = 0x01;
    lcr = 0;
    mcr = 0;
    lsr = 0x60;
    msr = 0;
    scr = 0;
    fcr = 0;

    _rxFifo.clear();
    _txFifo.clear();
  }

  @override
  DeviceAccessor? get memAccessor => UartAccessor(this);

  static Device create(
    RiverDevice config,
    Map<String, String> options,
    RiverSoC soc,
  ) {
    Stream<List<int>>? input;
    StreamSink<List<int>>? output;

    if (options.containsKey('path')) {
      final file = File(options['path']!);
      input = file.openRead();
      output = file.openWrite();
    }

    if (options.containsKey('input.path')) {
      final file = File(options['input.path']!);
      input = file.openRead();
    } else if (options.containsKey('input.string')) {
      input = Stream.value(options['input.string']!.codeUnits);
    } else if (options.containsKey('input.empty')) {
      input = Stream.empty();
    }

    if (options.containsKey('output.path')) {
      final file = File(options['output.path']!);
      output = file.openWrite();
    } else if (options.containsKey('output.empty')) {
      output = StreamController<List<int>>().sink;
    }

    if (input == null) {
      if (stdioType(stdin) == StdioType.terminal) {
        stdin.echoMode = false;
        stdin.lineMode = false;
      }
      input = stdin;
    }

    return Uart(config, input: input, output: output ?? stdout);
  }
}

class UartAccessor extends DeviceAccessor {
  final Uart device;

  UartAccessor(this.device) : super(type: DeviceAccessorType.io);

  @override
  Future<int> read(int addr, int width) async {
    // NS16550A register map (1 byte each)
    switch (addr) {
      case 0: // RBR/DLL
        await Future<void>.delayed(Duration.zero);
        return device.dlab ? device.dll : device._readRBR();
      case 1: // IER/DLM
        return device.dlab ? device.dlm : device.ier;
      case 2: // IIR
        return device.iir | (device.fcr & 0xC0);
      case 3: // LCR
        return device.lcr;
      case 4: // MCR
        return device.mcr;
      case 5: // LSR
        await Future<void>.delayed(Duration.zero);
        return device.lsr;
      case 6: // MSR
        return device.msr;
      case 7: // SCR
        return device.scr;
      default:
        return 0;
    }
  }

  @override
  Future<void> write(int addr, int value, int width) async {
    value &= 0xFF;

    switch (addr) {
      case 0: // THR/DLL
        if (device.dlab) {
          device.dll = value;
        } else {
          device._writeTHR(value);
        }
      case 1: // IER/DLM
        if (device.dlab) {
          device.dlm = value;
        } else {
          device.ier = value;
        }
        device._updateIIR();
      case 2: // FCR
        device.fcr = value;
        if ((value & 0x02) != 0) device._rxFifo.clear();
        if ((value & 0x04) != 0) device._txFifo.clear();
        device._updateLineStatus();
        device._updateIIR();
      case 3: // LCR
        device.lcr = value;
        device._updateLineStatus();
      case 4: // MCR
        device.mcr = value;
      case 7: // SCR
        device.scr = value;
    }
  }
}
