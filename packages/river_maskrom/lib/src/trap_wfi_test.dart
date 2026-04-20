import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// Tiny SRAM-class bring-up that proves two microcode fixes on silicon without
/// the DDR/Weir stack: MRET redirects the PC, and WFI retires instead of wedging.
///
/// UART marker sequence:
///   "CREEK "   core ran from the boot ROM
///   "M "       about to MRET
///   "R "       MRET landed at mepc and jal'd back
///   "W "       WFI retired
///   "OK\r\n"   full pass, then loops
///
/// Broken MRET loops on the mret (no "R"); broken WFI wedges (no "W"/"OK").
///
/// The landing pad sits at [romBase]+4: the first instruction is a `jal` over it,
/// so its absolute address is known at build time for MRET's mepc (the ADL has
/// no absolute label-load).
class RiverTrapWfiTest extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverTrapWfiTest({
    required this.isa,
    required int uartBase,
    required int romBase,
    int clockHz = 12000000,
    int baud = 115200,
  }) {
    final divisor = (clockHz ~/ baud).clamp(1, 0xffff);
    var uid = 0;

    // UART 8N1 setup (ns16550a). x13 holds the UART base; each block
    // re-materializes it so nothing depends on register state carried across the
    // MRET edge (invisible to the assembler).
    void uartInit() {
      register(Register.x13).bind(li(uartBase));
      register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8N1
      sb(register(Register.x13), register(Register.x11), offset: 3);
      register(Register.x11).bind(li(divisor & 0xff));
      sb(register(Register.x13), register(Register.x11), offset: 0);
      register(Register.x11).bind(li((divisor >> 8) & 0xff));
      sb(register(Register.x13), register(Register.x11), offset: 1);
      register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, 8N1
      sb(register(Register.x13), register(Register.x11), offset: 3);
    }

    // Poll THRE (LSR bit 5) then write one byte to THR. x13 must hold uartBase.
    void putc(int c) {
      final wait = label('tx_${uid++}');
      final lsr = lbu(register(Register.x13), offset: 5);
      register(Register.x14).bind(andi(lsr, 0x20));
      beq(register(Register.x14), register(Register.x0), wait);
      register(Register.x11).bind(li(c));
      sb(register(Register.x13), register(Register.x11));
    }

    void puts(String s) {
      register(Register.x13).bind(li(uartBase));
      for (final u in s.codeUnits) {
        putc(u);
      }
    }

    final mainStart = label('main_start');
    final afterMret = label('after_mret');

    // RV+0: single jal over the landing pad, so the pad sits at a known RV+4.
    jal(mainStart);

    // Landing pad @ romBase+4: the MRET target. Mark that MRET landed, rejoin main.
    puts('R ');
    jal(afterMret);

    // Main flow.
    placeLabel(mainStart);
    uartInit();
    puts('CREEK ');
    puts('M ');

    // MRET to the landing pad at romBase+4, staying in M-mode (mstatus.MPP=3).
    register(Register.x10).bind(li(romBase + 4));
    csrrw(CsrAddress.mepc.address, register(Register.x10));
    register(Register.x11).bind(li(0x1800)); // MPP = M
    csrrw(CsrAddress.mstatus.address, register(Register.x11));
    mret();

    // Only reached if MRET failed to redirect: shout and spin.
    puts('MFAIL ');
    final deadSpin = label('dead_spin');
    jal(deadSpin);

    // Reached from the landing pad after a good MRET.
    placeLabel(afterMret);
    // Prove WFI retires: if it wedged, "W" and "OK" never print.
    wfi();
    puts('W ');
    puts('OK\r\n');

    // Loop the whole sequence so a settled UART line reads a clean pass.
    jal(mainStart);
  }

  /// Raw machine code for baking into a boot ROM's init data.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());

  /// An ELF wrapping the program at [entryPoint], for the emulator/HDL sim.
  Uint8List emitElfBytes({required int entryPoint}) {
    final section = emitToSection(name: '.text', baseAddress: entryPoint);
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
