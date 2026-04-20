import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// DDR3 read-leveling eye-sweep firmware (creek OrangeCrab), built on the
/// ddrdiag run-structure.
///
/// Control + DRAM both work (STATUS=0x400 = DLL_LOCK[10]=1 but DATAVALID[8]=0 /
/// BURSTDET[9]=0, so the DQS read eye is not centred). This sweeps the
/// read-leveling knobs to find where DATAVALID / BURSTDET fire and a written
/// pattern reads back.
///
/// Train-control registers (8-byte strided, decoded on bus[5:3], at
/// [trainCtrlBase] = dramBase + dramSize = 0x88000000 on creek):
///   reg0 +0x00 RDTAP   target (7-bit DELAYF read tap, 0..127)
///   reg1 +0x08 CTL     bit0 SET (load RDTAP target into the delay walk)
///   reg2 +0x10 RDSLACK read-window slack cycles
///   reg3 +0x18 STATUS  (read-only) busy[0], curTap[7:1], DATAVALID[8],
///                      BURSTDET[9], DLL_LOCK[10], BDET_SEEN[11], DVALID_SEEN[12]
///   reg4 +0x20 READCLKSEL 3-bit DQSBUFM read-gate select (0..7)
/// DRAM array base = [dramBase] (0x80000000).
///
/// Sequence:
///   1. UART init + `12345678` liveness, and a one-shot `DLL=<bit10>` STATUS
///      snapshot (proves control READ works).
///   2. THREE nested RUNTIME loops (body emitted once, no Dart unroll): RDTAP in
///      {0,8,..,120} (16) x READCLKSEL 0..7 (8) x RDSLACK 0..4 (5) = 640 combos.
///      Each combo: program reg0=RDTAP + pulse reg1 SET, reg4=RCS, reg2=SLK;
///      write the 4-word C0DE pattern; warm-up read; read 4 words + STATUS.
///      MATCH judged by DATA (4 readback words == pattern), not flags. Prints
///      only when INTERESTING (MATCH, or STATUS DVALID_SEEN[12]/BDET_SEEN[11]):
///        `EYE TAP=<n> RCS=<n> SLK=<n> ST=<status> W0=<w0> [MATCH]`
///   3. Summary, looped for UART-glitch tolerance:
///        `EYEBEST TAP=<n> RCS=<n> SLK=<n>` first full-C0DE MATCH (or NONE)
///        `EYEDV TAP=<n> RCS=<n> SLK=<n>`   first DV/BD seen (or NONE)
///
/// DRAM read-back uses plain `lw`, which acks even on a bad eye (rdTimeout
/// floor), so no access can stall the sweep. Pure-ROM, position independent
/// except for the absolute UART / train-control / DRAM addresses.
class RiverDdrEyeSweep extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDdrEyeSweep({
    required this.isa,
    required int uartBase,
    required int dramBase,
    required int trainCtrlBase,
    int clockHz = 48000000,
    int baud = 115200,
  }) {
    // Train-control register addresses (8-byte strided, decoded on bus[5:3]).
    final regRdtap = trainCtrlBase + 0x00; // reg0 (7-bit DELAYF read tap)
    final regCtl = trainCtrlBase + 0x08; // reg1 (bit0 SET)
    final regRdslack = trainCtrlBase + 0x10; // reg2 (read-window slack)
    final regStatus = trainCtrlBase + 0x18; // reg3 (read-only)
    final regReadClkSel =
        trainCtrlBase + 0x20; // reg4 (3-bit DQS read-gate sel)

    // The 4-word C0DE pattern written + checked at the DRAM base each combo.
    const pat0 = 0xC0DE0000;
    const pat1 = 0xC0DE1111;
    const pat2 = 0xC0DE2222;
    const pat3 = 0xC0DE3333;

    // Sweep extents (runtime, body emitted once).
    const tapStep = 8; // RDTAP {0,8,...,120}
    const tapTop = 121; // while tap < 121 (0..120) -> 16 steps
    const rcsTop = 8; // READCLKSEL 0..7
    const slkTop = 5; // RDSLACK 0..4

    // ns16550a setup (the divisor gates the transmitter). x13 holds uartBase for
    // the whole program (the hex/crlf printers read it). EXACTLY ddrdiag's setup.
    final divisor = (clockHz ~/ baud).clamp(1, 0xffff);
    register(Register.x13).bind(li(uartBase));
    register(Register.x11).bind(li(0x83)); // LCR: DLAB=1, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);
    register(Register.x11).bind(li(divisor & 0xff)); // DLL
    sb(register(Register.x13), register(Register.x11), offset: 0);
    register(Register.x11).bind(li((divisor >> 8) & 0xff)); // DLM
    sb(register(Register.x13), register(Register.x11), offset: 1);
    register(Register.x11).bind(li(0x03)); // LCR: DLAB=0, 8N1
    sb(register(Register.x13), register(Register.x11), offset: 3);

    // 1. Liveness: this line must read 12345678 so we know the core is alive.
    register(Register.x14).bind(li(0x12345678));
    _printHexX14();
    _crlf();

    // reg7 WRDLY is the per-lane 4-bit write pointer ([3:0]=lane0, [7:4]=lane1,
    // auto-applies on write). Set it once to the env-baked WRPTR before the pass.
    const wrPtr = 0;
    final regWrDly = trainCtrlBase + 0x38;
    register(Register.x10).bind(li(regWrDly));
    register(Register.x11).bind(li(wrPtr));
    sw(register(Register.x10), register(Register.x11));

    // Beat/lane scramble decoder. A written value rereads stable, but each fresh
    // write lands in a rotating set of wrong values, so the defect is a write
    // beat/lane placement, not the read eye. Write a counting pattern (4 words =
    // 16 bytes 00..0F: 0x03020100 07060504 0B0A0908 0F0E0D0C) so the readback
    // reveals which byte lands where. Print "P w0 w1 w2 w3" per pass: identical
    // every pass = fixed permutation; rotating = per-burst gearbox phase.
    // x4..x7 = readback, x11 = write scratch, x10 = addr.
    final passTop = label('passtop');

    // Rewrite the 4-word counting pattern each pass (fresh write burst).
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x11).bind(li(0x03020100));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0x4));
    register(Register.x11).bind(li(0x07060504));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0x8));
    register(Register.x11).bind(li(0x0B0A0908));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0xC));
    register(Register.x11).bind(li(0x0F0E0D0C));
    sw(register(Register.x10), register(Register.x11));

    // Read the 4 words back into x4..x7 (warm-up read first).
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x14).bind(lw(register(Register.x10))); // warm-up
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x4).bind(lw(register(Register.x10)));
    register(Register.x10).bind(li(dramBase + 0x4));
    register(Register.x5).bind(lw(register(Register.x10)));
    register(Register.x10).bind(li(dramBase + 0x8));
    register(Register.x6).bind(lw(register(Register.x10)));
    register(Register.x10).bind(li(dramBase + 0xC));
    register(Register.x7).bind(lw(register(Register.x10)));

    _printStr('P ');
    register(Register.x14).bind(addi(register(Register.x4), 0));
    _printHexX14();
    _printChar(0x20);
    register(Register.x14).bind(addi(register(Register.x5), 0));
    _printHexX14();
    _printChar(0x20);
    register(Register.x14).bind(addi(register(Register.x6), 0));
    _printHexX14();
    _printChar(0x20);
    register(Register.x14).bind(addi(register(Register.x7), 0));
    _printHexX14();
    _crlf();

    jal(passTop);
    return;

    // ignore: dead_code
    // Nested read-leveling sweep: outer RDTAP x27 {0,8,..,120}, inner READCLKSEL
    // x26 {0..7}. For each combo: program rdtap(reg0)+pulse SET(reg1), program
    // READCLKSEL(reg4), write pattern to dramBase, read back, beq-match.
    register(Register.x11).bind(li(0x40DE0001)); // pattern (bit31 clear)
    register(Register.x12).bind(li(0x1)); // CTL.SET pulse value
    register(Register.x27).bind(li(0)); // rdtap
    final calTapTop = label('caltaptop');
    register(Register.x10).bind(li(regRdtap));
    sw(register(Register.x10), register(Register.x27)); // rdtap target
    register(Register.x10).bind(li(regCtl));
    sw(register(Register.x10), register(Register.x12)); // pulse SET (load walk)
    register(Register.x26).bind(li(0)); // rcs
    final calRcsTop = label('calrcstop');
    register(Register.x10).bind(li(regReadClkSel));
    sw(register(Register.x10), register(Register.x26)); // READCLKSEL
    register(Register.x10).bind(li(dramBase));
    sw(register(Register.x10), register(Register.x11)); // write pattern
    register(Register.x24).bind(lw(register(Register.x10))); // read back
    final calOk = label('calok');
    beq(register(Register.x24), register(Register.x11), calOk);
    register(Register.x26).bind(addi(register(Register.x26), 1));
    register(Register.x18).bind(li(8));
    final calRcsDone = label('calrcsdone');
    beq(register(Register.x26), register(Register.x18), calRcsDone);
    jal(calRcsTop);
    placeLabel(calRcsDone);
    register(Register.x27).bind(addi(register(Register.x27), 8));
    register(Register.x18).bind(li(128));
    final calNone = label('calnone');
    beq(register(Register.x27), register(Register.x18), calNone);
    jal(calTapTop);
    // NONE - loop printing the last DRAM read value (how wrong) + status.
    placeLabel(calNone);
    final calNoneLoop = label('calnoneloop');
    register(Register.x10).bind(li(dramBase));
    register(Register.x24).bind(lw(register(Register.x10)));
    _printStr('NONE DR=');
    register(Register.x14).bind(addi(register(Register.x24), 0));
    _printHexX14();
    _crlf();
    jal(calNoneLoop);
    // OK - loop printing the winning tap + rcs forever.
    placeLabel(calOk);
    final calOkLoop = label('calokloop');
    _printStr('OK t');
    register(Register.x14).bind(addi(register(Register.x27), 0));
    _printHexX14();
    _printStr(' r');
    register(Register.x14).bind(addi(register(Register.x26), 0));
    _printHexX14();
    _crlf();
    jal(calOkLoop);
    return;

    // ignore: dead_code
    // One-shot STATUS (reg3) snapshot of DLL lock (like ddrdiag's RDOK proof
    // that a control READ acks). `DLL=<bit10>`.
    register(Register.x10).bind(li(regStatus));
    register(Register.x24).bind(lw(register(Register.x10)));
    _printStr('DLL=');
    register(Register.x14).bind(andi(srli(register(Register.x24), 10), 0x1));
    _printHexX14();
    _crlf();

    // EYE sweep. x27=RDTAP (OUTER), x26=READCLKSEL (MID), x25=RDSLACK (INNER),
    // x4..x7=read-back words, x8=STATUS snapshot, x9=MATCH flag. Trackers:
    // x20=best-found, x21/x22/x23=best TAP/RCS/SLK, x28=dv-found,
    // x29/x30/x31=first-dv TAP/RCS/SLK.
    register(Register.x20).bind(li(0)); // best-found flag
    register(Register.x28).bind(li(0)); // dv-found flag

    register(Register.x27).bind(li(0)); // RDTAP
    final tapTopLbl = label('eyetap');

    // Program RDTAP target (reg0) = x27, then pulse reg1 SET to load the walk.
    register(Register.x10).bind(li(regRdtap));
    sw(register(Register.x10), register(Register.x27));
    register(Register.x10).bind(li(regCtl));
    register(Register.x11).bind(li(0x1)); // SET
    sw(register(Register.x10), register(Register.x11));

    register(Register.x26).bind(li(0)); // READCLKSEL
    final rcsTopLbl = label('eyercs');

    // Program READCLKSEL (reg4) = x26.
    register(Register.x10).bind(li(regReadClkSel));
    sw(register(Register.x10), register(Register.x26));

    register(Register.x25).bind(li(0)); // RDSLACK
    final slkTopLbl = label('eyeslk');

    // Program RDSLACK (reg2) = x25.
    register(Register.x10).bind(li(regRdslack));
    sw(register(Register.x10), register(Register.x25));

    // Write the 4-word C0DE pattern to DRAM base (plain sw, same as ddrtest).
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x11).bind(li(pat0));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0x4));
    register(Register.x11).bind(li(pat1));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0x8));
    register(Register.x11).bind(li(pat2));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0xC));
    register(Register.x11).bind(li(pat3));
    sw(register(Register.x10), register(Register.x11));

    // Warm-up read (absorb write->read turnaround), then read 4 words into
    // x4..x7. Plain `lw` acks even on a bad eye (rdTimeout floor), no hang.
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x14).bind(lw(register(Register.x10))); // warm-up
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x4).bind(lw(register(Register.x10))); // w0
    register(Register.x10).bind(li(dramBase + 0x4));
    register(Register.x5).bind(lw(register(Register.x10))); // w1
    register(Register.x10).bind(li(dramBase + 0x8));
    register(Register.x6).bind(lw(register(Register.x10))); // w2
    register(Register.x10).bind(li(dramBase + 0xC));
    register(Register.x7).bind(lw(register(Register.x10))); // w3

    // Snapshot STATUS (reg3) for this combo (DV/BD seen bits + the raw value).
    register(Register.x10).bind(li(regStatus));
    register(Register.x8).bind(lw(register(Register.x10)));

    // MATCH = (w0==pat0) & (w1==pat1) & (w2==pat2) & (w3==pat3). Build x9: start
    // 1, clear to 0 on any mismatch.
    register(Register.x9).bind(li(1));
    final mFail = label('eyemfail');
    register(Register.x11).bind(li(pat0));
    final mc1 = label('eyemc1');
    beq(register(Register.x4), register(Register.x11), mc1);
    jal(mFail);
    placeLabel(mc1);
    register(Register.x11).bind(li(pat1));
    final mc2 = label('eyemc2');
    beq(register(Register.x5), register(Register.x11), mc2);
    jal(mFail);
    placeLabel(mc2);
    register(Register.x11).bind(li(pat2));
    final mc3 = label('eyemc3');
    beq(register(Register.x6), register(Register.x11), mc3);
    jal(mFail);
    placeLabel(mc3);
    register(Register.x11).bind(li(pat3));
    final mc4 = label('eyemc4');
    beq(register(Register.x7), register(Register.x11), mc4);
    jal(mFail);
    placeLabel(mc4);
    final mNext = label('eyemnext');
    jal(mNext);
    placeLabel(mFail);
    register(Register.x9).bind(li(0)); // mismatch
    placeLabel(mNext);

    // x12 = DV-or-BD seen for this combo = STATUS[12] | STATUS[11] (nonzero if
    // the strobe fired anywhere on this combo). STATUS bits [12:11] -> srli 11,
    // mask 0x3.
    register(Register.x12).bind(andi(srli(register(Register.x8), 11), 0x3));

    // INTERESTING = MATCH (x9!=0) OR DV-or-BD seen (x12!=0). x11 = x9|x12; if
    // x11==0 skip the whole print block (keeps UART readable).
    register(
      Register.x11,
    ).bind(or(register(Register.x9), register(Register.x12)));
    final eyeSkip = label('eyeskip');
    beq(register(Register.x11), register(Register.x0), eyeSkip);

    // Print: EYE TAP=<n> RCS=<n> SLK=<n> ST=<status> W0=<w0> [MATCH]
    _printStr('EYE TAP=');
    register(Register.x14).bind(mv(register(Register.x27)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x26)));
    _printHexX14();
    _printStr(' SLK=');
    register(Register.x14).bind(mv(register(Register.x25)));
    _printHexX14();
    _printStr(' ST=');
    register(Register.x14).bind(mv(register(Register.x8)));
    _printHexX14();
    _printStr(' W0=');
    register(Register.x14).bind(mv(register(Register.x4)));
    _printHexX14();
    // " MATCH" only when all four words matched (x9 != 0).
    final noMatchTag = label('eyenomatch');
    beq(register(Register.x9), register(Register.x0), noMatchTag);
    _printStr(' MATCH');
    placeLabel(noMatchTag);
    _crlf();
    placeLabel(eyeSkip);

    // Latch EYEBEST: FIRST fully-matching combo. Record only if x9 (match) and
    // not already latched (x20==0).
    final bestDone = label('eyebestdone');
    beq(register(Register.x9), register(Register.x0), bestDone); // no match
    register(Register.x11).bind(li(1));
    beq(
      register(Register.x20),
      register(Register.x11),
      bestDone,
    ); // already set
    register(Register.x20).bind(li(1)); // latch best-found
    register(Register.x21).bind(mv(register(Register.x27))); // best TAP
    register(Register.x22).bind(mv(register(Register.x26))); // best RCS
    register(Register.x23).bind(mv(register(Register.x25))); // best SLK
    placeLabel(bestDone);

    // Latch EYEDV: FIRST combo where DATAVALID-seen OR BURSTDET-seen was set.
    // Record only if x12 (dv-or-bd) nonzero and not already latched (x28==0).
    final dvDone = label('eyedvdone');
    beq(register(Register.x12), register(Register.x0), dvDone); // no strobe
    register(Register.x11).bind(li(1));
    beq(register(Register.x28), register(Register.x11), dvDone); // already set
    register(Register.x28).bind(li(1)); // latch dv-found
    register(Register.x29).bind(mv(register(Register.x27))); // first-dv TAP
    register(Register.x30).bind(mv(register(Register.x26))); // first-dv RCS
    register(Register.x31).bind(mv(register(Register.x25))); // first-dv SLK
    placeLabel(dvDone);

    // INNER step: RDSLACK += 1; repeat while < slkTop (0..4).
    register(Register.x25).bind(addi(register(Register.x25), 1));
    register(Register.x11).bind(li(slkTop));
    blt(register(Register.x25), register(Register.x11), slkTopLbl);

    // MID step: READCLKSEL += 1; repeat while < rcsTop (0..7).
    register(Register.x26).bind(addi(register(Register.x26), 1));
    register(Register.x11).bind(li(rcsTop));
    blt(register(Register.x26), register(Register.x11), rcsTopLbl);

    // OUTER step: RDTAP += tapStep; repeat while < tapTop ({0,8,..,120}).
    register(Register.x27).bind(addi(register(Register.x27), tapStep));
    register(Register.x11).bind(li(tapTop));
    blt(register(Register.x27), register(Register.x11), tapTopLbl);

    // Summary, looped 3x for UART-glitch tolerance (x19 = counter):
    //   EYEBEST TAP=<n> RCS=<n> SLK=<n>  (first full match) or NONE
    //   EYEDV   TAP=<n> RCS=<n> SLK=<n>  (first strobe)     or NONE
    register(Register.x19).bind(li(0));
    final sumTop = label('eyesumtop');

    // EYEBEST line.
    _printStr('EYEBEST ');
    final bestNone = label('eyebestnone');
    beq(register(Register.x20), register(Register.x0), bestNone);
    _printStr('TAP=');
    register(Register.x14).bind(mv(register(Register.x21)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x22)));
    _printHexX14();
    _printStr(' SLK=');
    register(Register.x14).bind(mv(register(Register.x23)));
    _printHexX14();
    final bestSumDone = label('eyebestsumdone');
    jal(bestSumDone);
    placeLabel(bestNone);
    _printStr('NONE');
    placeLabel(bestSumDone);
    _crlf();

    // EYEDV line.
    _printStr('EYEDV ');
    final dvNone = label('eyedvnone');
    beq(register(Register.x28), register(Register.x0), dvNone);
    _printStr('TAP=');
    register(Register.x14).bind(mv(register(Register.x29)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x30)));
    _printHexX14();
    _printStr(' SLK=');
    register(Register.x14).bind(mv(register(Register.x31)));
    _printHexX14();
    final dvSumDone = label('eyedvsumdone');
    jal(dvSumDone);
    placeLabel(dvNone);
    _printStr('NONE');
    placeLabel(dvSumDone);
    _crlf();

    // Repeat the summary block 3 times total.
    register(Register.x19).bind(addi(register(Register.x19), 1));
    register(Register.x11).bind(li(3));
    blt(register(Register.x19), register(Register.x11), sumTop);

    // Loop the summary forever: streaming clean EYEBEST/EYEDV copies is the
    // readable path through the FPGA-reconfig UART glitch.
    final tailTop = label('eyetailtop');
    _printStr('EYEBEST ');
    final bestNone2 = label('eyebestnone2');
    beq(register(Register.x20), register(Register.x0), bestNone2);
    _printStr('TAP=');
    register(Register.x14).bind(mv(register(Register.x21)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x22)));
    _printHexX14();
    _printStr(' SLK=');
    register(Register.x14).bind(mv(register(Register.x23)));
    _printHexX14();
    final bestSumDone2 = label('eyebestsumdone2');
    jal(bestSumDone2);
    placeLabel(bestNone2);
    _printStr('NONE');
    placeLabel(bestSumDone2);
    _crlf();

    _printStr('EYEDV ');
    final dvNone2 = label('eyedvnone2');
    beq(register(Register.x28), register(Register.x0), dvNone2);
    _printStr('TAP=');
    register(Register.x14).bind(mv(register(Register.x29)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x30)));
    _printHexX14();
    _printStr(' SLK=');
    register(Register.x14).bind(mv(register(Register.x31)));
    _printHexX14();
    final dvSumDone2 = label('eyedvsumdone2');
    jal(dvSumDone2);
    placeLabel(dvNone2);
    _printStr('NONE');
    placeLabel(dvSumDone2);
    _crlf();
    jal(tailTop);
  }

  /// Prints x14 as eight uppercase hex digits, MSB first.
  void _printHexX14() {
    register(Register.x17).bind(li(0x3A));
    register(Register.x18).bind(li(28));
    final nibble = label('nib');
    register(
      Register.x15,
    ).bind(srl(register(Register.x14), register(Register.x18)));
    register(Register.x15).bind(andi(register(Register.x15), 0xF));
    register(Register.x15).bind(addi(register(Register.x15), 0x30));
    final noAdjust = Label('noadj');
    blt(register(Register.x15), register(Register.x17), noAdjust);
    register(Register.x15).bind(addi(register(Register.x15), 7));
    placeLabel(noAdjust);
    final poll = label('p');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x16).bind(andi(lsr, 0x20));
    beq(register(Register.x16), register(Register.x0), poll);
    sb(register(Register.x13), register(Register.x15));
    register(Register.x18).bind(addi(register(Register.x18), -4));
    bge(register(Register.x18), register(Register.x0), nibble);
  }

  /// Transmits a single byte, polling the LSR THRE bit first.
  void _printChar(int ch) {
    final poll = label('p');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x16).bind(andi(lsr, 0x20));
    beq(register(Register.x16), register(Register.x0), poll);
    register(Register.x15).bind(li(ch));
    sb(register(Register.x13), register(Register.x15));
  }

  /// Transmits an ASCII string byte by byte (immediates only, no data table).
  void _printStr(String s) {
    for (final ch in s.codeUnits) {
      _printChar(ch);
    }
  }

  void _crlf() {
    for (final ch in const [0x0D, 0x0A]) {
      _printChar(ch);
    }
  }

  /// Raw machine code for a monitor load frame.
  Uint8List generateBytes() => Uint8List.fromList(generateBinary());
}
