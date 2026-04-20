import 'package:rohd/rohd.dart';

/// SiFive-style JTAG BSCAN tunnel (NESTED_TAP variant): lets OpenOCD reach the
/// River debug module over the FPGA config JTAG (ECP5 `JTAGG` ER1 user register,
/// driven by dirtyJtag) instead of a separate GPIO TAP. The inner
/// [RiverDebugModule] keeps its full TAP; this module reconstructs that TAP's
/// `tck/tms/tdi` from a framed ER1 DR scan and returns its `tdo` on `jtdo1`.
///
/// Frame (one ER1 DR scan, LSB-first), matching riscv-openocd
/// `riscv_add_bscan_tunneled_scan` for `BSCAN_TUNNEL_NESTED_TAP`:
///   [1 bit]  sel    : 1 = inner DR scan, 0 = inner IR scan
///   [7 bits] width  : inner scan length N (NOT N-1), LSB first
///   [N+1]    payload: inner TDI; the +1 is the one-TCK in/out skew OpenOCD
///                     compensates by right-shifting the captured field
///   [3 bits] idle   : zeros; carry the inner TAP Exit1 -> Update -> Run/Idle
/// Total frame = N + 12 bits.
///
/// OpenOCD selects this tunnel with `riscv use_bscan_tunnel <irwidth> 0` (0 =
/// nested-tap; irwidth = inner DM IR width = 5).
///
/// The inner TAP is clocked only during the ER1 Shift-DR window (`jce1 & jshift`)
/// so it advances once per frame bit and is frozen between frames. The tunnel
/// synthesizes a full inner-TAP walk inside that window:
///   sel=1 (DR): RTI -> Select-DR -> Capture-DR -> Shift-DR(N+1) -> Exit1 -> Update -> RTI
///   sel=0 (IR): RTI -> Select-DR -> Select-IR -> Capture-IR -> Shift-IR(N+1) -> Exit1 -> Update -> RTI
/// This FSM and the inner DM both rising-edge-detect `tck` in the system clock
/// domain, so they advance in lockstep.
///
/// HW-validation pending: the TDI/TDO skew (+1 payload bit) and header-to-shift
/// alignment are the parts to confirm against live OpenOCD. Framing + inner-TAP
/// walk are sim-tested against the real DM in jtag_tunnel_dm_test.dart (only the
/// `Ecp5Jtagg` primitive is an unsimulatable blackbox).
class JtagBscanTunnel extends Module {
  /// Width of the widest inner scan (the DMI register, ~41 bits). Sizes the
  /// payload counter.
  final int maxScanBits;

  JtagBscanTunnel({this.maxScanBits = 64, super.name = 'jtag_bscan_tunnel'})
    : super(definitionName: 'JtagBscanTunnel') {
    final clk = addInput('clk', Logic());
    final reset = addInput('reset', Logic());

    // ER1 user-register side (from Ecp5Jtagg).
    final jtck = addInput('jtck', Logic());
    final jtdi = addInput('jtdi', Logic());
    final jshift = addInput('jshift', Logic());
    final jupdate = addInput('jupdate', Logic());
    final jce1 = addInput('jce1', Logic());
    final jrstn = addInput('jrstn', Logic());
    final innerTdo = addInput('inner_tdo', Logic());

    final jtdo1 = addOutput('jtdo1');
    final innerTck = addOutput('inner_tck');
    final innerTms = addOutput('inner_tms');
    final innerTdi = addOutput('inner_tdi');
    final innerTrstN = addOutput('inner_trst_n');

    final cntW = (maxScanBits + 16).bitLength;
    final cnt = Logic(name: 'bit_cnt', width: cntW); // frame bit index
    final sel = Logic(name: 'sel'); // 1=DR, 0=IR
    final width = Logic(name: 'width', width: 7); // inner scan length N
    final jtckPrev = Logic(name: 'jtck_prev');
    final tdoCap = Logic(name: 'tdo_cap'); // registered inner tdo for jtdo1

    final jtckRise = (jtck & ~jtckPrev).named('jtck_rise');
    final active = (jce1 & jshift).named('tunnel_active'); // shifting ER1 DR

    // Header is 8 bits (sel + 7 width). OpenOCD sends width+1 payload bits but the
    // inner TAP shifts exactly N; the extra bit is the one-TCK TDO skew. So the
    // inner Shift window is bits 8 .. 8+N-1.
    final headerBits = 8;
    final shiftStart = Const(headerBits, width: cntW);
    final lastShift =
        (Const(headerBits, width: cntW) +
                width.zeroExtend(cntW) -
                Const(1, width: cntW))
            .named('last_shift');

    // Inner TAP in Shift (driving N real shifts)?
    final inShift = (cnt.gte(shiftStart) & cnt.lte(lastShift)).named(
      'in_shift',
    );
    final atLastShift = cnt.eq(lastShift).named('at_last_shift');

    // TMS schedule by frame bit. Inner TAP starts each frame in Run-Test/Idle
    // (TLR on first access lands in RTI too, identical walk).
    //   DR walk: tms=1 at bit 5 (RTI->Sel-DR); bits 6,7 tms=0 (Capture, Shift).
    //   IR walk: tms=1 at bits 4,5 (Sel-DR, Sel-IR); bits 6,7 tms=0.
    // Then N shift bits 8..lastShift (tms=0); last asserts tms=1 (Shift->Exit1),
    // bit lastShift+1 tms=1 (Exit1->Update), trailing bits tms=0 (Update->RTI).
    final w4 = cnt.eq(Const(4, width: cntW));
    final w5 = cnt.eq(Const(5, width: cntW));
    final exitFirst = cnt.eq(lastShift + Const(1, width: cntW));

    final tmsDr = w5.named('tms_dr_walk');
    final tmsIr = (w4 | w5).named('tms_ir_walk');
    final tmsVal = mux(
      inShift,
      atLastShift, // last shift bit exits Shift -> Exit1
      mux(
        cnt.gt(lastShift),
        exitFirst, // Exit1 -> Update on the first post-shift bit, then RTI
        mux(sel, tmsDr, tmsIr), // header walk (DR vs IR)
      ),
    ).named('inner_tms_val');

    Sequential(clk, reset: reset, [
      jtckPrev < jtck,
      If(
        ~jrstn,
        then: [cnt < Const(0, width: cntW)],
        orElse: [
          If(
            jtckRise,
            then: [
              If(
                active,
                then: [
                  cnt < cnt + 1,
                  If(cnt.eq(Const(0, width: cntW)), then: [sel < jtdi]),
                  // Shift width in LSB-first across bits 1..7.
                  If(
                    cnt.gte(Const(1, width: cntW)) &
                        cnt.lte(Const(7, width: cntW)),
                    then: [
                      width < [jtdi, width.getRange(1, 7)].swizzle(),
                    ],
                  ),
                  // Capture inner tdo while shifting (registered -> the +1 skew).
                  If(inShift, then: [tdoCap < innerTdo]),
                ],
                orElse: [
                  // Between scans (outer Capture-DR / Update / idle): restart the
                  // frame index so the next Shift-DR window begins clean.
                  cnt < Const(0, width: cntW),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    // Inner TAP drive. Clock the inner TAP ONLY inside the ER1 Shift-DR window
    // so it advances once per frame bit; tms/tdi are combinational per bit.
    innerTck <= jtck & active;
    innerTrstN <= jrstn;
    innerTms <= tmsVal;
    innerTdi <= mux(inShift, jtdi, Const(0));
    jtdo1 <= tdoCap;
  }
}
