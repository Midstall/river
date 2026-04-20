import 'dart:io';

import 'package:river/river.dart';
import 'package:river_maskrom/river_maskrom.dart';

/// Emit the hello-world demo as an ELF for emulator/HDL testing.
/// Usage: `dart run river_maskrom:emit_hello [out.elf] [entry] [ram] [uart]`
/// (all addresses are integers, e.g. 0x80000000).
Future<void> main(List<String> args) async {
  final out = args.isNotEmpty ? args[0] : '/tmp/hello.elf';
  final entry = args.length > 1 ? int.parse(args[1]) : 0x80000000;
  final ram = args.length > 2 ? int.parse(args[2]) : 0x80008000;
  final uart = args.length > 3 ? int.parse(args[3]) : 0x10000000;

  final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);
  final prog = RiverHelloWorld(isa: isa, uartBase: uart, ramBase: ram);
  await prog.build();
  await File(out).writeAsBytes(prog.emitElfBytes(entryPoint: entry));
  stdout.writeln(
    'wrote $out (entry=0x${entry.toRadixString(16)}, '
    'ram=0x${ram.toRadixString(16)}, uart=0x${uart.toRadixString(16)})',
  );
}
