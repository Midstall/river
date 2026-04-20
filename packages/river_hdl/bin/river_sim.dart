import 'dart:async';
import 'dart:io' show Platform, File, exit, stdout;

import 'package:args/args.dart';
import 'package:bintools/bintools.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' hide DataPortInterface, DataPortGroup;
import 'package:river/river.dart';
import 'package:river_hdl/river_hdl.dart';

String elfToMemString(Elf elf, int dataWidth) {
  final segments = elf.programHeaders.where((ph) => ph.type == 1).toList();
  final buf = StringBuffer();

  for (final ph in segments) {
    final data = elf.segmentData(ph);
    if (data.isEmpty) continue;

    buf.writeln('@${ph.pAddr.toRadixString(16)}');

    for (var i = 0; i < data.length; i++) {
      buf.write(data[i].toRadixString(16).padLeft(2, '0'));
      if ((i + 1) % 16 == 0) {
        buf.writeln();
      } else {
        buf.write(' ');
      }
    }

    if (ph.memSize > ph.fileSize) {
      for (var i = ph.fileSize; i < ph.memSize; i++) {
        buf.write('00');
        if ((i + 1) % 16 == 0) {
          buf.writeln();
        } else {
          buf.write(' ');
        }
      }
    }

    buf.writeln();
  }

  return buf.toString();
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addMultiOption(
      'core',
      abbr: 'c',
      help: 'Core model',
      defaultsTo: ['rc1-mi'],
      allowed: ['rc1-n', 'rc1-mi', 'rc1-s', 'rc1-m'],
    )
    ..addOption(
      'clock-freq',
      help: 'System clock frequency (Hz)',
      defaultsTo: '48000000',
    )
    ..addOption('maskrom-path', help: 'Path to an ELF to load into the maskrom')
    ..addOption('firmware', help: 'Path to an ELF to load into memory')
    ..addOption('payload', help: 'Path to an ELF to load after firmware')
    ..addOption(
      'max-cycles',
      help: 'Maximum simulation cycles',
      defaultsTo: '0',
    )
    ..addFlag(
      'remote-bitbang',
      help: 'Expose the core over an OpenOCD remote_bitbang JTAG debug server',
    )
    ..addOption(
      'remote-bitbang-port',
      help: 'TCP port for the remote_bitbang debug server',
      defaultsTo: '44853',
    )
    ..addOption(
      'log',
      help: 'Log level',
      allowed: Level.LEVELS.map((v) => v.name.toLowerCase()).toList(),
    )
    ..addFlag(
      'debug-trace',
      help: 'Log debug-halt/request/SBA line transitions (remote-bitbang)',
    )
    ..addFlag('trace', help: 'Print a per-cycle PC/state trace')
    ..addOption(
      'resume-budget',
      help:
          'Max core clocks to free-run on a debug RESUME edge before '
          'falling back to one-clock-per-bit',
      defaultsTo: '2000000',
    )
    ..addFlag('help', abbr: 'h', help: 'Prints usage');

  final args = parser.parse(arguments);

  if (args.flag('help')) {
    print('Usage: ${path.basename(Platform.script.toFilePath())} [options]');
    print('');
    print('River HDL simulator');
    print('');
    print('Options:');
    print(parser.usage);
    return;
  }

  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  if (args.option('log') != null) {
    Logger.root.level = Level.LEVELS.firstWhere(
      (v) => v.name.toLowerCase() == args.option('log'),
    );
  }

  final coreModels = {
    'rc1-n': RiverCoreConfigV1.nano,
    'rc1-mi': RiverCoreConfigV1.micro,
    'rc1-s': RiverCoreConfigV1.small,
    'rc1-m': RiverCoreConfigV1.macro,
  };

  // --core matches the emulator/genip surface (multi-option), but the sim builds
  // a single core; if several are given it simulates the first and says so.
  final coreList = args.multiOption('core');
  if (coreList.length > 1) {
    print(
      'Note: sim builds a single core; using the first (${coreList.first})',
    );
  }
  final coreModel = coreList.first;
  final factory = coreModels[coreModel];
  if (factory == null) {
    print('Unknown core model: $coreModel');
    return;
  }

  final mxlen = (coreModel == 'rc1-n' || coreModel == 'rc1-mi')
      ? RiscVMxlen.rv32
      : RiscVMxlen.rv64;

  final sysclk = HarborClockConfig(
    name: 'sysclk',
    rate: HarborFixedClockRate(int.parse(args.option('clock-freq')!)),
  );

  final coreConfig = factory(
    interrupts: [],
    mmu: HarborMmuConfig(
      mxlen: mxlen,
      pagingModes: mxlen == RiscVMxlen.rv64
          ? const [RiscVPagingMode.bare, RiscVPagingMode.sv39]
          : const [RiscVPagingMode.bare],
      tlbLevels: const [],
      pmp: HarborPmpConfig.none,
    ),
    clock: sysclk,
    resetVector: 0,
  );

  final addrWidth = coreConfig.mxlen.size;

  final clk = SimpleClockGenerator(20).clk;
  final reset = Logic();

  final wbConfig = WishboneConfig(
    addressWidth: addrWidth,
    dataWidth: coreConfig.mxlen.size,
    selWidth: coreConfig.mxlen.size ~/ 8,
  );

  final storage = SparseMemoryStorage(
    addrWidth: addrWidth,
    dataWidth: coreConfig.mxlen.size,
    alignAddress: (addr) => addr,
    onInvalidRead: (addr, dataWidth) =>
        LogicValue.filled(dataWidth, LogicValue.zero),
  );

  final remoteBitbang = args.flag('remote-bitbang');
  final core = RiverCore(
    coreConfig,
    busConfig: wbConfig,
    withDebug: remoteBitbang,
  );

  core.input('clk').srcConnection! <= clk;
  // Hart reset = external reset OR the DM's ndmreset (below); the DM resets only
  // on external reset, so a debugger can reset the hart without dropping JTAG.
  final coreReset = Logic(name: 'coreReset');
  core.input('reset').srcConnection! <= coreReset;

  await core.build();

  final coreDataBus = core.interface('dataBus');
  final wb = coreDataBus.interface as WishboneInterface;

  final memRead = DataPortInterface(coreConfig.mxlen.size, addrWidth);
  final memWrite = DataPortInterface(coreConfig.mxlen.size, addrWidth);

  // ignore: unused_local_variable
  final mem = MemoryModel(
    clk,
    reset,
    [wrapWriteForRegisterFile(memWrite)],
    [wrapReadForRegisterFile(memRead)],
    storage: storage,
  );

  memRead.en <= wb.cyc & wb.stb & ~wb.we;
  memRead.addr <= wb.adr;
  memWrite.en <= wb.cyc & wb.stb & wb.we;
  memWrite.addr <= wb.adr;
  memWrite.data <= wb.datMosi;

  final wbAckReg = Logic(name: 'wbAck');
  Sequential(clk, [
    If(
      reset,
      then: [wbAckReg < 0],
      orElse: [
        If(
          wb.cyc & wb.stb & ~wbAckReg,
          then: [wbAckReg < 1],
          orElse: [wbAckReg < 0],
        ),
      ],
    ),
  ]);
  wb.ack <= wbAckReg;
  wb.datMiso <= memRead.data;

  // Optional JTAG debug bridge. The TAP/DTM/DM live in the system clock domain
  // and edge-detect TCK, so OpenOCD's remote_bitbang drives the real RTL. SBA is
  // serviced against the same storage the core uses.
  final tck = Logic(name: 'tck');
  final tms = Logic(name: 'tms');
  final tdi = Logic(name: 'tdi');
  final trstN = Logic(name: 'trst_n');
  final sbaRdata = Logic(name: 'sba_rdata', width: coreConfig.mxlen.size);
  final sbaAck = Logic(name: 'sba_ack');
  RiverDebugModule? dbg;
  if (remoteBitbang) {
    dbg = RiverDebugModule(
      clk,
      reset,
      tck,
      tms,
      tdi,
      trstN,
      hartHalted: core.output('debug_halted'),
      regRdata: core.output('debug_reg_rdata'),
      regReady: core.output('debug_reg_ready'),
      sbaRdata: sbaRdata,
      sbaAck: sbaAck,
      xlen: coreConfig.mxlen.size,
      idcode: 0x10000001,
    );
    await dbg.build();
    // Close the loop: the Debug Module halts/resumes the core, accesses its
    // registers via abstract commands, and the core reports state back.
    core.input('debug_halt_req').srcConnection! <= dbg.haltReq;
    core.input('debug_resume_req').srcConnection! <= dbg.resumeReq;
    core.input('debug_reg_read').srcConnection! <= dbg.regRead;
    core.input('debug_reg_write').srcConnection! <= dbg.regWrite;
    core.input('debug_reg_addr').srcConnection! <= dbg.regAddr;
    core.input('debug_reg_wdata').srcConnection! <= dbg.regWdata;
  }

  // ndmreset (dmcontrol bit 1) resets the hart but not the DM.
  if (dbg != null) {
    coreReset <= reset | dbg.ndmreset;
  } else {
    coreReset <= reset;
  }

  final maskromPath = args.option('maskrom-path');
  final firmwarePath = args.option('firmware');
  final payloadPath = args.option('payload');

  if (maskromPath == null && firmwarePath == null) {
    print('Provide --maskrom-path or --firmware');
    return;
  }

  reset.inject(1);

  if (remoteBitbang) {
    tck.inject(0);
    tms.inject(0);
    tdi.inject(0);
    trstN.inject(1);
    sbaRdata.inject(0);
    sbaAck.inject(0);
  }

  Simulator.registerAction(20, () {
    reset.put(0);

    if (maskromPath != null) {
      final elf = Elf.load(File(maskromPath).readAsBytesSync());
      storage.loadMemString(elfToMemString(elf, coreConfig.mxlen.size));
      print(
        'Loaded maskrom: entry 0x${elf.header.entry.toRadixString(16)}, '
        '${elf.programHeaders.where((ph) => ph.type == 1).length} segments',
      );
    }

    if (firmwarePath != null) {
      final elf = Elf.load(File(firmwarePath).readAsBytesSync());
      storage.loadMemString(elfToMemString(elf, coreConfig.mxlen.size));
      print(
        'Loaded firmware: entry 0x${elf.header.entry.toRadixString(16)}, '
        '${elf.programHeaders.where((ph) => ph.type == 1).length} segments',
      );
    }

    if (payloadPath != null) {
      final elf = Elf.load(File(payloadPath).readAsBytesSync());
      storage.loadMemString(elfToMemString(elf, coreConfig.mxlen.size));
      print(
        'Loaded payload: entry 0x${elf.header.entry.toRadixString(16)}, '
        '${elf.programHeaders.where((ph) => ph.type == 1).length} segments',
      );
    }
  });

  final maxCycles = int.parse(args.option('max-cycles')!);
  if (maxCycles > 0) {
    // Margin so the run-loop's maxCycles check fires (and dumps regs) before
    // the simulator force-ends.
    Simulator.setMaxSimTime((maxCycles + 50) * 20);
  }

  var cycles = 0;
  var lastPc = -1;
  var samePc = 0;

  // The remote_bitbang path drives the simulator by hand (below) so it can
  // yield to the Dart event loop and service the JTAG socket; `Simulator.run()`
  // never yields mid-run and would starve it. The normal path free-runs.
  if (!remoteBitbang) {
    unawaited(Simulator.run());

    await clk.nextPosedge;

    while (reset.value.toBool()) {
      await clk.nextPosedge;
    }
  }

  if (remoteBitbang) {
    final d = dbg!;
    final dataBytes = coreConfig.mxlen.size ~/ 8;
    final zeroWord = LogicValue.filled(coreConfig.mxlen.size, LogicValue.zero);
    var sbaAcked = false;

    // Service one System Bus Access against the same storage the core uses.
    // Sub-word accesses read-modify-write the containing word; reads shift the
    // requested bytes to the low end so sbdata0 holds them.
    void serviceSba() {
      final reqV = d.sbaReq.value;
      if (reqV.isValid && reqV.toBool() && !sbaAcked) {
        final byteAddr = d.sbaAddr.value.toInt();
        final off = byteAddr % dataBytes;
        final addrLv = LogicValue.ofInt(byteAddr - off, addrWidth);
        final size = d.sbaSize.value.isValid ? d.sbaSize.value.toInt() : 0;
        final nbits = (1 << size) * 8;
        final cur = (storage.getData(addrLv) ?? zeroWord).toBigInt();
        if (d.sbaWe.value.toBool()) {
          final wdata = d.sbaWdata.value.toBigInt();
          final mask = ((BigInt.one << nbits) - BigInt.one) << (off * 8);
          final spliced = (cur & ~mask) | ((wdata << (off * 8)) & mask);
          storage.setData(
            addrLv,
            LogicValue.ofBigInt(spliced, coreConfig.mxlen.size),
          );
        }
        final rd =
            (storage.getData(addrLv) ?? zeroWord).toBigInt() >> (off * 8);
        sbaRdata.inject(LogicValue.ofBigInt(rd, coreConfig.mxlen.size));
        sbaAck.inject(1);
        sbaAcked = true;
      } else {
        sbaAck.inject(0);
        sbaAcked = false;
      }
    }

    final port = int.parse(args.option('remote-bitbang-port')!);

    // Optional debug trace (--debug-trace): log transitions of the debug-halt
    // and request lines plus SBA activity.
    final trace = args.flag('debug-trace');
    int sv(Logic l) => l.value.isValid ? l.value.toInt() : -1;
    var pH = -9, pHR = -9, pRR = -9, pReq = -9;
    var prevClkHigh = clk.value.isValid && clk.value.toBool();

    // Drive the simulator on demand from each JTAG transition rather than a
    // free-running loop, removing the per-bit Timer latency that made bring-up
    // ~1.8s per DMI op. One core clock per JTAG bit (the TAP shifts once per bit
    // since TCK transitions once), then keep clocking while a multi-cycle DM FSM
    // (abstract command / SBA) is in flight so it settles before OpenOCD reads
    // the result. One clock per bit with no drain would starve those FSMs.
    // Advances exactly one core clock (one rising edge), servicing SBA on the
    // edge. Primitive for both the one-clock-per-bit path and the resume free-run.
    Future<void> advanceOneClock() async {
      while (Simulator.hasStepsRemaining()) {
        await Simulator.tick();
        final cur = clk.value.isValid && clk.value.toBool();
        final rising = cur && !prevClkHigh;
        prevClkHigh = cur;
        if (!rising) continue;
        if (!reset.value.toBool()) {
          serviceSba();
          cycles++;
          if (trace) {
            final h = sv(core.output('debug_halted'));
            final hr = sv(d.haltReq);
            final rr = sv(d.resumeReq);
            final rq = sv(d.sbaReq);
            if (h != pH || hr != pHR || rr != pRR || rq != pReq) {
              print(
                '[trace cyc=$cycles] halted=$h haltReq=$hr '
                'resumeReq=$rr sbaReq=$rq',
              );
              pH = h;
              pHR = hr;
              pRR = rr;
              pReq = rq;
            }
          }
        }
        return;
      }
    }

    bool coreHalted() {
      final h = core.output('debug_halted').value;
      return h.isValid && h.toBool();
    }

    // Backstop for a resumed program that never self-halts (no ebreak): cap the
    // free-run so it falls back to one-clock-per-bit instead of wedging. Real
    // firmware self-halts long before this; override via --resume-budget.
    final resumeBudget = int.parse(args.option('resume-budget')!);

    // One core clock per JTAG bit, but on a resume edge free-run the core to its
    // self-halt so a resumed program executes instead of starving at OpenOCD's
    // one-clock-per-poll cadence.
    final pump = ResumePump(
      advanceOneClock: advanceOneClock,
      coreHalted: coreHalted,
      resumeBudget: resumeBudget,
      // The core runs after reset; the first real halt makes the next resume an
      // observable edge.
      initiallyHalted: false,
    );

    await startJtagRemote(
      tck: tck,
      tms: tms,
      tdi: tdi,
      tdo: d.tdo,
      port: port,
      onTick: pump.pump,
    );
    print(
      'remote_bitbang debug server listening on port $port '
      '(core $coreModel)',
    );
    // Flush so external scripts (Heimdall/OpenOCD launchers) can detect that
    // the server is ready; piped stdout is otherwise block-buffered.
    await stdout.flush();

    // The JTAG server runs in the background and drives the simulator via
    // pumpOneClock on each transition; block here so the process stays alive
    // until the harness or OpenOCD terminates it.
    await Completer<void>().future;
  }

  while (true) {
    await clk.nextPosedge;
    cycles++;

    if (args.flag('trace')) {
      String h(LogicValue v) =>
          v.isValid ? '0x${v.toInt().toRadixString(16)}' : 'x';
      print(
        'cyc=$cycles pc=${h(core.pipeline.nextPc.value)} '
        'done=${core.pipeline.done.value.toBool()} '
        'adr=${h(wb.adr.value)} stb=${wb.stb.value.toBool()} '
        'we=${wb.we.value.toBool()} miso=${h(memRead.data.value)}',
      );
    }

    final pc = core.pipeline.nextPc.value;
    if (pc.isValid) {
      final pcInt = pc.toInt();
      // A stable nextPc for many cycles means a self-loop (program done).
      // Requiring several identical cycles avoids pipeline-warmup false halts;
      // ignore pc==0 which appears as a transient glitch during pipeline bubbles.
      if (pcInt == lastPc && pcInt != 0) {
        samePc++;
        if (samePc >= 16) {
          print(
            'Halted at PC=0x${pcInt.toRadixString(16)} after $cycles cycles',
          );
          break;
        }
      } else {
        samePc = 0;
        lastPc = pcInt;
      }
    }

    if (maxCycles > 0 && cycles >= maxCycles) {
      print(
        'Reached max cycles ($maxCycles) at PC=0x${lastPc.toRadixString(16)}',
      );
      break;
    }
  }

  // Dump the integer register file (sim/flop model) for verification.
  final buf = StringBuffer();
  for (var i = 1; i < 32; i++) {
    final v = core.regs.getData(LogicValue.ofInt(i, 5));
    if (v != null && v.isValid && v.toInt() != 0) {
      buf.write(' x$i=0x${v.toInt().toRadixString(16)}');
    }
  }
  print('regs:$buf');

  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  print('Simulation complete: $cycles cycles');

  exit(0);
}
