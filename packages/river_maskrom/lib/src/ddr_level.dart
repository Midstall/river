import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// DDR3 read-leveling eye-sweep firmware (OrangeCrab). The read eye is centered
/// by the DELAYF read tap (reg0 RDTAP + reg1 SET), the knob that makes DATAVALID
/// / BURSTDET fire. This sweeps it (plus READCLKSEL and RDSLACK) while
/// writing+reading a known pattern to find where the array reads back correctly.
///
/// THREE nested RUNTIME loops, body emitted once (no Dart unroll):
///   OUTER  RDTAP in {0,8,..,120}  (16; reg0=tap, reg1 SET pulse)
///   MID    READCLKSEL in 0..7     (reg4) -> 8
///   INNER  RDSLACK in 0..7        (reg2) -> 8
/// = 1024 combos. READCLKSEL[1:0] also selects the PHY per-DQ BitSlip read-beat
/// rotation (RCS 0/4->slp0, 1/5->slp1, 2/6->slp2, 3/7->slp3). RDSLACK also moves
/// the PHY fabric read-capture anchor cycle (rdPipe[clSys + rdSlackRt]).
///
/// Per combo: write the 4-word C0DE pattern
///   [0xC0DE0000, 0xC0DE1111, 0xC0DE2222, 0xC0DE3333]
/// to DRAM base, warm-up read, then read back and compare. MATCH judged by DATA
/// (4 words == pattern), not the DV/BD flags. Prints only INTERESTING combos
/// (MATCH, or STATUS DATAVALID-seen[12]/BURSTDET-seen[11] set):
///   `LVL TAP=<n> RCS=<n> SLK=<n> -> <w0> <w1> DV=<b> BD=<b>`
/// Summary (looped for UART-glitch tolerance):
///   `LVLBEST TAP=<n> RCS=<n> SLK=<n>` first full match, or NONE
///   `LVLDV TAP=<n> RCS=<n>` first DV/BD-seen combo, or NONE
///
/// Train-control registers (8-byte strided, address bits [5:3], at
/// [trainCtrlBase] = dramBase + dramSize on creek):
///   reg0 +0x00 RDTAP   target (7-bit DELAYF read tap, 0..127)
///   reg1 +0x08 CTL     bit0 SET (load RDTAP target into the delay walk)
///   reg2 +0x10 RDSLACK read-window slack cycles
///   reg3 +0x18 STATUS  (read-only) DATAVALID[8], BURSTDET[9], DLL_LOCK[10],
///                      BDET_SEEN[11], DVALID_SEEN[12]
///   reg4 +0x20 READCLKSEL 3-bit DQSBUFM read-gate select (0..7)
///
/// Pure ROM, runtime loops. Only the four DRAM words at the base are touched.
class RiverDdrLevel extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDdrLevel({
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
    final regWlres = trainCtrlBase + 0x30; // reg6 (read-only WL-RESULT)
    final regWrdly = trainCtrlBase + 0x38; // reg7 WRDLY (per-lane tap + dir)
    final regWtrim =
        trainCtrlBase + 0x40; // reg8 WRITE-TRIM (lane0 DYNDELAY[7:0])

    // The 4-word C0DE pattern written + checked at the DRAM base each combo.
    const pat0 = 0xC0DE0000;
    const pat1 = 0xC0DE1111;
    const pat2 = 0xC0DE2222;
    const pat3 = 0xC0DE3333;

    // Sweep extents (runtime, body emitted once).
    const tapStep = 8; // RDTAP {0,8,...,120}
    const tapTop = 121; // exclusive-ish: while tap < 121 (0..120)
    const rcsTop = 8; // READCLKSEL 0..7
    const slkTop = 8; // RDSLACK 0..7 (now also moves the fabric capture anchor)

    // ns16550a setup (the divisor gates the transmitter). x13 holds uartBase for
    // the whole program (the hex/crlf printers read it).
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

    // Printer self-test: this line must read 12345678 so we know the core is
    // alive before the sweep.
    register(Register.x14).bind(li(0x12345678));
    _printHexX14();
    _crlf();

    // DIAG: one-shot STATUS (reg3) snapshot of the sticky read-path flags before
    // the sweep: DLL lock, BURSTDET-seen[11], DATAVALID-seen[12].
    register(Register.x10).bind(li(regStatus));
    register(Register.x24).bind(lw(register(Register.x10)));
    _printStr('DIAG DLL=');
    register(Register.x14).bind(andi(srli(register(Register.x24), 10), 0x1));
    _printHexX14();
    _printStr(' BDET=');
    register(Register.x14).bind(andi(srli(register(Register.x24), 11), 0x1));
    _printHexX14();
    _printStr(' DVAL=');
    register(Register.x14).bind(andi(srli(register(Register.x24), 12), 0x1));
    _printHexX14();
    _crlf();

    // EYE sweep. x27=RDTAP (OUTER), x26=READCLKSEL (MID), x25=RDSLACK (INNER),
    // x4..x7=read-back words, x8=STATUS snapshot, x9=MATCH flag. Trackers:
    // x20=best-found, x21/x22/x23=best TAP/RCS/SLK, x28=dv-found,
    // x29/x30=first-dv TAP/RCS.
    register(Register.x20).bind(li(0)); // best-found flag
    register(Register.x28).bind(li(0)); // dv-found flag

    register(Register.x27).bind(li(0)); // RDTAP
    final tapTopLbl = label('lvltap');

    // Program RDTAP target (reg0) = x27, then pulse reg1 SET to load the walk.
    register(Register.x10).bind(li(regRdtap));
    sw(register(Register.x10), register(Register.x27));
    register(Register.x10).bind(li(regCtl));
    register(Register.x11).bind(li(0x1)); // SET
    sw(register(Register.x10), register(Register.x11));

    register(Register.x26).bind(li(0)); // READCLKSEL
    final rcsTopLbl = label('lvlrcs');

    // Program READCLKSEL (reg4) = x26.
    register(Register.x10).bind(li(regReadClkSel));
    sw(register(Register.x10), register(Register.x26));

    register(Register.x25).bind(li(0)); // RDSLACK
    final slkTopLbl = label('lvlslk');

    // Program RDSLACK (reg2) = x25.
    register(Register.x10).bind(li(regRdslack));
    sw(register(Register.x10), register(Register.x25));

    // Write the 4-word C0DE pattern to DRAM base.
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

    // Warm-up read (absorb the write->read turnaround beat), then capture the
    // four words into x4..x7.
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

    // Snapshot STATUS (reg3) for the DV/BD-seen bits of this combo.
    register(Register.x10).bind(li(regStatus));
    register(Register.x8).bind(lw(register(Register.x10)));

    // MATCH = (w0==pat0) & (w1==pat1) & (w2==pat2) & (w3==pat3). Build x9: start
    // 1, clear to 0 on any mismatch.
    register(Register.x9).bind(li(1));
    final mNext = label('lvlmnext');
    final mFail = label('lvlmfail');
    register(Register.x11).bind(li(pat0));
    final mc1 = label('lvlmc1');
    beq(register(Register.x4), register(Register.x11), mc1);
    jal(mFail);
    placeLabel(mc1);
    register(Register.x11).bind(li(pat1));
    final mc2 = label('lvlmc2');
    beq(register(Register.x5), register(Register.x11), mc2);
    jal(mFail);
    placeLabel(mc2);
    register(Register.x11).bind(li(pat2));
    final mc3 = label('lvlmc3');
    beq(register(Register.x6), register(Register.x11), mc3);
    jal(mFail);
    placeLabel(mc3);
    register(Register.x11).bind(li(pat3));
    final mc4 = label('lvlmc4');
    beq(register(Register.x7), register(Register.x11), mc4);
    jal(mFail);
    placeLabel(mc4);
    jal(mNext);
    placeLabel(mFail);
    register(Register.x9).bind(li(0)); // mismatch
    placeLabel(mNext);

    // x12 = DV-or-BD seen for this combo = STATUS[12] | STATUS[11] (nonzero if
    // the strobe fired anywhere on this combo).
    register(Register.x12).bind(andi(srli(register(Register.x8), 11), 0x3));

    // INTERESTING = MATCH (x9!=0) OR DV-or-BD seen (x12!=0). Compute x11 =
    // x9|x12; if x11==0 skip the whole print block.
    register(
      Register.x11,
    ).bind(or(register(Register.x9), register(Register.x12)));
    final lvlSkip = label('lvlskip');
    beq(register(Register.x11), register(Register.x0), lvlSkip);

    // Print: LVL TAP=<n> RCS=<n> SLK=<n> -> <w0> <w1> DV=<b> BD=<b>
    _printStr('LVL TAP=');
    register(Register.x14).bind(mv(register(Register.x27)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x26)));
    _printHexX14();
    _printStr(' SLK=');
    register(Register.x14).bind(mv(register(Register.x25)));
    _printHexX14();
    _printStr(' -> ');
    register(Register.x14).bind(mv(register(Register.x4)));
    _printHexX14();
    _printChar(0x20);
    register(Register.x14).bind(mv(register(Register.x5)));
    _printHexX14();
    _printStr(' DV=');
    register(Register.x14).bind(andi(srli(register(Register.x8), 12), 0x1));
    _printHexX14();
    _printStr(' BD=');
    register(Register.x14).bind(andi(srli(register(Register.x8), 11), 0x1));
    _printHexX14();
    _crlf();
    placeLabel(lvlSkip);

    // Latch LVLBEST: FIRST fully-matching combo. Record only if x9 (match) and
    // not already latched (x20==0).
    final bestDone = label('lvlbestdone');
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

    // Latch LVLDV: FIRST combo where DATAVALID-seen OR BURSTDET-seen was set.
    // Record only if x12 (dv-or-bd) nonzero and not already latched (x28==0).
    final dvDone = label('lvldvdone');
    beq(register(Register.x12), register(Register.x0), dvDone); // no strobe
    register(Register.x11).bind(li(1));
    beq(register(Register.x28), register(Register.x11), dvDone); // already set
    register(Register.x28).bind(li(1)); // latch dv-found
    register(Register.x29).bind(mv(register(Register.x27))); // first-dv TAP
    register(Register.x30).bind(mv(register(Register.x26))); // first-dv RCS
    placeLabel(dvDone);

    // INNER step: RDSLACK += 1; repeat while < slkTop (0..7).
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
    //   LVLBEST TAP=<n> RCS=<n> SLK=<n>  (first full match) or NONE
    //   LVLDV   TAP=<n> RCS=<n>          (first strobe)     or NONE
    register(Register.x19).bind(li(0));
    final sumTop = label('lvlsumtop');

    // LVLBEST line.
    _printStr('LVLBEST ');
    final bestNone = label('lvlbestnone');
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
    final bestSumDone = label('lvlbestsumdone');
    jal(bestSumDone);
    placeLabel(bestNone);
    _printStr('NONE');
    placeLabel(bestSumDone);
    _crlf();

    // LVLDV line.
    _printStr('LVLDV ');
    final dvNone = label('lvldvnone');
    beq(register(Register.x28), register(Register.x0), dvNone);
    _printStr('TAP=');
    register(Register.x14).bind(mv(register(Register.x29)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x30)));
    _printHexX14();
    final dvSumDone = label('lvldvsumdone');
    jal(dvSumDone);
    placeLabel(dvNone);
    _printStr('NONE');
    placeLabel(dvSumDone);
    _crlf();

    // Repeat the summary block 3 times total.
    register(Register.x19).bind(addi(register(Register.x19), 1));
    register(Register.x11).bind(li(3));
    blt(register(Register.x19), register(Register.x11), sumTop);

    // Layer-2 additive-WRDLY calibration sweep. Remaining bug is the DQ1/5/9
    // rise-beat float (0x0222 OR-mask on word0). reg7 WRDLY is additive: each
    // per-lane offset retards the DQSW270 launch on top of the WL-trained pos
    // (preserving WL strobe-centering). The sweep finds the per-lane offset that
    // clears the float plus the read combo (RCS/SLK) that reads it back clean.
    // Ordering: read WLRES, spin until wlDone==1 before any reg7 write (the
    // additive base wlBasePos latches only once WL replay completes). Do not
    // reset the controller between WL and the sweep (that clobbers wlBasePos).
    register(Register.x10).bind(li(regWlres));
    register(Register.x24).bind(lw(register(Register.x10)));
    _printStr('WLRES lane0=');
    register(Register.x14).bind(andi(register(Register.x24), 0xF));
    _printHexX14();
    _printStr(' lane1=');
    register(Register.x14).bind(andi(srli(register(Register.x24), 4), 0xF));
    _printHexX14();
    _printStr(' done=');
    register(Register.x14).bind(andi(srli(register(Register.x24), 8), 0x1));
    _printHexX14();
    _crlf();

    // SPIN until reg6[8] (wlDone) == 1 - WL replay must complete (wlBasePos
    // latched) before any additive reg7 apply.
    final wlWaitLbl = label('wlwait');
    register(Register.x10).bind(li(regWlres));
    register(Register.x11).bind(lw(register(Register.x10)));
    register(Register.x11).bind(andi(srli(register(Register.x11), 8), 0x1));
    beq(register(Register.x11), register(Register.x0), wlWaitLbl);

    const wp0 = 0x40DE0000;
    const wp1 = 0x40DE1111;
    const wp2 = 0x40DE2222;
    const wp3 = 0x40DE3333;

    // Park RDTAP=0 (reg0=0 + reg1 SET) once - the live read eye (Layer-1 data).
    register(Register.x10).bind(li(regRdtap));
    register(Register.x11).bind(li(0));
    sw(register(Register.x10), register(Register.x11)); // reg0 RDTAP target = 0
    register(Register.x10).bind(li(regCtl));
    register(Register.x11).bind(li(0x1)); // SET: load the tap walk
    sw(register(Register.x10), register(Register.x11));

    // 4 nested loops, body emitted once. x25=RCS (reg4) {0,1,2} OUTER, x26=SLK
    // (reg2) 0..7, x27=lane0Off (WRDLY [3:0]) 0..3, x28=lane1Off (WRDLY [7:4])
    // 0..3 INNER = 384 combos. CALBEST (first CLR): x20 found, x21 RCS, x22 SLK,
    // x23 l0, x24 l1. Word results x4..x7.
    const calWrDir =
        0; // WRDIRECTION (reg7 bit8); flip to 1 if dir=0 clears none
    register(Register.x20).bind(li(0)); // CALBEST found flag

    register(Register.x25).bind(li(0)); // RCS
    final calRcsLbl = label('calrcs');
    register(Register.x26).bind(li(0)); // SLK
    final calSlkLbl = label('calslk');
    register(Register.x27).bind(li(0)); // lane0Off
    final calL0Lbl = label('call0');
    register(Register.x28).bind(li(0)); // lane1Off
    final calL1Lbl = label('call1');

    // Program reg4=RCS, reg2=SLK.
    register(Register.x10).bind(li(regReadClkSel));
    sw(register(Register.x10), register(Register.x25)); // reg4 READCLKSEL = RCS
    register(Register.x10).bind(li(regRdslack));
    sw(register(Register.x10), register(Register.x26)); // reg2 RDSLACK = SLK
    // reg7 = (calWrDir<<8) | (lane1Off<<4) | lane0Off  (additive per-lane offset;
    // the reg7 edge steps each lane to WL_base + laneOff).
    register(Register.x11).bind(slli(register(Register.x28), 4)); // lane1Off<<4
    register(
      Register.x11,
    ).bind(or(register(Register.x11), register(Register.x27)));
    if (calWrDir != 0) {
      register(Register.x12).bind(li(calWrDir << 8));
      register(
        Register.x11,
      ).bind(or(register(Register.x11), register(Register.x12)));
    }
    register(Register.x10).bind(li(regWrdly));
    sw(register(Register.x10), register(Register.x11)); // apply edge -> WRMOVE

    // Write the 4-word pattern to dramBase 0x0/0x4/0x8/0xC.
    register(Register.x10).bind(li(dramBase + 0x0));
    register(Register.x11).bind(li(wp0));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0x4));
    register(Register.x11).bind(li(wp1));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0x8));
    register(Register.x11).bind(li(wp2));
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(dramBase + 0xC));
    register(Register.x11).bind(li(wp3));
    sw(register(Register.x10), register(Register.x11));

    // Warm-up read (absorb write->read turnaround), then read w0..w3.
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

    // Score CLR (x12) iff all 4 words land exactly; Z0 (x19) iff (w0&0x0222)==0.
    register(Register.x12).bind(li(1)); // CLR, cleared on any mismatch
    final calClrFail = label('calclrfail');
    final calClrDone = label('calclrdone');
    register(Register.x11).bind(li(wp0));
    final cc1 = label('calcc1');
    beq(register(Register.x4), register(Register.x11), cc1);
    jal(calClrFail);
    placeLabel(cc1);
    register(Register.x11).bind(li(wp1));
    final cc2 = label('calcc2');
    beq(register(Register.x5), register(Register.x11), cc2);
    jal(calClrFail);
    placeLabel(cc2);
    register(Register.x11).bind(li(wp2));
    final cc3 = label('calcc3');
    beq(register(Register.x6), register(Register.x11), cc3);
    jal(calClrFail);
    placeLabel(cc3);
    register(Register.x11).bind(li(wp3));
    final cc4 = label('calcc4');
    beq(register(Register.x7), register(Register.x11), cc4);
    jal(calClrFail);
    placeLabel(cc4);
    jal(calClrDone);
    placeLabel(calClrFail);
    register(Register.x12).bind(li(0)); // a word mismatched
    placeLabel(calClrDone);
    // Z0 = ((w0 & 0x0222) == 0) ? 1 : 0.
    register(Register.x11).bind(andi(register(Register.x4), 0x222));
    register(Register.x19).bind(li(0));
    final calNoZ0Set = label('calnoz0set');
    bne(register(Register.x11), register(Register.x0), calNoZ0Set);
    register(Register.x19).bind(li(1)); // Z0 = float on word0 cleared
    placeLabel(calNoZ0Set);

    // Print ONLY if CLR (x12) or Z0 (x19) - keep the UART readable.
    register(
      Register.x11,
    ).bind(or(register(Register.x12), register(Register.x19)));
    final calSkip = label('calskip');
    beq(register(Register.x11), register(Register.x0), calSkip);
    _printStr('CAL l0=');
    register(Register.x14).bind(mv(register(Register.x27)));
    _printHexX14();
    _printStr(' l1=');
    register(Register.x14).bind(mv(register(Register.x28)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x25)));
    _printHexX14();
    _printStr(' SLK=');
    register(Register.x14).bind(mv(register(Register.x26)));
    _printHexX14();
    _printStr(' -> ');
    register(Register.x14).bind(mv(register(Register.x4)));
    _printHexX14();
    _printChar(0x20);
    register(Register.x14).bind(mv(register(Register.x5)));
    _printHexX14();
    _printChar(0x20);
    register(Register.x14).bind(mv(register(Register.x6)));
    _printHexX14();
    _printChar(0x20);
    register(Register.x14).bind(mv(register(Register.x7)));
    _printHexX14();
    // CLR wins the token; else Z0 (the print gate guarantees at least one).
    final calTokZ0 = label('caltokz0');
    final calTokDone = label('caltokdone');
    beq(register(Register.x12), register(Register.x0), calTokZ0);
    _printStr(' CLR');
    jal(calTokDone);
    placeLabel(calTokZ0);
    _printStr(' Z0');
    placeLabel(calTokDone);
    _crlf();
    placeLabel(calSkip);

    // Latch CALBEST: FIRST full CLR combo. Record only if CLR (x12!=0) and not
    // already latched (x20==0).
    final calBestDone = label('calbestdone');
    beq(register(Register.x12), register(Register.x0), calBestDone); // no CLR
    register(Register.x11).bind(li(1));
    beq(
      register(Register.x20),
      register(Register.x11),
      calBestDone,
    ); // already set
    register(Register.x20).bind(li(1)); // latch found
    register(Register.x21).bind(mv(register(Register.x25))); // best RCS
    register(Register.x22).bind(mv(register(Register.x26))); // best SLK
    register(Register.x23).bind(mv(register(Register.x27))); // best lane0Off
    register(Register.x24).bind(mv(register(Register.x28))); // best lane1Off
    placeLabel(calBestDone);

    // INNER step: lane1Off += 1; repeat while < 4.
    register(Register.x28).bind(addi(register(Register.x28), 1));
    register(Register.x11).bind(li(4));
    blt(register(Register.x28), register(Register.x11), calL1Lbl);
    // lane0Off step: += 1; repeat while < 4.
    register(Register.x27).bind(addi(register(Register.x27), 1));
    register(Register.x11).bind(li(4));
    blt(register(Register.x27), register(Register.x11), calL0Lbl);
    // SLK step: += 1; repeat while < 8.
    register(Register.x26).bind(addi(register(Register.x26), 1));
    register(Register.x11).bind(li(8));
    blt(register(Register.x26), register(Register.x11), calSlkLbl);
    // OUTER RCS step: += 1; repeat while < 3 (RCS {0,1,2}).
    register(Register.x25).bind(addi(register(Register.x25), 1));
    register(Register.x11).bind(li(3));
    blt(register(Register.x25), register(Register.x11), calRcsLbl);

    // CALBEST summary, looped 3x for UART-glitch tolerance. x19 = counter (not
    // x17/x18, the print helpers).
    register(Register.x19).bind(li(0));
    final calSumTop = label('calsumtop');
    _printStr('CALBEST ');
    final calBestNone = label('calbestnone');
    beq(register(Register.x20), register(Register.x0), calBestNone);
    _printStr('l0=');
    register(Register.x14).bind(mv(register(Register.x23)));
    _printHexX14();
    _printStr(' l1=');
    register(Register.x14).bind(mv(register(Register.x24)));
    _printHexX14();
    _printStr(' RCS=');
    register(Register.x14).bind(mv(register(Register.x21)));
    _printHexX14();
    _printStr(' SLK=');
    register(Register.x14).bind(mv(register(Register.x22)));
    _printHexX14();
    final calSumDone = label('calsumdone');
    jal(calSumDone);
    placeLabel(calBestNone);
    _printStr('NONE');
    placeLabel(calSumDone);
    _crlf();
    register(Register.x19).bind(addi(register(Register.x19), 1));
    register(Register.x11).bind(li(3));
    blt(register(Register.x19), register(Register.x11), calSumTop);

    // 2-phase write-launch sweep. word0 (first 2 write beats on dqsw270) floats
    // ~0x02DE on DQ1/DQ2 because the write launch is off-center vs the DQS
    // preamble. Prior write sweeps were confounded by a fixed read combo, but the
    // read eye moves per build:
    //   PHASE 1: find the read eye for word0 (DYNDELAY=0, sweep the read), latch
    //            (RDTAP,RCS,SLK) where word0 is most readable.
    //   PHASE 2: at that read eye, sweep the write launch (DYNDELAY + WRDIRECTION)
    //            and score word0 - the non-confounded write-launch test.
    // Stays x0..x30 (x31 is codegen scratch; a tracker there bricks the boot).
    const wtpark0 = 0x40DE0000;
    const wtpark1 = 0x40DE1111;
    const wtpark2 = 0x40DE2222;
    const wtpark3 = 0x40DE3333;

    // Helper-free inline: write the 4-word pattern + warm-up read + read word0
    // into x4 (uses x10/x11/x14 scratch). Emitted at each measurement point.
    void writeReadW0() {
      register(Register.x10).bind(li(dramBase + 0x0));
      register(Register.x11).bind(li(wtpark0));
      sw(register(Register.x10), register(Register.x11));
      register(Register.x10).bind(li(dramBase + 0x4));
      register(Register.x11).bind(li(wtpark1));
      sw(register(Register.x10), register(Register.x11));
      register(Register.x10).bind(li(dramBase + 0x8));
      register(Register.x11).bind(li(wtpark2));
      sw(register(Register.x10), register(Register.x11));
      register(Register.x10).bind(li(dramBase + 0xC));
      register(Register.x11).bind(li(wtpark3));
      sw(register(Register.x10), register(Register.x11));
      register(Register.x10).bind(li(dramBase + 0x0));
      register(Register.x14).bind(lw(register(Register.x10))); // warm-up
      register(Register.x10).bind(li(dramBase + 0x0));
      register(Register.x4).bind(lw(register(Register.x10))); // w0
    }

    // --- PHASE 1: find the read eye for word0 (DYNDELAY=0). --------------------
    // Set reg8 DYNDELAY = 0 (no write trim) - measure the READ only.
    register(Register.x10).bind(li(regWtrim));
    sw(register(Register.x10), register(Register.x0)); // reg8 = 0

    // Latched eye: x20 = min (w0 & 0x0FFF) so far (init 0x1000), x21 = best RDTAP,
    // x22 = best RCS, x23 = best SLK. x4 = w0.
    register(Register.x20).bind(li(0x1000)); // min residue
    register(Register.x21).bind(li(0)); // best RDTAP
    register(Register.x22).bind(li(0)); // best RCS
    register(Register.x23).bind(li(0)); // best SLK

    // 3 nested loops: x25 = RDTAP (0,8,..,120 step 8), x26 = RCS (0..7), x27 =
    // SLK (0..7). Step 8 not 16: the word0 eye is at tap 88 (0x58), which a
    // step-16 grid skips.
    register(Register.x25).bind(li(0)); // RDTAP
    final p1TapLbl = label('p1tap');
    register(Register.x26).bind(li(0)); // RCS
    final p1RcsLbl = label('p1rcs');
    register(Register.x27).bind(li(0)); // SLK
    final p1SlkLbl = label('p1slk');

    // Program reg0=RDTAP + reg1 SET, reg4=RCS, reg2=SLK.
    register(Register.x10).bind(li(regRdtap));
    sw(register(Register.x10), register(Register.x25)); // reg0 RDTAP
    register(Register.x10).bind(li(regCtl));
    register(Register.x11).bind(li(0x1)); // SET
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(regReadClkSel));
    sw(register(Register.x10), register(Register.x26)); // reg4 RCS
    register(Register.x10).bind(li(regRdslack));
    sw(register(Register.x10), register(Register.x27)); // reg2 SLK

    writeReadW0();
    register(Register.x11).bind(andi(register(Register.x4), 0xFFF)); // residue

    // New min? latch (RDTAP,RCS,SLK) = the read eye for word0, and print the
    // descent (RDMIN) so the running-min is visible on hardware as it falls.
    final p1Skip = label('p1skip');
    register(
      Register.x12,
    ).bind(slt(register(Register.x11), register(Register.x20)));
    beq(register(Register.x12), register(Register.x0), p1Skip);
    register(Register.x20).bind(mv(register(Register.x11))); // new min residue
    register(Register.x21).bind(mv(register(Register.x25))); // RDTAP
    register(Register.x22).bind(mv(register(Register.x26))); // RCS
    register(Register.x23).bind(mv(register(Register.x27))); // SLK
    _printStr('RDMIN tap=');
    register(Register.x14).bind(mv(register(Register.x25)));
    _printHexX14();
    _printStr(' rcs=');
    register(Register.x14).bind(mv(register(Register.x26)));
    _printHexX14();
    _printStr(' slk=');
    register(Register.x14).bind(mv(register(Register.x27)));
    _printHexX14();
    _printStr(' res=');
    register(Register.x14).bind(mv(register(Register.x20)));
    _printHexX14();
    _crlf();
    placeLabel(p1Skip);

    // INNER SLK += 1 < 8; RCS += 1 < 8; RDTAP += 8 < 128 (0,8,..,120 = hits 88).
    register(Register.x27).bind(addi(register(Register.x27), 1));
    register(Register.x11).bind(li(8));
    blt(register(Register.x27), register(Register.x11), p1SlkLbl);
    register(Register.x26).bind(addi(register(Register.x26), 1));
    register(Register.x11).bind(li(8));
    blt(register(Register.x26), register(Register.x11), p1RcsLbl);
    register(Register.x25).bind(addi(register(Register.x25), 8));
    register(Register.x11).bind(li(128));
    blt(register(Register.x25), register(Register.x11), p1TapLbl);

    // Print the latched read eye: RDEYE tap=<> rcs=<> slk=<> res=<>.
    _printStr('RDEYE tap=');
    register(Register.x14).bind(mv(register(Register.x21)));
    _printHexX14();
    _printStr(' rcs=');
    register(Register.x14).bind(mv(register(Register.x22)));
    _printHexX14();
    _printStr(' slk=');
    register(Register.x14).bind(mv(register(Register.x23)));
    _printHexX14();
    _printStr(' res=');
    register(Register.x14).bind(mv(register(Register.x20)));
    _printHexX14();
    _crlf();

    // --- PHASE 2: sweep the write launch at the latched read eye. --------------
    // Program the LATCHED eye (x21 RDTAP + SET, x22 RCS, x23 SLK) ONCE - fixed.
    register(Register.x10).bind(li(regRdtap));
    sw(register(Register.x10), register(Register.x21)); // reg0 = best RDTAP
    register(Register.x10).bind(li(regCtl));
    register(Register.x11).bind(li(0x1)); // SET
    sw(register(Register.x10), register(Register.x11));
    register(Register.x10).bind(li(regReadClkSel));
    sw(register(Register.x10), register(Register.x22)); // reg4 = best RCS
    register(Register.x10).bind(li(regRdslack));
    sw(register(Register.x10), register(Register.x23)); // reg2 = best SLK

    // Phase-2 trackers (x21/x22/x23 must stay LIVE - they are the fixed eye, but
    // not re-read in phase 2, so reuse only x20/x24/x27..x30):
    //   x20 = min residue (reinit), x27 = best packed {dyn<<1 | dir}, x24 = best
    //   w0, x29 = clean flag, x30 = clean packed {dyn<<1 | dir}.
    register(Register.x20).bind(li(0x1000)); // phase-2 min residue
    register(Register.x29).bind(li(0)); // clean found flag

    // 2 nested loops: x25 = DYNDELAY (0,8,..,120 step 8), x26 = dir (0,1).
    register(Register.x25).bind(li(0)); // DYNDELAY
    final p2DynLbl = label('p2dyn');
    register(Register.x26).bind(li(0)); // dir
    final p2DirLbl = label('p2dir');

    // Program reg8 = DYNDELAY (x25), reg7 = (dir<<8) (lane0 tap 0, dir bit).
    register(Register.x10).bind(li(regWtrim));
    sw(register(Register.x10), register(Register.x25)); // reg8 DYNDELAY
    register(Register.x11).bind(slli(register(Register.x26), 8)); // dir<<8
    register(Register.x10).bind(li(regWrdly));
    sw(register(Register.x10), register(Register.x11)); // reg7 WRDLY (dir bit)

    writeReadW0();
    register(Register.x11).bind(andi(register(Register.x4), 0xFFF)); // residue

    // New min? print + latch best.
    final p2Skip = label('p2skip');
    register(
      Register.x12,
    ).bind(slt(register(Register.x11), register(Register.x20)));
    beq(register(Register.x12), register(Register.x0), p2Skip);
    register(Register.x20).bind(mv(register(Register.x11))); // new min residue
    register(Register.x27).bind(slli(register(Register.x25), 1)); // dyn<<1
    register(
      Register.x27,
    ).bind(or(register(Register.x27), register(Register.x26)));
    register(Register.x24).bind(mv(register(Register.x4))); // best w0
    _printStr('WL dyn=');
    register(Register.x14).bind(mv(register(Register.x25)));
    _printHexX14();
    _printStr(' dir=');
    register(Register.x14).bind(mv(register(Register.x26)));
    _printHexX14();
    _printStr(' -> w0=');
    register(Register.x14).bind(mv(register(Register.x4)));
    _printHexX14();
    _crlf();
    placeLabel(p2Skip);

    // CLEAN: latch FIRST (dyn,dir) where w0 == 0x40DE0000. x29 flag, x30 packed.
    final p2CleanDone = label('p2cleandone');
    register(Register.x12).bind(li(1));
    beq(
      register(Register.x29),
      register(Register.x12),
      p2CleanDone,
    ); // already set
    register(Register.x12).bind(li(wtpark0));
    final p2NotClean = label('p2notclean');
    bne(register(Register.x4), register(Register.x12), p2NotClean);
    register(Register.x29).bind(li(1)); // clean found
    register(Register.x30).bind(slli(register(Register.x25), 1)); // dyn<<1
    register(
      Register.x30,
    ).bind(or(register(Register.x30), register(Register.x26)));
    placeLabel(p2NotClean);
    placeLabel(p2CleanDone);

    // INNER dir += 1 < 2; DYNDELAY += 8 < 128.
    register(Register.x26).bind(addi(register(Register.x26), 1));
    register(Register.x11).bind(li(2));
    blt(register(Register.x26), register(Register.x11), p2DirLbl);
    register(Register.x25).bind(addi(register(Register.x25), 8));
    register(Register.x11).bind(li(128));
    blt(register(Register.x25), register(Register.x11), p2DynLbl);

    // Summary, looped 3x for UART-glitch tolerance. x19 = counter.
    register(Register.x19).bind(li(0));
    final wtSumTop = label('wtsumtop');
    // WLBEST: cleanest word0 (global-min residue) - always present. Unpack x27 =
    // (dyn<<1 | dir).
    _printStr('WLBEST dyn=');
    register(
      Register.x14,
    ).bind(srli(register(Register.x27), 1)); // dyn = x27>>1
    _printHexX14();
    _printStr(' dir=');
    register(Register.x14).bind(andi(register(Register.x27), 0x1)); // dir
    _printHexX14();
    _printStr(' w0=');
    register(Register.x14).bind(mv(register(Register.x24)));
    _printHexX14();
    _crlf();
    // WLCLEAN: the (dyn,dir) that hit exact 0x40DE0000, or NONE. Unpack x30.
    _printStr('WLCLEAN ');
    final wtCleanNone = label('wlcleannone');
    beq(register(Register.x29), register(Register.x0), wtCleanNone);
    _printStr('dyn=');
    register(
      Register.x14,
    ).bind(srli(register(Register.x30), 1)); // dyn = x30>>1
    _printHexX14();
    _printStr(' dir=');
    register(Register.x14).bind(andi(register(Register.x30), 0x1)); // dir
    _printHexX14();
    final wtCleanSumDone = label('wlcleansumdone');
    jal(wtCleanSumDone);
    placeLabel(wtCleanNone);
    _printStr('NONE');
    placeLabel(wtCleanSumDone);
    _crlf();
    register(Register.x19).bind(addi(register(Register.x19), 1));
    register(Register.x11).bind(li(3));
    blt(register(Register.x19), register(Register.x11), wtSumTop);

    final done = label('done');
    jal(done);
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
