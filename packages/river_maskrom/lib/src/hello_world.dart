import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// Minimal boot program for SRAM-class systems (data RAM usable straight out of
/// reset). A first bring-up smoke test: write a message into RAM, read it back,
/// stream each byte out the ns16550a UART, then spin.
///
/// UART writes poll the LSR THRE bit so the loop paces to the transmitter,
/// keeping the image safe on real silicon as well as the emulator.
///
/// Code is position independent (all control flow PC-relative), so the same
/// image runs from boot ROM or RAM. Only [ramBase] and [uartBase] are absolute.
class RiverHelloWorld extends Module {
  @override
  final RiscVIsaConfig isa;

  /// The message streamed out the UART. Defaults to a CRLF-terminated banner.
  final String message;

  RiverHelloWorld({
    required this.isa,
    required int uartBase,
    required int ramBase,
    int clockHz = 12000000,
    int baud = 115200,
    this.message = 'Hello from River!\r\n',
    bool loop = false,
  }) {
    // Configure the ns16550a for 8N1. Harbor's UART gates TX on a non-zero
    // divisor (resets to 0), so this setup is mandatory on hardware, not
    // cosmetic. Baud = clockHz/divisor.
    final divisor = (clockHz ~/ baud).clamp(1, 0xffff);
    register(Register.x13).bind(li(uartBase)); // UART base
    register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8 data bits, 1 stop
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(divisor & 0xff)); // DLL (divisor low)
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(
      Register.x11,
    ).bind(li((divisor >> 8) & 0xff)); // DLM (divisor high)
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, 8N1 (latch divisor)
    sb(register(Register.x13), register(Register.x11), offset: 3);

    // Write the message into data RAM one byte at a time (exercises stores).
    register(Register.x10).bind(li(ramBase));
    for (var i = 0; i < message.length; i++) {
      register(Register.x11).bind(li(message.codeUnitAt(i)));
      sb(register(Register.x10), register(Register.x11), offset: i);
    }

    // Read it back from RAM and stream to the UART (exercises loads + MMIO).
    // Re-entry point: when [loop] is set, jump here to re-emit the banner forever
    // so bring-up can dial in the baud. The read cursor resets each pass.
    final streamStart = label('stream_start');
    register(Register.x10).bind(li(ramBase)); // read cursor
    register(Register.x12).bind(li(ramBase + message.length)); // end of message
    register(Register.x13).bind(li(uartBase)); // UART base

    final txLoop = label('tx_loop');
    // Wait for the transmit holding register to drain: poll LSR (offset 5),
    // bit 5 (THRE). While it is clear, branch back and re-poll.
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x14).bind(andi(lsr, 0x20));
    beq(register(Register.x14), register(Register.x0), txLoop);

    // Transmitter is ready: load the next byte from RAM and write it to THR.
    final ch = lbu(register(Register.x10));
    sb(register(Register.x13), ch);
    register(Register.x10).bind(addi(register(Register.x10), 1));
    bne(register(Register.x10), register(Register.x12), txLoop);

    if (loop) {
      // Re-emit the banner forever (bring-up baud sweep aid).
      jal(streamStart);
    } else {
      // Done: spin forever.
      final done = label('done');
      jal(done);
    }
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
