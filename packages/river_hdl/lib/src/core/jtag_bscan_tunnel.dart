import 'package:rohd/rohd.dart';

/// SiFive-style JTAG BSCAN tunnel (NESTED_TAP variant): lets OpenOCD reach the
/// River debug module over the FPGA config JTAG (ECP5 `JTAGG` ER1 user register or
/// Xilinx `BSCANE2` USER4) instead of a separate GPIO TAP. The inner
/// [RiverDebugModule] keeps its full standard TAP; this module reconstructs that
/// TAP's `tck/tms/tdi` from a framed config-JTAG DR scan and returns its `tdo` on
/// `jtdo1`.
///
/// Frame (one config-JTAG DR scan, LSB-first), matching riscv-openocd's
/// `BSCAN_TUNNEL_NESTED_TAP` frame (sel + width lead the Shift-DR window):
///   [1 bit]  sel    : 1 = inner DR scan, 0 = inner IR scan
///   [7 bits] width  : inner scan length N, LSB first
///   [N+1]    payload: inner TDI; the +1 is the one-TCK in/out skew OpenOCD
///                     compensates by right-shifting the captured field
///   [3 bits] idle   : zeros; carry the inner TAP Exit1 -> Update -> Run/Idle
/// Total frame = N + 12 bits.
///
/// OpenOCD selects this tunnel with `riscv use_bscan_tunnel <irwidth> 0` (0 =
/// nested-tap; irwidth = inner DM IR width = 5). Hardware-proven on the Arty S7:
/// OpenOCD examines the RISC-V DM and reads DDR over SBA through this.
///
/// TCK (~1 MHz) is asynchronous to the system clock, so every config-JTAG level is
/// passed through a 2-FF synchronizer before the frame FSM edge-detects `jtck` or
/// samples `jtdi`/drives the inner TMS, so a level in flight at a system clock edge
/// can't be latched metastable. The inner TAP is clocked only during the Shift-DR
/// window (`jce1 & jshift`) so it advances once per frame bit and is frozen between
/// frames; the FSM synthesizes a full inner TAP walk inside that window:
///   sel=1 (DR): RTI -> Select-DR -> Capture-DR -> Shift-DR(N) -> Exit1 -> Update
///   sel=0 (IR): RTI -> Select-DR -> Select-IR -> Capture-IR -> Shift-IR(N) -> ...
///
/// The frame counter is restarted by the `~active` edge reset (a config-JTAG
/// edge outside the Shift-DR window), which anchors each scan to its Capture-DR.
/// An earlier BSCANE2-CAPTURE anchor input was tried and removed: CAPTURE held
/// wider than one Capture-DR state on silicon and pinned the counter, killing the
/// tunnel. Framing + inner-TAP walk are sim-tested against the real DM in
/// jtag_tunnel_dm_test.dart (the config-JTAG primitive is an unsimulatable
/// blackbox; the async synchronizers only matter on real silicon).
class JtagBscanTunnel extends Module {
  /// Width of the widest inner scan (the DMI register, ~41 bits). Sizes the
  /// payload counter.
  final int maxScanBits;

  JtagBscanTunnel({this.maxScanBits = 64, super.name = 'jtag_bscan_tunnel'})
    : super(definitionName: 'JtagBscanTunnel') {
    final clk = addInput('clk', Logic());
    final reset = addInput('reset', Logic());

    // Config-JTAG user-register side (from Ecp5Jtagg or XilinxBscane2).
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

    // 2-FF synchronizers for the asynchronous config-JTAG inputs. Bit 0 is the
    // metastability-catcher, bit 1 the synchronized level the FSM consumes.
    final jtckSync = Logic(name: 'jtck_sync', width: 2);
    final jtdiSync = Logic(name: 'jtdi_sync', width: 2);
    final jshiftSync = Logic(name: 'jshift_sync', width: 2);
    final jce1Sync = Logic(name: 'jce1_sync', width: 2);
    final jrstnSync = Logic(name: 'jrstn_sync', width: 2);
    final jtckS = jtckSync[1];
    final jtdiS = jtdiSync[1];
    final jshiftS = jshiftSync[1];
    final jce1S = jce1Sync[1];
    final jrstnS = jrstnSync[1];

    final cntW = (maxScanBits + 16).bitLength;
    final cnt = Logic(name: 'bit_cnt', width: cntW); // frame bit index
    final sel = Logic(name: 'sel'); // 1=DR, 0=IR
    final width = Logic(name: 'width', width: 7); // inner scan length N
    final jtckPrev = Logic(name: 'jtck_prev');
    final tdoCap = Logic(name: 'tdo_cap'); // registered inner tdo for jtdo1

    final jtckRise = (jtckS & ~jtckPrev).named('jtck_rise');
    final active = (jce1S & jshiftS).named('tunnel_active'); // shifting DR

    // Header is 8 bits (sel + 7 width). The inner Shift window is bits
    // 8 .. 8+N-1; OpenOCD's extra payload bit is the one-TCK TDO skew.
    final headerBits = 8;
    final shiftStart = Const(headerBits, width: cntW);
    final lastShift =
        (Const(headerBits, width: cntW) +
                width.zeroExtend(cntW) -
                Const(1, width: cntW))
            .named('last_shift');

    final inShift = (cnt.gte(shiftStart) & cnt.lte(lastShift)).named(
      'in_shift',
    );
    final atLastShift = cnt.eq(lastShift).named('at_last_shift');

    // TMS schedule by frame bit. Inner TAP starts each frame in Run-Test/Idle.
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
      // Advance the input synchronizers every system clock.
      jtckSync < [jtckSync[0], jtck].swizzle(),
      jtdiSync < [jtdiSync[0], jtdi].swizzle(),
      jshiftSync < [jshiftSync[0], jshift].swizzle(),
      jce1Sync < [jce1Sync[0], jce1].swizzle(),
      jrstnSync < [jrstnSync[0], jrstn].swizzle(),

      jtckPrev < jtckS,
      If(
        ~jrstnS,
        then: [cnt < Const(0, width: cntW)],
        orElse: [
          If(
            jtckRise,
            then: [
              If(
                active,
                then: [
                  cnt < cnt + 1,
                  If(cnt.eq(Const(0, width: cntW)), then: [sel < jtdiS]),
                  // Shift width in LSB-first across bits 1..7.
                  If(
                    cnt.gte(Const(1, width: cntW)) &
                        cnt.lte(Const(7, width: cntW)),
                    then: [
                      width < [jtdiS, width.getRange(1, 7)].swizzle(),
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

    // Inner TAP drive. Clock the inner TAP ONLY inside the Shift-DR window so it
    // advances once per frame bit; tms/tdi are combinational per bit.
    innerTck <= jtckS & active;
    innerTrstN <= jrstnS;
    innerTms <= tmsVal;
    innerTdi <= mux(inShift, jtdiS, Const(0));
    jtdo1 <= tdoCap;
  }
}
