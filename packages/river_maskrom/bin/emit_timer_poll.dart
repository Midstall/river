import 'dart:io';

import 'package:river/river.dart';
import 'package:river_maskrom/river_maskrom.dart';

/// Emit the CLINT polling demo as a monitor payload: a raw `.bin` for
/// `river_load`, plus a `.hex` frame for testbenches.
/// Usage: `dart run river_maskrom:emit_timer_poll [out_base] [tickHz] [ticks]`
/// (out_base defaults to /tmp/timer_poll; tickHz to 12000000 = one-second
/// ticks at 12MHz, use a small value like 50000 for simulation).
Future<void> main(List<String> args) async {
  final base = args.isNotEmpty ? args[0] : '/tmp/timer_poll';
  final tickHz = args.length > 1 ? int.parse(args[1]) : 12000000;
  final ticks = args.length > 2 ? int.parse(args[2]) : 5;

  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  final prog = RiverTimerPollDemo(
    isa: isa,
    uartBase: 0x10000000,
    clintBase: 0x02000000,
    tickHz: tickHz,
    ticks: ticks,
  );
  await prog.build();
  final payload = prog.generateBytes();

  final sum = payload.fold<int>(0, (a, b) => (a + b) & 0xff);
  final frame = [
    payload.length & 0xff,
    (payload.length >> 8) & 0xff,
    ...payload,
    sum,
  ];
  await File('$base.bin').writeAsBytes(payload);
  await File('$base.hex').writeAsString(
    frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('\n'),
  );
  stdout.writeln(
    'wrote $base.bin / $base.hex: ${payload.length}-byte payload, '
    '${frame.length}-byte frame, tickHz=$tickHz, ticks=$ticks',
  );
}
