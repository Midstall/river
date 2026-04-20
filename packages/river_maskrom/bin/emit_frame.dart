import 'dart:io';

import 'package:river/river.dart';
import 'package:river_maskrom/river_maskrom.dart';

/// Emit a serial-monitor load frame (len_lo len_hi payload checksum) for a
/// sample [RiverHelloWorld] payload, as one hex byte per line (for
/// `$readmemh` in a testbench), plus the raw payload as a sibling `.bin`
/// for sending to real hardware with river_load.
/// Usage: `dart run river_maskrom:emit_frame [out.hex] [ram] [uart] [clockHz]`
/// The payload prints from RAM, so its data buffer sits 32KB above its code
/// (inside even the smallest 64KB board RAM).
/// clockHz must match the TARGET BOARD (the payload re-derives the UART
/// divisor from it): 12000000 for the iCESugar, 48000000 for the OrangeCrab.
Future<void> main(List<String> args) async {
  final out = args.isNotEmpty ? args[0] : '/tmp/frame.hex';
  final ram = args.length > 1 ? int.parse(args[1]) : 0x80000000;
  final uart = args.length > 2 ? int.parse(args[2]) : 0x10000000;
  final clockHz = args.length > 3 ? int.parse(args[3]) : 12000000;

  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  final payloadProg = RiverHelloWorld(
    isa: isa,
    uartBase: uart,
    ramBase:
        ram + 0x8000, // data buffer 32KB up, clear of code, within 64KB RAMs
    clockHz: clockHz,
    message: 'Hi from RAM!\r\n',
  );
  await payloadProg.build();
  final payload = payloadProg.generateBytes();

  final sum = payload.fold<int>(0, (a, b) => (a + b) & 0xff);
  final frame = [
    payload.length & 0xff,
    (payload.length >> 8) & 0xff,
    ...payload,
    sum,
  ];
  await File(out).writeAsString(
    frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('\n'),
  );
  // The raw payload alongside, for sending to real hardware via river_load.
  final binOut = out.replaceAll(RegExp(r'\.hex$'), '.bin');
  await File(binOut == out ? '$out.bin' : binOut).writeAsBytes(payload);
  stdout.writeln(
    'wrote $out (+ payload .bin): ${payload.length}-byte payload, checksum '
    '0x${sum.toRadixString(16)}, frame ${frame.length} bytes',
  );
}
