import 'dart:async' show unawaited;
import 'dart:io' show Platform, File, stdout;

import 'package:args/args.dart';
import 'package:bintools/bintools.dart';
import 'package:path/path.dart' as path;
import 'package:river/river.dart';
import 'package:river_emulator/river_emulator.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addMultiOption(
      'core',
      abbr: 'c',
      help: 'Core model',
      defaultsTo: ['rc1-mi'],
      allowed: ['rc1-n', 'rc1-mi', 'rc1-s', 'rc1-m'],
    )
    ..addMultiOption(
      'memory',
      abbr: 'm',
      help: 'Memory region (name:addr:size:type)',
    )
    ..addMultiOption(
      'device',
      abbr: 'd',
      help: 'Peripheral device (name:type:addr[:compat])',
    )
    ..addOption(
      'clock-freq',
      help: 'System clock frequency (Hz)',
      defaultsTo: '48000000',
    )
    ..addMultiOption(
      'device-option',
      help: 'Device option (device.key=value)',
      splitCommas: false,
    )
    ..addOption(
      'maskrom-path',
      help: 'Path to the binary to load into the maskrom (L1 cache)',
    )
    ..addOption(
      'firmware',
      help: 'Path to an ELF to load into memory (e.g. OpenSBI fw_jump.elf)',
    )
    ..addOption(
      'payload',
      help:
          'Path to an ELF to load into memory after firmware (e.g. Linux kernel)',
    )
    ..addOption(
      'max-cycles',
      help: 'Stop after this many cycles (0 = run forever)',
      defaultsTo: '0',
    )
    ..addFlag(
      'remote-bitbang',
      help: 'Expose core 0 over an OpenOCD remote_bitbang JTAG debug server',
    )
    ..addOption(
      'remote-bitbang-port',
      help: 'TCP port for the remote_bitbang debug server',
      defaultsTo: '${RemoteBitbangServer.defaultPort}',
    )
    ..addFlag(
      'start-halted',
      help:
          'Start the hart halted (waiting for the debugger) instead of '
          'free-running from reset. Use with --remote-bitbang so a debugger '
          'or Heimdall can attach before the core runs.',
    )
    ..addFlag('help', abbr: 'h', help: 'Prints usage');

  final args = parser.parse(arguments);

  if (args.flag('help')) {
    print('Usage: ${path.basename(Platform.script.toFilePath())} [options]');
    print('');
    print('River SoC emulator');
    print('');
    print('Options:');
    print(parser.usage);
    return;
  }

  final clockFreq = int.parse(args.option('clock-freq')!);
  final sysclk = HarborClockConfig(
    name: 'sysclk',
    rate: HarborFixedClockRate(clockFreq),
  );

  final coreModels = {
    'rc1-n': RiverCoreConfigV1.nano,
    'rc1-mi': RiverCoreConfigV1.micro,
    'rc1-s': RiverCoreConfigV1.small,
    'rc1-m': RiverCoreConfigV1.macro,
  };

  // Parse memory regions: name:addr:size:type
  final memories = args.multiOption('memory').map((spec) {
    final parts = spec.split(':');
    if (parts.length < 4) {
      throw FormatException('Memory format: name:addr:size:type, got: $spec');
    }
    return RiverDevice(
      name: parts[0],
      compatible: 'river,${parts[3]}',
      range: BusAddressRange(int.parse(parts[1]), _parseSize(parts[2])),
    );
  }).toList();

  // Parse devices: name:type:addr[:compat]
  final devices = args.multiOption('device').map((spec) {
    final parts = spec.split(':');
    if (parts.length < 3) {
      throw FormatException(
        'Device format: name:type:addr[:compat], got: $spec',
      );
    }
    final type = parts[1];
    final defaultCompat = {
      'uart': 'ns16550a',
      'clint': 'riscv,clint0',
      'plic': 'riscv,plic0',
    };
    final defaultSizes = {'clint': 0x10000, 'plic': 0x4000000, 'uart': 0x8};
    return RiverDevice(
      name: parts[0],
      compatible: parts.length > 3
          ? parts[3]
          : (defaultCompat[type] ?? 'river,$type'),
      range: BusAddressRange(int.parse(parts[2]), defaultSizes[type] ?? 0x1000),
    );
  }).toList();

  // Determine mxlen from first core
  final firstCoreModel = args.multiOption('core').first;
  final mxlen = (firstCoreModel == 'rc1-n' || firstCoreModel == 'rc1-mi')
      ? RiscVMxlen.rv32
      : RiscVMxlen.rv64;

  final mmu = HarborMmuConfig(
    mxlen: mxlen,
    pagingModes: mxlen == RiscVMxlen.rv64
        ? const [RiscVPagingMode.bare, RiscVPagingMode.sv39]
        : const [RiscVPagingMode.bare],
    tlbLevels: const [],
    pmp: HarborPmpConfig.none,
  );

  final resetVector = memories.isNotEmpty ? memories.first.range!.start : 0;

  final cores = args.multiOption('core').map((coreModel) {
    final factory = coreModels[coreModel];
    if (factory == null) throw ArgumentError('Unknown core model: $coreModel');
    return factory(
      mmu: mmu,
      interrupts: [],
      clock: sysclk,
      resetVector: resetVector,
    );
  }).toList();

  final socConfig = RiverSoCConfig(
    devices: [...memories, ...devices],
    cores: cores,
    busConfig: WishboneConfig(
      addressWidth: mxlen.size,
      dataWidth: mxlen.size,
      selWidth: mxlen.size ~/ 8,
    ),
  );

  // Parse device options: device.key=value
  final deviceOptions = <String, Map<String, String>>{};
  for (final option in args.multiOption('device-option')) {
    final dot = option.indexOf('.');
    if (dot < 0) {
      throw FormatException(
        'Device option format: device.key=value, got: $option',
      );
    }
    final devName = option.substring(0, dot);
    final rest = option.substring(dot + 1);
    final eq = rest.indexOf('=');
    if (eq < 0) {
      throw FormatException(
        'Device option format: device.key=value, got: $option',
      );
    }
    deviceOptions.putIfAbsent(devName, () => {})[rest.substring(0, eq)] = rest
        .substring(eq + 1);
  }

  final emulator = RiverEmulator(
    soc: RiverSoC(socConfig, deviceOptions: deviceOptions),
  );

  emulator.reset();

  final maskromPath = args.option('maskrom-path');

  if (maskromPath != null) {
    final maskrom = Elf.load(File(maskromPath).readAsBytesSync());
    await emulator.soc.loadMaskrom(maskrom);

    final coreResetVector = emulator.soc.cores[0].config.resetVector;
    if (maskrom.header.entry != coreResetVector) {
      print(
        'WARNING: ELF entry is 0x${maskrom.header.entry.toRadixString(16)}, '
        'but core reset vector is 0x${coreResetVector.toRadixString(16)}',
      );
    }
  } else if (emulator.soc.cores[0].l1i != null) {
    print('Maskrom binary is required');
    return;
  }

  final firmwarePath = args.option('firmware');
  if (firmwarePath != null) {
    final fw = Elf.load(File(firmwarePath).readAsBytesSync());
    emulator.soc.loadElf(fw);
    print(
      'Loaded firmware: ${fw.programHeaders.where((ph) => ph.type == 1).length} segments, '
      'entry 0x${fw.header.entry.toRadixString(16)}',
    );
  }

  final payloadPath = args.option('payload');
  if (payloadPath != null) {
    final payload = Elf.load(File(payloadPath).readAsBytesSync());
    emulator.soc.loadElf(payload);
    print(
      'Loaded payload: ${payload.programHeaders.where((ph) => ph.type == 1).length} segments, '
      'entry 0x${payload.header.entry.toRadixString(16)}',
    );
  }

  final maxCycles = int.parse(args.option('max-cycles')!);

  // Optional JTAG debug server: lets OpenOCD / Heimdall halt and inspect core 0
  // over the OpenOCD remote_bitbang protocol, the same path used for the HDL
  // sim and silicon.
  RiverDebugTarget? debug;
  if (args.flag('remote-bitbang')) {
    final port = int.parse(args.option('remote-bitbang-port')!);
    debug = RiverDebugTarget(emulator.soc.cores[0]);
    final server = RemoteBitbangServer(
      SoftJtagDtm(SoftDebugModule(debug)),
      port: port,
    );
    await server.bind();
    unawaited(server.serve());
    // With --start-halted the hart waits for the debugger instead of
    // free-running from the reset vector into a fault before the (slow) examine
    // connects. This makes the emulator a stable DUT for Heimdall (load/run via
    // JTAG), matching how a real debug target comes up with a pending halt.
    if (args.flag('start-halted')) {
      debug.requestHalt();
      debug.dpc = resetVector;
    }
    print('remote_bitbang debug server listening on port ${server.boundPort}');
  }

  Map<int, int> pcs = {};
  var cycle = 0;
  final dbgHartId = debug != null ? emulator.soc.cores[0].config.hartId : 0;
  var prevHalted = debug?.halted ?? false;
  // Instructions retired since we last handed control back to the event loop.
  // soc.run's awaits all complete in-memory (no real I/O), so without an
  // explicit yield the Dart scheduler keeps draining microtasks and never
  // services the JTAG remote_bitbang socket. A loaded program that runs without
  // faulting then starves the socket: the debugger's halt request sits unread
  // and the rig wedges until the RPC times out. Pump the event loop every so
  // often so an incoming halt is seen promptly while staying fast otherwise.
  var sinceYield = 0;
  const yieldEvery = 256;
  while (maxCycles == 0 || cycle < maxCycles) {
    final nowHalted = debug != null && debug.halted;
    // On a halt/resume edge, sync dpc with the run loop's per-core PC: save the
    // hart's PC into dpc when it stops, and resume from dpc (which the debugger
    // may have rewritten, e.g. the fuzzer setting each program's entry).
    if (debug != null && nowHalted != prevHalted) {
      if (nowHalted) {
        debug.dpc = pcs[dbgHartId] ?? resetVector;
      } else {
        pcs[dbgHartId] = debug.dpc;
      }
      prevHalted = nowHalted;
    }
    // While the debugger holds the hart halted, idle instead of retiring.
    if (nowHalted) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      continue;
    }
    if (debug != null) {
      // A debug target must not crash the process when the running program
      // faults (e.g. a random fuzz program that double-faults with mtvec=0).
      // Halt so the debugger / Heimdall observes the faulted state and can load
      // the next program, the way real silicon stays alive under the debugger.
      try {
        pcs = await emulator.soc.run(pcs);
      } catch (e) {
        debug.requestHalt();
        print('hart faulted, halting for debugger: $e');
      }
      // Yield to the event loop periodically so the JTAG socket is serviced
      // even while a program runs straight-line without faulting; otherwise an
      // incoming halt request is never read and the debug session wedges.
      if (++sinceYield >= yieldEvery) {
        sinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    } else {
      pcs = await emulator.soc.run(pcs);
    }
    cycle++;
  }

  // Let any in-flight UART transmits drain, then flush stdout so output is
  // not lost when we exit.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await stdout.flush();
}

int _parseSize(String s) {
  final upper = s.toUpperCase();
  if (upper.endsWith('M')) {
    return int.parse(upper.substring(0, upper.length - 1)) * 1024 * 1024;
  }
  if (upper.endsWith('K')) {
    return int.parse(upper.substring(0, upper.length - 1)) * 1024;
  }
  return int.parse(s);
}
