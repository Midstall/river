import 'dart:typed_data';

import 'package:river/river.dart';
import 'package:river_adl/river_adl.dart';

/// Xilinx ISERDESE2 (Arty S7) DDR read-leveling boot program.
///
/// The ddr3Fast (ISERDESE2) read path returns real DQ but the per-DQ IDELAYE2
/// eye is uncentered and the ISERDESE2 BITSLIP beat rotation is arbitrary. This
/// centers each DQ lane's read eye against the DDR3 MPR page0 predefined pattern
/// (0b01010101), a write-independent target the DRAM hardwires, via the DDR
/// train-control MMIO block (built with `--ddr-trainable`):
///
///   reg10 @ trainCtrlBase+0x50  IDELAY: [4:0]tap(CNTVALUEIN) [5]LD [9:6]lane
///   reg11 @ trainCtrlBase+0x58  BITSLIP: [3:0]lane [4]slip
///   reg3  @ trainCtrlBase+0x18  STATUS  (read-only; bit0 = IDELAYCTRL RDY)
///   reg12 @ trainCtrlBase+0x60  WINDOW  [3:0] ctrl100 read-pipe tap
///
/// Golden target: the MPR pattern gives beat0=0, beat1=1, ... on every DQ lane.
/// Each read word = {fallBeat<<16 | riseBeat}, so a centered read = 0xFFFF0000.
/// Per lane L: rise bit = bit L (=0), fall bit = bit L+16 (=1).
///
/// Algorithm (all RUNTIME loops, body emitted once; x0..x30 only, x31 scratch):
///  1. UART init; print ST=/RDY. Pin reg12 = window 5 (the live burst cycle).
///  2. Find the global BITSLIP (0..7) putting the most lanes in the 0xFFFF0000
///     orientation at tap 16; apply it. Report `BS<n>=<count>` + `BEST BS=`.
///  3. Per DQ lane: sweep IDELAY tap 0..31 (reg10 VAR_LOAD), judge only lane L's
///     two MPR bits (rise=0, fall=1), record the contiguous pass window [lo,hi]
///     and park at center. Report `LVLX L=<lane> TAP=<center> LO=<lo> HI=<hi>`.
///  4. VERIFY: read word0 16x with centered taps; count hits vs 0xFFFF0000 and
///     0x0000FFFF + a sample. Report `VER FF00=<n> 00FF=<n> S=<sample>`.
///  5. Loop the centering forever (UART-glitch tolerance).
///
/// Position-independent; only the UART, DRAM and train-control bases are
/// absolute. MPR reads ignore the address, so no DRAM bytes are modified.
class RiverDdrLevelXilinx extends Module {
  @override
  final RiscVIsaConfig isa;

  RiverDdrLevelXilinx({
    required this.isa,
    required int uartBase,
    required int dramBase,
    required int trainCtrlBase,
    int clockHz = 48000000,
    int baud = 115200,
    // Number of DQ lanes (each has its own IDELAYE2 tap). reg10's lane field is
    // [3:0], so this must stay <= 16. Arty S7 DDR3 is x16.
    int dataBits = 16,
    // BITSLIP rotations to probe. The fabric BITSLIP re-pairs the two half-beat
    // captures; width-2 has up to 4 distinct rotations.
    int bitslipTop = 4,
    // MPR mode: when true (--ddr-mpr build), run the write-independent MPR
    // read-eye centering (DRAM returns the 0101 pattern). When false (real
    // build), skip centering, park all lanes at [bakedCenterTap] + window 5, and
    // run the A/B/C write-store test (does the array store what we write).
    bool mprMode = true,
    // Per-lane IDELAY center tap the MPR centering converged to (uniform across
    // all 16 lanes). Parks a clean read in the non-MPR write test.
    int bakedCenterTap = 17,
  }) {
    // Train-control register addresses (8-byte strided, decoded on bus[6:3]).
    final regRdslack = trainCtrlBase + 0x10; // reg2  RDSLACK (read-back only)
    final regStatus = trainCtrlBase + 0x18; // reg3  STATUS (read-only)
    final regIdelay =
        trainCtrlBase + 0x50; // reg10 IDELAY [4:0]tap [5]LD [9:6]lane
    final regBitslip = trainCtrlBase + 0x58; // reg11 BITSLIP [3:0]lane [4]slip
    final regWindow = trainCtrlBase + 0x60; // reg12 WINDOW [3:0]ctrl83 read tap

    const tapTop = 32; // IDELAYE2 5-bit counter: taps 0..31.
    const kReads = 8; // per-tap stability reads (reject marginal-eye taps).

    // ns16550a setup (x13 holds uartBase for the whole program; the print
    // helpers read it).
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

    // Liveness: a fixed line + hex self-test so a UART reader knows the core is
    // alive before the slow leveling sweep.
    _printStr('LVLX START');
    _crlf();
    register(Register.x14).bind(li(0x12345678));
    _printHexX14();
    _crlf();

    // One-shot STATUS snapshot (informational).
    register(Register.x10).bind(li(regStatus));
    register(Register.x14).bind(lw(register(Register.x10)));
    _printStr('LVLX ST=');
    _printHexX14();
    _crlf();

    // Keep regRdslack documented in the register map (read-back parity only on
    // this PHY); assert suppresses the unused-warning.
    assert(regRdslack > 0);

    // A 3D MPR window sweep (reg12 window x reg11 bitslip x reg10 IDELAY)
    // localized the DRAM read burst to ctrl100 read-pipe window 5 (windows 4/5/6
    // carry live tap-varying data, center 5). Pin here.
    const foundWin = 5;
    // MPR centering leaves BITSLIP at its reset default and detects the resulting
    // orientation instead (a whole-beat slip cannot swap rise<->fall). assert
    // keeps regBitslip documented and suppresses the unused-warning.
    assert(regBitslip > 0);

    // Read dramBase+0 into x4 (word0) and dramBase+4 into x5 (word1), with a
    // warm-up read first to absorb the read-pipe turnaround. Position-independent.
    void readW0W1() {
      register(Register.x10).bind(li(dramBase + 0x0));
      register(Register.x14).bind(lw(register(Register.x10))); // warm-up
      register(Register.x10).bind(li(dramBase + 0x0));
      register(Register.x4).bind(lw(register(Register.x10))); // word0
      register(Register.x10).bind(li(dramBase + 0x4));
      register(Register.x5).bind(lw(register(Register.x10))); // word1
    }

    // Set ALL 16 lanes' IDELAY to an absolute tap (reg10 = tap|LD|lane<<6, one
    // VAR_LOAD per lane). reg10 lane field is [9:6], tap [4:0], LD [5].
    void setAllTaps(int tap) {
      for (var l = 0; l < dataBits; l++) {
        register(Register.x10).bind(li(regIdelay));
        register(Register.x11).bind(li((l << 6) | 0x20 | (tap & 0x1f)));
        sw(register(Register.x10), register(Register.x11));
      }
    }

    // MPR per-lane read-eye centering (window 5, against the DDR3 MPR page0 0101
    // pattern). The MPR read path (skip-ACTIVATE, A[1:0]=00) returns the
    // write-independent pattern, so each DQ lane's eye centers against a known
    // target. Golden target: beat0=0, beat1=1, ...; each read word =
    // {fallBeat<<16 | riseBeat} so a centered read = 0xFFFF0000. Per lane L: rise
    // bit = bit L (0), fall bit = bit L+16 (1); laneMask = (1<<L)|(1<<L+16).
    // A whole-line BITSLIP can land the 0x0000FFFF orientation instead, so first
    // find the global bitslip putting the most lanes in 0xFFFF0000 at tap 16,
    // then per-lane sweep IDELAY tap 0..31 for the pass window and park at center.
    // Register plan: x20 lane, x21 lo, x22 hi, x23 center, x24 scratch, x25 tap,
    // x26 counter, x27 best-bitslip, x28 best-count, x29 cur-count, x30 bitslip
    // index, x9 pass-flag, x8 laneField.

    // Non-MPR (real) build: write-store test with the baked read eye. Park every
    // lane at [bakedCenterTap] + window 5 for a clean read, then probe writes:
    // write A to dramBase and read (A=); write a different B to the same address
    // and read (B=); read an unwritten address (C=). A!=B => the write lands;
    // A!=C => reads track address.
    if (!mprMode) {
      final wtLoop = label('lvlxwtloop');
      _printStr('LVLX WRITE TEST');
      _crlf();
      register(Register.x10).bind(li(regStatus));
      register(Register.x14).bind(lw(register(Register.x10)));
      _printStr('ST=');
      _printHexX14();
      _crlf();
      // Pin window 5 + park all lanes at the baked center tap for a clean read.
      register(Register.x10).bind(li(regWindow));
      register(Register.x11).bind(li(foundWin));
      sw(register(Register.x10), register(Register.x11));
      setAllTaps(bakedCenterTap);

      void wtWrite(int off, int val) {
        register(Register.x10).bind(li(dramBase + off));
        register(Register.x11).bind(li(val));
        sw(register(Register.x10), register(Register.x11));
      }

      void wtRead(int off) {
        register(Register.x10).bind(li(dramBase + off));
        register(Register.x14).bind(lw(register(Register.x10))); // warm-up
        register(Register.x10).bind(li(dramBase + off));
        register(Register.x4).bind(lw(register(Register.x10)));
      }

      void wtPrint(String tag) {
        _printStr(tag);
        register(Register.x14).bind(mv(register(Register.x4)));
        _printHexX14();
        _crlf();
      }

      // A: write 0x40DE0000 to +0 and read back.
      wtWrite(0x0, 0x40DE0000);
      wtRead(0x0);
      wtPrint('A=');
      // B: write a DIFFERENT value to the SAME address and read back.
      wtWrite(0x0, 0x33221100);
      wtRead(0x0);
      wtPrint('B=');
      // C: read an unwritten address (+0x1000).
      wtRead(0x1000);
      wtPrint('C=');
      // D: write 0x0000CAFE to +0x40 and read it (a second distinct addr/value).
      wtWrite(0x40, 0x0000CAFE);
      wtRead(0x40);
      wtPrint('D=');

      // Read-eye verify: write 0x40DE0000 to +0, sweep IDELAY tap 0..31 (all
      // lanes) reading +0, dump WT<tap>=<read>. A clean read is stable across the
      // tap-10..24 eye band; if the written value ever appears the write lands.
      // A stable band != the written value means reads are clean and the write is
      // the residual failure. x25=tap, x8=laneField=0.
      wtWrite(0x0, 0x40DE0000);
      register(Register.x25).bind(li(0)); // tap
      final wtEye = label('lvlxwteye');
      // set ALL lanes to this tap (reuse setAllTaps semantics inline for a var).
      register(Register.x26).bind(li(0)); // lane
      final wtEyeLane = label('lvlxwteyelane');
      register(Register.x10).bind(li(regIdelay));
      register(Register.x11).bind(slli(register(Register.x26), 6)); // lane<<6
      register(
        Register.x11,
      ).bind(or(register(Register.x11), register(Register.x25)));
      register(Register.x11).bind(ori(register(Register.x11), 0x20));
      sw(register(Register.x10), register(Register.x11));
      register(Register.x26).bind(addi(register(Register.x26), 1));
      register(Register.x12).bind(li(dataBits));
      blt(register(Register.x26), register(Register.x12), wtEyeLane);
      wtRead(0x0);
      _printStr('WT');
      register(Register.x14).bind(mv(register(Register.x25)));
      _printHexX14();
      _printChar(0x3D);
      register(Register.x14).bind(mv(register(Register.x4)));
      _printHexX14();
      _crlf();
      register(Register.x25).bind(addi(register(Register.x25), 1));
      register(Register.x11).bind(li(tapTop));
      blt(register(Register.x25), register(Register.x11), wtEye);
      // Restore the baked center for the next A/B/C/D pass.
      setAllTaps(bakedCenterTap);

      // Human/tool-paced delay, then loop forever (bottom-tested, ROM-fit).
      register(Register.x24).bind(li(0x200000));
      final wtDelay = label('lvlxwtdelay');
      register(Register.x24).bind(addi(register(Register.x24), -1));
      bne(register(Register.x24), register(Register.x0), wtDelay);
      jal(wtLoop);
      return;
    }

    final diagLoop = label('lvlxdiag');
    _printStr('LVLX MPR EYE');
    _crlf();
    register(Register.x10).bind(li(regStatus));
    register(Register.x14).bind(lw(register(Register.x10)));
    _printStr('ST=');
    _printHexX14();
    _crlf();

    // DIAGNOSTIC: sweep the read window 0..7 (reg12) at tap 16 and dump word0 so
    // a UART reader can see where the MPR pattern (target 0xFFFF0000) lands.
    setAllTaps(16);
    register(Register.x30).bind(li(0)); // window
    final winDiag = label('lvlxwindiag');
    register(Register.x10).bind(li(regWindow));
    register(Register.x11).bind(mv(register(Register.x30)));
    sw(register(Register.x10), register(Register.x11));
    readW0W1();
    _printChar(0x57); // 'W'
    register(Register.x14).bind(mv(register(Register.x30)));
    _printHexNibbleX14();
    _printChar(0x3D); // '='
    register(Register.x14).bind(mv(register(Register.x4)));
    _printHexX14();
    _crlf();
    register(Register.x30).bind(addi(register(Register.x30), 1));
    register(Register.x11).bind(li(8));
    blt(register(Register.x30), register(Register.x11), winDiag);

    // Pin the read window to 5 (the live burst-landing cycle).
    register(Register.x10).bind(li(regWindow));
    register(Register.x11).bind(li(foundWin));
    sw(register(Register.x10), register(Register.x11));

    // STEP 1: detect the MPR orientation (golden reference word x19). The
    // symmetric 0101 pattern lands as 0xFFFF0000 or 0x0000FFFF depending on the
    // fixed beat rotation, which a whole-beat BITSLIP cannot swap, so detect the
    // dominant orientation and center against it. Vote over kReads at tap 16 by
    // the lane0-rise/lane0-fall sentinel bits; x19 = the chosen golden word.
    setAllTaps(16);
    register(Register.x28).bind(li(0)); // votes for 0x0000FFFF (rise=1/fall=0)
    register(Register.x26).bind(li(kReads * 2)); // vote trials
    final orLoop = label('lvlxorloop');
    readW0W1();
    // rise sentinel = bit0 of x4; fall sentinel = bit16. Vote 0x0000FFFF when
    // rise==1 && fall==0.
    register(
      Register.x24,
    ).bind(andi(register(Register.x4), 1)); // rise bit (0/1)
    register(Register.x12).bind(srli(register(Register.x4), 16));
    register(Register.x12).bind(andi(register(Register.x12), 1)); // fall bit
    // want rise==1 and fall==0 -> (rise & ~fall). x24 = rise, x12 = fall.
    register(
      Register.x12,
    ).bind(xori(register(Register.x12), 1)); // ~fall (1 bit)
    register(
      Register.x24,
    ).bind(and(register(Register.x24), register(Register.x12))); // 0/1
    // BRANCHLESS vote accumulation (no conditional bind): x28 += x24.
    register(
      Register.x28,
    ).bind(add(register(Register.x28), register(Register.x24)));
    register(Register.x26).bind(addi(register(Register.x26), -1));
    bne(register(Register.x26), register(Register.x0), orLoop);
    // BRANCHLESS golden select: pick 0x0000FFFF iff votes >= threshold, else
    // 0xFFFF0000. ge = ~(x28 < threshold) as 0/1; mask = -ge; x19 = select.
    register(
      Register.x11,
    ).bind(li(kReads)); // majority threshold (half of trials)
    register(
      Register.x24,
    ).bind(slt(register(Register.x28), register(Register.x11))); // 1 iff <thr
    register(
      Register.x24,
    ).bind(xori(register(Register.x24), 1)); // ge = 1 iff >=thr
    register(
      Register.x24,
    ).bind(sub(register(Register.x0), register(Register.x24))); // mask
    register(Register.x12).bind(li(0x0000FFFF));
    register(
      Register.x12,
    ).bind(and(register(Register.x12), register(Register.x24))); // 00FF&mask
    register(Register.x6).bind(li(0xFFFF0000 & 0xFFFFFFFF));
    register(Register.x11).bind(xori(register(Register.x24), -1)); // ~mask
    register(
      Register.x6,
    ).bind(and(register(Register.x6), register(Register.x11))); // FF00&~mask
    register(
      Register.x19,
    ).bind(or(register(Register.x12), register(Register.x6))); // golden
    _printStr('GOLD=');
    register(Register.x14).bind(mv(register(Register.x19)));
    _printHexX14();
    _printStr(' V=');
    register(Register.x14).bind(mv(register(Register.x28)));
    _printHexX14();
    _crlf();

    // DIAGNOSTIC: dump lane 0's read at every IDELAY tap 0..31 (other lanes at
    // 16) so a UART reader sees the eye shape. One read per tap; x8=laneField=0.
    register(Register.x8).bind(li(0)); // lane 0 field
    register(Register.x25).bind(li(0)); // tap
    final t0dump = label('lvlxt0dump');
    register(Register.x10).bind(li(regIdelay));
    register(
      Register.x11,
    ).bind(or(register(Register.x8), register(Register.x25)));
    register(Register.x11).bind(ori(register(Register.x11), 0x20));
    sw(register(Register.x10), register(Register.x11));
    readW0W1();
    _printChar(0x54); // 'T'
    register(Register.x14).bind(mv(register(Register.x25)));
    _printHexX14(); // full 8-digit tap (unambiguous for 16..31)
    _printChar(0x3D); // '='
    register(Register.x14).bind(mv(register(Register.x4)));
    _printHexX14();
    _crlf();
    register(Register.x25).bind(addi(register(Register.x25), 1));
    register(Register.x11).bind(li(tapTop));
    blt(register(Register.x25), register(Register.x11), t0dump);
    // Restore lane 0 to tap 16 for the sweep below.
    register(Register.x10).bind(li(regIdelay));
    register(Register.x11).bind(li(0x20 | 16));
    sw(register(Register.x10), register(Register.x11));

    // STEP 2: per-lane IDELAY tap sweep 0..31 for the contiguous MPR pass window;
    // park each lane at center. Sweep one lane's tap with the others at 16, judge
    // only lane L's two bits against golden x19 (rise bit L, fall bit L+16).
    register(Register.x20).bind(li(0)); // lane
    final laneScan = label('lvlxlanescan');
    register(
      Register.x8,
    ).bind(slli(register(Register.x20), 6)); // laneField = L<<6
    // Other lanes stay at 16 (step 1 never moved them). This lane sweeps.
    register(Register.x21).bind(li(0)); // lo
    register(Register.x22).bind(li(0)); // hi
    register(Register.x29).bind(li(0)); // any-pass flag
    register(Register.x25).bind(li(0)); // tap
    final tapScan = label('lvlxtapscan');
    // Load this lane's absolute tap (reg10 VAR_LOAD = laneField | tap | 0x20).
    register(Register.x10).bind(li(regIdelay));
    register(
      Register.x11,
    ).bind(or(register(Register.x8), register(Register.x25)));
    register(Register.x11).bind(ori(register(Register.x11), 0x20));
    sw(register(Register.x10), register(Register.x11));
    // Stability judge: read word0 kReads times; the lane passes only if every
    // read matches golden x19 in both of lane L's bits. Requiring all kReads
    // consistent finds the stable eye, not a marginal edge. Mask = (1<<L)|
    // (1<<L+16); miss = ((read ^ golden) & mask)!=0. x9=running pass (cleared on
    // any miss), x26=read counter, x24=scratch, x7=lane mask, x8=laneField.
    register(Register.x7).bind(li(1));
    register(
      Register.x7,
    ).bind(sll(register(Register.x7), register(Register.x20))); // 1<<L
    register(Register.x24).bind(slli(register(Register.x7), 16)); // (1<<L)<<16
    register(
      Register.x7,
    ).bind(or(register(Register.x7), register(Register.x24))); // mask
    register(Register.x9).bind(li(1)); // assume pass until a miss
    register(Register.x26).bind(li(kReads));
    final kLoop = label('lvlxkloop');
    readW0W1();
    register(
      Register.x24,
    ).bind(xor(register(Register.x4), register(Register.x19)));
    register(
      Register.x24,
    ).bind(and(register(Register.x24), register(Register.x7)));
    // Branchless pass accumulation: river_adl `.bind()` is not control-flow-aware
    // (a branch-skipped bind still schedules), so a conditional bind cannot gate
    // this. thisOk = (masked-xor == 0) via sltiu(x24, 1); x9 &= thisOk so any
    // miss across the kReads clears the pass.
    register(
      Register.x24,
    ).bind(sltiu(register(Register.x24), 1)); // 1 iff x24==0
    register(
      Register.x9,
    ).bind(and(register(Register.x9), register(Register.x24)));
    register(Register.x26).bind(addi(register(Register.x26), -1));
    bne(register(Register.x26), register(Register.x0), kLoop);
    // Branchless lo/hi latch (masked select, not conditional bind). x9 = pass:
    //   passMask  = -x9
    //   hi        = pass ? tap : hi
    //   firstPass = x9 & ~x29      (pass AND no prior pass); firstMask = -firstPass
    //   lo        = firstPass ? tap : lo
    //   x29       = x29 | x9       (sticky any-pass)
    // select(mask,a,b) = (a & mask) | (b & ~mask). x24/x12/x6 = scratch.
    // hi = pass ? tap : hi
    register(
      Register.x24,
    ).bind(sub(register(Register.x0), register(Register.x9))); // passMask
    register(
      Register.x12,
    ).bind(and(register(Register.x25), register(Register.x24))); // tap&mask
    register(Register.x6).bind(xori(register(Register.x24), -1)); // ~passMask
    register(
      Register.x6,
    ).bind(and(register(Register.x22), register(Register.x6))); // hi&~mask
    register(
      Register.x22,
    ).bind(or(register(Register.x12), register(Register.x6))); // new hi
    // firstPass = x9 & ~x29
    register(Register.x6).bind(xori(register(Register.x29), -1)); // ~x29
    register(
      Register.x6,
    ).bind(and(register(Register.x9), register(Register.x6))); // firstPass 0/1
    register(
      Register.x24,
    ).bind(sub(register(Register.x0), register(Register.x6))); // firstMask
    register(
      Register.x12,
    ).bind(and(register(Register.x25), register(Register.x24))); // tap&fmask
    register(Register.x6).bind(xori(register(Register.x24), -1)); // ~fmask
    register(
      Register.x6,
    ).bind(and(register(Register.x21), register(Register.x6))); // lo&~fmask
    register(
      Register.x21,
    ).bind(or(register(Register.x12), register(Register.x6))); // new lo
    // x29 = x29 | x9 (sticky any-pass)
    register(
      Register.x29,
    ).bind(or(register(Register.x29), register(Register.x9)));
    register(Register.x25).bind(addi(register(Register.x25), 1));
    register(Register.x11).bind(li(tapTop));
    blt(register(Register.x25), register(Register.x11), tapScan);

    // center = (lo+hi)/2; park this lane there (VAR_LOAD).
    register(
      Register.x23,
    ).bind(add(register(Register.x21), register(Register.x22)));
    register(Register.x23).bind(srli(register(Register.x23), 1));
    register(Register.x10).bind(li(regIdelay));
    register(
      Register.x11,
    ).bind(or(register(Register.x8), register(Register.x23)));
    register(Register.x11).bind(ori(register(Register.x11), 0x20));
    sw(register(Register.x10), register(Register.x11));

    // Report LVLX L=<lane> TAP=<center> LO=<lo> HI=<hi>.
    _printStr('LVLX L=');
    register(Register.x14).bind(mv(register(Register.x20)));
    _printHexX14();
    _printStr(' TAP=');
    register(Register.x14).bind(mv(register(Register.x23)));
    _printHexX14();
    _printStr(' LO=');
    register(Register.x14).bind(mv(register(Register.x21)));
    _printHexX14();
    _printStr(' HI=');
    register(Register.x14).bind(mv(register(Register.x22)));
    _printHexX14();
    _crlf();

    register(Register.x20).bind(addi(register(Register.x20), 1));
    register(Register.x11).bind(li(dataBits));
    blt(register(Register.x20), register(Register.x11), laneScan);

    // STEP 3: verify the centered eye against golden x19. Read word0 nTrials
    // times; count exact matches (GOOD) and OR a sticky per-bit error map (ERR).
    // Low 16 = rise beats, high 16 = fall beats. ERR=0 = perfect stable eye.
    register(Register.x28).bind(li(0)); // exact golden matches
    register(Register.x7).bind(li(0)); // sticky error bitmap
    register(Register.x26).bind(li(64)); // trials
    final vloop = label('lvlxvloop');
    readW0W1();
    register(
      Register.x24,
    ).bind(xor(register(Register.x4), register(Register.x19)));
    // Mask the error to the low 32 bits (lw sign-extends a bit-31-set read, so the
    // raw 64-bit xor would smear the upper half). x12 = 0xFFFFFFFF.
    register(Register.x12).bind(li(0xFFFF));
    register(Register.x12).bind(slli(register(Register.x12), 16));
    register(
      Register.x12,
    ).bind(ori(register(Register.x12), 0xFFFF)); // 0xFFFFFFFF
    register(
      Register.x24,
    ).bind(and(register(Register.x24), register(Register.x12)));
    register(
      Register.x7,
    ).bind(or(register(Register.x7), register(Register.x24)));
    // BRANCHLESS exact-match count: match = (x24 == 0); x28 += match.
    register(
      Register.x24,
    ).bind(sltiu(register(Register.x24), 1)); // 1 iff x24==0
    register(
      Register.x28,
    ).bind(add(register(Register.x28), register(Register.x24)));
    register(Register.x26).bind(addi(register(Register.x26), -1));
    bne(register(Register.x26), register(Register.x0), vloop);
    register(Register.x6).bind(mv(register(Register.x4))); // last sample
    _printStr('VER GOOD=');
    register(Register.x14).bind(mv(register(Register.x28)));
    _printHexX14();
    _printStr(' ERR=');
    register(Register.x14).bind(mv(register(Register.x7)));
    _printHexX14();
    _printStr(' S=');
    register(Register.x14).bind(mv(register(Register.x6)));
    _printHexX14();
    _crlf();

    // Short delay to pace the readout, then loop the centering forever
    // (UART-glitch tolerance). x24 counts down, bottom-tested.
    register(Register.x24).bind(li(0x200000)); // delay count
    final delayLbl = label('lvlxdelay');
    register(Register.x24).bind(addi(register(Register.x24), -1));
    bne(register(Register.x24), register(Register.x0), delayLbl);
    jal(diagLoop); // repeat the centering forever
  }

  /// Prints x14 as eight uppercase hex digits, MSB first (clobbers x15..x18).
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

  /// Prints the low nibble of x14 as one uppercase hex digit (clobbers
  /// x15..x17). Used for the single-digit window/bitslip/varies indices.
  void _printHexNibbleX14() {
    register(Register.x17).bind(li(0x3A));
    register(Register.x15).bind(andi(register(Register.x14), 0xF));
    register(Register.x15).bind(addi(register(Register.x15), 0x30));
    final noAdjust = Label('nadjn');
    blt(register(Register.x15), register(Register.x17), noAdjust);
    register(Register.x15).bind(addi(register(Register.x15), 7));
    placeLabel(noAdjust);
    final poll = label('pn');
    final lsr = lbu(register(Register.x13), offset: 5);
    register(Register.x16).bind(andi(lsr, 0x20));
    beq(register(Register.x16), register(Register.x0), poll);
    sb(register(Register.x13), register(Register.x15));
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
