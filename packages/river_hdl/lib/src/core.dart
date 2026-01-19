import 'dart:math' show max;

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:rohd_hcl/rohd_hcl.dart';
import 'package:riscv/riscv.dart';
import 'package:river/river.dart';

import 'core/csr.dart';
import 'core/int.dart';
import 'core/mmu.dart';
import 'core/pipeline.dart';

import 'memory/port.dart';

import 'dev.dart';

class RiverCoreIP extends BridgeModule {
  final RiverCore config;

  late final RegisterFile regs;
  late final RiverPipeline pipeline;

  RiverCoreIP(
    this.config, {
    Map<String, Logic> srcIrqs = const {},
    List<String> staticInstructions = const [],
    super.name = 'river_core',
  }) : super('RiverCore') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    final clk = input('clk');
    final reset = input('reset');

    final devices = Map.fromEntries(
      config.mmu.blocks.indexed.map((e) {
        final index = e.$1;
        final mmap = e.$2;

        final mmioRead = addInterface(
          MmioReadInterface(config.mxlen.size, mmap.size.bitLength),
          name: 'mmioRead$index',
          role: PairRole.consumer,
        );
        final mmioWrite = addInterface(
          MmioWriteInterface(config.mxlen.size, mmap.size.bitLength),
          name: 'mmioWrite$index',
          role: PairRole.provider,
        );

        final devRead = DataPortInterface(
          config.mxlen.size,
          mmap.size.bitLength,
        );
        final devWrite = DataPortInterface(
          config.mxlen.size,
          mmap.size.bitLength,
        );

        mmioRead.internalInterface!.en <= devRead.en;
        mmioRead.internalInterface!.addr <= devRead.addr;
        devRead.data <= mmioRead.internalInterface!.data;
        devRead.done <= mmioRead.internalInterface!.done;
        devRead.valid <= mmioRead.internalInterface!.valid;

        mmioWrite.internalInterface!.en <= devWrite.en;
        mmioWrite.internalInterface!.addr <= devWrite.addr;
        mmioWrite.internalInterface!.data <= devWrite.data;
        devWrite.done <= mmioWrite.internalInterface!.done;
        devWrite.valid <= mmioWrite.internalInterface!.valid;

        return MapEntry(mmap, (devRead, devWrite));
      }),
    );

    final pipelineEnable = Logic(name: 'pipelineEnable');
    final pc = Logic(name: 'pc', width: config.mxlen.size);
    final sp = Logic(name: 'sp', width: config.mxlen.size);
    final mode = Logic(name: 'mode', width: 3);
    final interruptHold = Logic(name: 'interruptHold');
    final fence = Logic(name: 'fence');

    final pagingMode = Logic(
      name: 'pagingMode',
      width: PagingMode.values
          .where((m) => m.isSupported(config.mxlen))
          .map((m) => m.id)
          .fold((0), (a, b) => a > b ? a : b)
          .bitLength,
    );

    final pageTableAddress = Logic(
      name: 'pageTableAddress',
      width: config.mxlen.size,
    );

    final enableMxr = Logic(name: 'enableMxr');
    final enableSum = Logic(name: 'enableSum');

    final mmuFetchRead = DataPortInterface(
      config.mxlen.size,
      config.mxlen.size,
    );
    final mmuExecRead = DataPortInterface(config.mxlen.size, config.mxlen.size);
    final mmuWritebackRead = DataPortInterface(
      config.mxlen.size,
      config.mxlen.size,
    );

    final mmuWrite = DataPortInterface(config.mxlen.size, config.mxlen.size);
    final sizedMmuWrite = DataPortInterface(
      config.mxlen.size + 7,
      config.mxlen.size,
    );

    SizedWriteSingleDataPort(
      clk,
      reset,
      backingRead: mmuWritebackRead,
      backingWrite: mmuWrite,
      source: sizedMmuWrite,
    );

    MmuModule(
      clk,
      reset,
      [(MemoryAccess.write, mmuWrite)],
      [
        (MemoryAccess.instr, mmuFetchRead),
        (MemoryAccess.read, mmuExecRead),
        (MemoryAccess.read, mmuWritebackRead),
      ],
      config: config.mmu,
      privilegeMode: mode,
      pagingMode: config.mmu.hasPaging ? pagingMode : null,
      pageTableAddress: config.mmu.hasPaging ? pageTableAddress : null,
      devices: devices,
      enableSum: config.mmu.hasSum ? enableSum : null,
      enableMxr: config.mmu.hasMxr ? enableMxr : null,
      fence: fence,
    );

    final rs1Read = DataPortInterface(config.mxlen.size, 5);
    final rs2Read = DataPortInterface(config.mxlen.size, 5);
    final rdWrite = DataPortInterface(config.mxlen.size, 5);

    regs = RegisterFile(
      clk,
      reset,
      [rdWrite],
      [rs1Read, rs2Read],
      numEntries: 32,
      name: 'riscv_regfile',
    );

    int computeNumIrqs(InterruptController ic) {
      final irqs = ic.lines.map((l) => l.irq).toList();
      if (irqs.isEmpty) return 1;
      final maxIrq = irqs.reduce((a, b) => a > b ? a : b);
      return max(1, maxIrq + 1);
    }

    final interruptBundles =
        <
          ({
            InterruptController cfg,
            Logic srcIrq,
            InterruptPortInterface ipi,
            RiscVInterruptController ctrl,
          })
        >[];

    for (final ic in config.interrupts) {
      final numIrqs = computeNumIrqs(ic);

      final isExternal = srcIrqs.containsKey(ic.name);
      final srcIrq = isExternal
          ? addInput(
              'srcIrqLevel_${interruptBundles.length}',
              srcIrqs[ic.name]!,
              width: numIrqs,
            )
          : Logic(
              name: 'srcIrqLevel_${interruptBundles.length}',
              width: numIrqs,
            );

      final ipi = InterruptPortInterface(config.mxlen.size, config.mxlen.size);

      final ctrl = RiscVInterruptController(ic, clk, reset, srcIrq, ipi);

      ipi.en <= Const(0);
      ipi.write <= Const(0);
      ipi.addr <= Const(0, width: ipi.addr.width);
      ipi.wdata <= Const(0, width: ipi.wdata.width);
      ipi.wstrb <= Const(0, width: ipi.wstrb.width);

      interruptBundles.add((cfg: ic, srcIrq: srcIrq, ipi: ipi, ctrl: ctrl));
    }

    Logic externalPending = Const(0);
    for (final b in interruptBundles) {
      final v = b.ctrl.irqToTargets;
      Logic anyFromThis = Const(0);
      for (var i = 0; i < v.width; i++) {
        anyFromThis = anyFromThis | v[i];
      }
      externalPending = externalPending | anyFromThis;
    }

    final csrRead = DataPortInterface(config.mxlen.size, 12);
    final csrWrite = DataPortInterface(config.mxlen.size, 12);

    final csrs = config.type.hasCsrs
        ? RiscVCsrFile(
            clk,
            reset,
            mode,
            mxlen: config.mxlen,
            misa:
                config.extensions
                    .map((ext) => ext.mask)
                    .fold(0, (t, i) => t | i) |
                config.mxlen.misa |
                ((config.hasSupervisor ? 1 : 0) << 18) |
                ((config.hasUser ? 1 : 0) << 20),
            mvendorid: config.vendorId,
            marchid: config.archId,
            mimpid: config.impId,
            mhartid: config.hartId,
            externalPending: externalPending,
            hasSupervisor: config.hasSupervisor,
            hasUser: config.hasUser,
            hasPaging: config.mmu.hasPaging,
            hasMxr: config.mmu.hasMxr,
            hasSum: config.mmu.hasSum,
            csrRead: csrRead,
            csrWrite: csrWrite,
          )
        : null;

    if (csrs != null && csrs.satp != null) {
      pagingMode <=
          (((csrs.satp! >>
                      Const(
                        config.mxlen.satpModeShift,
                        width: config.mxlen.size,
                      )) &
                  Const(config.mxlen.satpModeMask, width: config.mxlen.size)))
              .slice(pagingMode.width - 1, 0);
      pageTableAddress <=
          (csrs.satp! &
              Const(config.mxlen.satpPpnMask, width: config.mxlen.size));
    } else {
      pagingMode <= Const(0, width: pagingMode.width);
      pageTableAddress <= Const(0, width: config.mxlen.size);
    }

    if (csrs != null) {
      enableMxr <=
          ((csrs.mstatus >> 19) & Const(1, width: config.mxlen.size)).neq(0);
      enableSum <=
          ((csrs.mstatus >> 18) & Const(1, width: config.mxlen.size)).neq(0);
    }

    final microcodeDecodeRead = DataPortInterface(
      config.microcode.patternWidth,
      config.microcode.map.length.bitLength,
    );

    if (config.microcodeMode.onDecoder != MicrocodePipelineMode.none) {
      RegisterFile(
        clk,
        reset,
        [],
        [microcodeDecodeRead],
        numEntries: config.microcode.map.length,
        resetValue: config.microcode.encodedPatterns,
        definitionName: 'RiverMicrocodeLookup',
      );
    }

    final microcodeExecRead = DataPortInterface(
      config.microcode.mopWidth(config.mxlen),
      config.microcode.mopIndexWidth(config.mxlen),
    );

    if (config.microcodeMode.onExec != MicrocodePipelineMode.none) {
      final mops = config.microcode.encodedMops(config.mxlen);

      RegisterFile(
        clk,
        reset,
        [],
        [microcodeExecRead],
        numEntries: mops.length,
        resetValue: mops,
        definitionName: 'RiverMicrocodeOperations',
      );
    }

    pipeline = RiverPipeline(
      clk,
      reset,
      pipelineEnable,
      sp,
      pc,
      mode,
      config.type.hasCsrs ? csrRead : null,
      config.type.hasCsrs ? csrWrite : null,
      // TODO: have a cache backed memory interface
      mmuFetchRead,
      mmuExecRead,
      sizedMmuWrite,
      rs1Read,
      rs2Read,
      rdWrite,
      config.microcodeMode.onDecoder != MicrocodePipelineMode.none
          ? microcodeDecodeRead
          : null,
      config.microcodeMode.onExec != MicrocodePipelineMode.none
          ? microcodeExecRead
          : null,
      useMixedDecoders:
          config.microcodeMode.onDecoder == MicrocodePipelineMode.in_parallel,
      useMixedExecution:
          config.microcodeMode.onExec == MicrocodePipelineMode.in_parallel,
      microcode: config.microcode,
      mxlen: config.mxlen,
      hasSupervisor: config.hasSupervisor,
      hasUser: config.hasUser,
      hasCompressed: config.extensions.any((e) => e.name == 'RVC'),
      mideleg: csrs?.mideleg,
      medeleg: csrs?.medeleg,
      mtvec: csrs?.mtvec,
      stvec: csrs?.stvec,
      staticInstructions: staticInstructions,
    );

    Sequential(clk, [
      If(
        reset,
        then: [
          pipelineEnable < 0,
          pc < config.resetVector,
          sp < 0,
          mode < 0,
          fence < 0,
          interruptHold < 0,
        ],
        orElse: [
          If(
            interruptHold & externalPending,
            then: [interruptHold < 0, pipelineEnable < 1, fence < 0],
          ),

          If(
            ~interruptHold,
            then: [
              If(
                pipeline.done,
                then: [
                  pc < pipeline.nextPc,
                  sp < pipeline.nextSp,
                  mode < pipeline.nextMode,
                  interruptHold < pipeline.interruptHold,
                  fence < pipeline.fence,
                  pipelineEnable < 0,
                ],
                orElse: [pipelineEnable < 1, fence < 0],
              ),
            ],
            orElse: [pipelineEnable < 0, fence < 0],
          ),
        ],
      ),
    ]);
  }
}
