import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// [sram] copies the payload from flash into SRAM and runs it there.
/// [cacheAsRam] locks a cache region as scratch first (for SRAM-less systems
/// that wire the cache-lock CSRs). [xipLaunch] does no copy: it warms up the
/// flash XIP controller (spins up the Xilinx STARTUPE2/CCLK path so instruction
/// fetch from flash works, which fails on the first cold-reset cycle), then
/// jumps to the FSBL executing in place from flash.
enum RiverBootMode { sram, cacheAsRam, xipLaunch }

/// Optional USB DFU download-mode parameters for the maskrom.
///
/// When supplied, the maskrom arms USB DFU before the flash copy, waits for a
/// host to download an image into RAM, then jumps to it. Addresses are the MMIO
/// registers of the [RiverDfuStatus] block:
///   * [controlAddr]  write 1 to assert usb_enable (USB pull-up / connect).
///   * [statusAddr]   poll; bit0 set means the image has landed in RAM.
///   * [entryAddr]    read the RAM entry address to jump to once ready.
class RiverDfuConfig {
  final int controlAddr;
  final int statusAddr;
  final int entryAddr;

  const RiverDfuConfig({
    required this.controlAddr,
    required this.statusAddr,
    required this.entryAddr,
  });
}

class RiverMaskromConfig {
  final RiscVIsaConfig isa;
  final int resetVector;
  final int flashSource;
  final int copyDest;
  final int copySize;
  final int stackTop;
  final RiverBootMode bootMode;

  /// When non-null, the maskrom enters USB DFU download mode: assert usb_enable,
  /// poll until an image lands in RAM, jump to the reported entry. Skips the copy.
  final RiverDfuConfig? dfu;

  /// Optional boot banner. When [bootMessage] and [uartBase] are both set, the
  /// maskrom brings up the UART and prints the banner before handing off (the
  /// xipLaunch path prints it just before jumping to the FSBL). [uartDivisor] is
  /// the ns16550a baud divisor (uart clock / baud).
  final String? bootMessage;
  final int? uartBase;
  final int uartDivisor;

  const RiverMaskromConfig({
    required this.isa,
    required this.resetVector,
    required this.flashSource,
    required this.copyDest,
    required this.copySize,
    required this.stackTop,
    this.bootMode = RiverBootMode.sram,
    this.dfu,
    this.bootMessage,
    this.uartBase,
    this.uartDivisor = 1,
  });
}

class RiverMaskrom extends Module {
  @override
  final RiscVIsaConfig isa;

  /// Unique-label counter for the banner's per-character TX-wait loops.
  int _uid = 0;

  RiverMaskrom(RiverMaskromConfig config) : isa = config.isa {
    register(Register.x2).bind(li(config.stackTop));

    register(Register.x5).bind(li(config.resetVector));
    csrrw(CsrAddress.mtvec.address, register(Register.x5));

    if (config.dfu != null) {
      // USB DFU: arm USB, wait for the host to push an image into RAM, jump to
      // it. Supersedes the flash copy below.
      _dfuDownload(config.dfu!);
    }

    if (config.bootMode == RiverBootMode.xipLaunch) {
      // No copy: warm up the flash XIP controller, then jump to the FSBL running
      // in place. flashSource = warmup read window; copyDest = FSBL entry.
      _warmupRead(config.flashSource, config.copySize);
      if (config.bootMessage != null && config.uartBase != null) {
        _emitBanner(config.bootMessage!, config.uartBase!, config.uartDivisor);
      }
      fence();
      register(Register.x10).bind(li(0)); // a0 = hartid (boot hart)
      register(
        Register.x11,
      ).bind(li(0)); // a1 = dtb (none; FSBL uses comptime SoC)
      register(Register.x5).bind(li(config.copyDest));
      jalr(register(Register.x5));
      final xtrap = label('xip_trap');
      jal(xtrap);
      return;
    }

    if (config.bootMode == RiverBootMode.cacheAsRam) {
      _lockCache(
        config.copyDest,
        config.copySize + config.stackTop - config.copyDest,
      );
    }

    _copyLoop(config.flashSource, config.copyDest, config.copySize);

    fence();

    // RISC-V boot convention: a0 = hartid (0), a1 = dtb (0 = none). Without this
    // a0 holds the copy loop's leftover source pointer, so a bootloader (Weir
    // FSBL) reads it as a nonzero hartid and parks the boot hart in a wfi spin.
    register(Register.x10).bind(li(0)); // a0 = hartid
    register(Register.x11).bind(li(0)); // a1 = dtb
    register(Register.x5).bind(li(config.copyDest));
    jalr(register(Register.x5));

    final trap = label('trap');
    jal(trap);
  }

  void _dfuDownload(RiverDfuConfig dfu) {
    // Assert usb_enable (write 1 to CONTROL) so the device enumerates and the
    // host can DFU-download into RAM.
    register(Register.x10).bind(li(dfu.controlAddr));
    register(Register.x11).bind(li(1));
    sw(register(Register.x10), register(Register.x11));

    // Poll the STATUS register until bit0 (image_ready) is set.
    register(Register.x12).bind(li(dfu.statusAddr));
    final poll = label('dfu_poll');
    final status = lw(register(Register.x12));
    final ready = andi(status, 1);
    beq(ready, zero, poll); // not ready yet -> keep polling

    // Read the entry address the image landed at and jump to it.
    register(Register.x13).bind(li(dfu.entryAddr));
    register(Register.x5).bind(lw(register(Register.x13)));
    fence();
    jalr(register(Register.x5));

    // Safety trap: if the jump ever returns, spin.
    final dfuTrap = label('dfu_trap');
    jal(dfuTrap);
  }

  void _lockCache(int addr, int size) {
    register(Register.x5).bind(li(addr));
    csrrw(CsrAddress.rcacheaddr.address, register(Register.x5));
    register(Register.x5).bind(li(size));
    csrrw(CsrAddress.rcachesize.address, register(Register.x5));
    register(Register.x5).bind(li(1));
    csrrw(CsrAddress.rcachectl.address, register(Register.x5));
  }

  /// Read [size] bytes from [src] (flash) word by word, discarding the data. The
  /// act of reading spins up the flash XIP controller + Xilinx STARTUPE2/CCLK
  /// path so the subsequent fetch from flash succeeds. x15 is pinned so the
  /// dead-code pass keeps the loads even though nothing consumes them.
  void _warmupRead(int src, int size) {
    register(Register.x10).bind(li(src));
    register(Register.x12).bind(li(src + size));
    final loop = label('warmup');
    register(Register.x15).bind(lw(register(Register.x10)));
    register(Register.x10).bind(addi(register(Register.x10), 4));
    bne(register(Register.x10), register(Register.x12), loop);
  }

  /// Bring up the ns16550a UART (8N1, [divisor] baud divisor) and print
  /// [msg] as a boot banner. x13 holds the UART base throughout; each byte
  /// polls THRE (LSR bit 5) before it writes THR. The banner is fire-and-forget:
  /// nothing here is read back, so it never blocks the handoff to the FSBL.
  void _emitBanner(String msg, int uartBase, int divisor) {
    final div = divisor.clamp(1, 0xffff);
    register(Register.x13).bind(li(uartBase));
    register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(div & 0xff));
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(Register.x11).bind(li((div >> 8) & 0xff));
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);

    register(Register.x13).bind(li(uartBase));
    for (final c in msg.codeUnits) {
      final wait = label('mrtx_${_uid++}');
      final lsr = lbu(register(Register.x13), offset: 5);
      register(Register.x14).bind(andi(lsr, 0x20));
      beq(register(Register.x14), register(Register.x0), wait);
      register(Register.x11).bind(li(c));
      sb(register(Register.x13), register(Register.x11));
    }
  }

  void _copyLoop(int src, int dst, int size) {
    // One loop-carried pointer (x10, source); dst is recomputed each iteration
    // as x10 + (dst - src). The ADL dead-code pass is not loop-aware: a separate
    // `dst += 4` read only across the back-edge has no straight-line consumer and
    // is dropped, so every store hits the same address and the copy silently
    // fails. x10 survives because `bne` reads it; the dst `add` is consumed by `sw`.
    register(Register.x10).bind(li(src));
    register(Register.x13).bind(li(dst - src)); // dst = src + delta
    register(Register.x12).bind(li(src + size));

    final loop = label('copy');
    register(Register.x15).bind(lw(register(Register.x10)));
    register(
      Register.x14,
    ).bind(add(register(Register.x10), register(Register.x13)));
    sw(register(Register.x14), register(Register.x15));
    register(Register.x10).bind(addi(register(Register.x10), 4));
    bne(register(Register.x10), register(Register.x12), loop);
  }

  Section emitMaskrom({int? baseAddress}) {
    return emitToSection(name: '.text', baseAddress: baseAddress ?? 0);
  }

  Uint8List emitElfBytes({required int entryPoint}) {
    final section = emitMaskrom();
    final writer = ElfWriter(
      entryPoint: entryPoint,
      elfClass: isa.mxlen == RiscVMxlen.rv64
          ? ElfWriterClass.elf64
          : ElfWriterClass.elf32,
    );
    writer.addSection(section, address: entryPoint);
    return Uint8List.fromList(writer.write());
  }
}
