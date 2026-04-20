import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// A diagnostic stub meant to run FROM DRAM (copied there and jumped to, e.g. by
/// [RiverDramExec]). It isolates instruction-fetch integrity from every other
/// variable:
///
/// - It prints its characters from IMMEDIATES (`li`), never reading a data
///   buffer, so a garbled line cannot be blamed on a DDR data read/write.
/// - It paces each line with a long delay loop, so the UART is nowhere near
///   saturated and the host-side USB-serial cannot overrun (which would also
///   garble a sustained stream).
///
/// So the ONLY DRAM traffic while it runs is the core re-fetching this loop body
/// every iteration. If the printed `[PING]` lines are clean, instruction fetch
/// from DRAM is sound and any earlier garble was data or readout. If they are
/// still corrupted, instruction fetch from DRAM is itself marginal.
///
/// Assumes the UART divisor is already programmed (the copier set it up).
/// Position independent (PC-relative control flow, immediate UART base).
class RiverDramPing extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDramPing({
    required this.isa,
    required int uartBase,
    int delayCount = 0x40000,
  }) {
    const msg = '[PING]\r\n';
    register(Register.x13).bind(li(uartBase));

    final top = label('ping_top');
    for (var i = 0; i < msg.length; i++) {
      final poll = label('p$i');
      final lsr = lbu(register(Register.x13), offset: 5);
      register(Register.x14).bind(andi(lsr, 0x20));
      beq(register(Register.x14), register(Register.x0), poll);
      register(Register.x11).bind(li(msg.codeUnitAt(i)));
      sb(register(Register.x13), register(Register.x11));
    }
    // Delay so the line is not saturated: count x12 down to zero.
    register(Register.x12).bind(li(delayCount));
    final delay = label('ping_delay');
    register(Register.x12).bind(addi(register(Register.x12), -1));
    bne(register(Register.x12), register(Register.x0), delay);
    jal(top);
  }

  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
