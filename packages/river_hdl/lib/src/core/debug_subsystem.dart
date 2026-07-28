import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:river/river.dart';

import 'debug.dart';
import 'jtag_bscan_tunnel.dart';
import 'sba_wishbone.dart';

/// SoC-level JTAG debug subsystem. On ECP5 it reaches the debugger over the FPGA
/// config JTAG (dirtyJtag) via the `JTAGG` ER1 user register + a SiFive bscan
/// tunnel, so no extra JTAG pads and no second probe. Wraps:
///   Ecp5Jtagg  (config-JTAG user register taps)
///     -> JtagBscanTunnel (frame decode -> inner TAP drive)
///       -> RiverDebugModule (TAP + DTM + DM + SBA, sim-proven)
///         -> SbaWishboneAdapter (SBA -> Wishbone master `bus`)
///
/// Exposes a Wishbone master `bus` (second fabric master for memory access) and
/// the core-facing debug control ports; JTAG pins are internal to `JTAGG`. genip
/// wires `bus` via `soc.addMaster` and the control ports to a
/// `RiverCore(withDebug: true)`.
///
/// OpenOCD reaches it with `riscv use_bscan_tunnel 6 1` over the ECP5 TAP.
/// HW-validation pending; the tunnel framing is the piece to confirm live.
class RiverDebugSubsystem extends BridgeModule implements HarborJtagDebug {
  /// The debug module's JTAG IDCODE, advertised over the BSCAN tunnel.
  final int idcode;

  RiverDebugSubsystem(
    WishboneConfig config, {
    required int xlen,
    this.idcode = 0x10000001,
    // FPGA target: selects the config-JTAG primitive. Xilinx (openXC7/vivado)
    // taps the config TAP with BSCANE2 on USER1; everything else uses the ECP5
    // JTAGG. Null (ASIC / no FPGA target) falls back to JTAGG.
    HarborDeviceTarget? target,
    String? name,
  }) : super('RiverDebugSubsystem', name: name ?? 'debug_jtag') {
    final useBscane2 =
        target is HarborFpgaTarget &&
        (target.vendor == HarborFpgaVendor.openXc7 ||
            target.vendor == HarborFpgaVendor.vivado);
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    // Core-facing: from the core.
    createPort('hart_halted', PortDirection.input);
    createPort('reg_rdata', PortDirection.input, width: xlen);
    createPort('reg_ready', PortDirection.input);
    // Core-facing: to the core.
    createPort('halt_req', PortDirection.output);
    createPort('resume_req', PortDirection.output);
    createPort('ndmreset', PortDirection.output);
    createPort('reg_read', PortDirection.output);
    createPort('reg_write', PortDirection.output);
    createPort('reg_addr', PortDirection.output, width: 16);
    createPort('reg_wdata', PortDirection.output, width: xlen);

    // Wishbone master (provider): drives the fabric, reads ack/datMiso back.
    final busRef = addInterface(
      WishboneInterface(config),
      name: 'bus',
      role: PairRole.provider,
    );
    final bus = busRef.internalInterface as WishboneInterface;

    // Tunnel: framed config-JTAG DR scan -> inner TAP signals. Fed by the
    // vendor's config-JTAG user-register primitive below.
    final tunnel = JtagBscanTunnel(maxScanBits: xlen);
    tunnel.input('clk').srcConnection! <= input('clk');
    tunnel.input('reset').srcConnection! <= input('reset');

    if (useBscane2) {
      // Xilinx 7-series BSCANE2 on USER4 (JTAG_CHAIN=4, IR 0x23). riscv-openocd's
      // bscan tunnel HARDCODES USER4 for tunneled DMI scans (riscv.c select_user4
      // = 0x23), so the DM must ride USER4, not USER1, or SEL never asserts and
      // the tunnel returns zeros. Mapped onto the tunnel's JTAGG-style ports.
      // jtck = TCK, the RAW scan clock (the tunnel FSM matches JTAGG's raw JTCK
      // and is sim-validated against a continuously toggling clock, so DRCK, the
      // gated data-register clock, mis-frames it). The tunnel gates advance with
      // SEL & SHIFT; SEL = this user chain selected (the JCE1 equivalent); the
      // active-high RESET inverts to the tunnel's active-low jrstn.
      final bscan = XilinxBscane2(jtagChain: 4);
      tunnel.input('jtck').srcConnection! <= bscan.output('TCK');
      tunnel.input('jtdi').srcConnection! <= bscan.output('TDI');
      tunnel.input('jshift').srcConnection! <= bscan.output('SHIFT');
      tunnel.input('jupdate').srcConnection! <= bscan.output('UPDATE');
      tunnel.input('jce1').srcConnection! <= bscan.output('SEL');
      tunnel.input('jrstn').srcConnection! <= ~bscan.output('RESET');
      bscan.input('TDO').srcConnection! <= tunnel.output('jtdo1');
    } else {
      // ECP5 config-JTAG user register taps (ER1).
      final jtagg = Ecp5Jtagg();
      tunnel.input('jtck').srcConnection! <= jtagg.output('JTCK');
      tunnel.input('jtdi').srcConnection! <= jtagg.output('JTDI');
      tunnel.input('jshift').srcConnection! <= jtagg.output('JSHIFT');
      tunnel.input('jupdate').srcConnection! <= jtagg.output('JUPDATE');
      tunnel.input('jce1').srcConnection! <= jtagg.output('JCE1');
      tunnel.input('jrstn').srcConnection! <= jtagg.output('JRSTN');
      jtagg.input('JTDO1').srcConnection! <= tunnel.output('jtdo1');
      jtagg.input('JTDO2').srcConnection! <= Const(0);
    }

    // Nets feeding the DM's SBA response, driven by the adapter below.
    final sbaRdata = Logic(name: 'sba_rdata', width: xlen);
    final sbaAck = Logic(name: 'sba_ack');

    final dm = RiverDebugModule(
      input('clk'),
      input('reset'),
      tunnel.output('inner_tck'),
      tunnel.output('inner_tms'),
      tunnel.output('inner_tdi'),
      tunnel.output('inner_trst_n'),
      hartHalted: input('hart_halted'),
      regRdata: input('reg_rdata'),
      regReady: input('reg_ready'),
      sbaRdata: sbaRdata,
      sbaAck: sbaAck,
      xlen: xlen,
      idcode: idcode,
    );
    tunnel.input('inner_tdo').srcConnection! <= dm.tdo;

    // DM outputs to the core.
    output('halt_req') <= dm.haltReq;
    output('resume_req') <= dm.resumeReq;
    output('ndmreset') <= dm.ndmreset;
    output('reg_read') <= dm.regRead;
    output('reg_write') <= dm.regWrite;
    output('reg_addr') <= dm.regAddr;
    output('reg_wdata') <= dm.regWdata;

    // SBA -> Wishbone.
    final adapter = SbaWishboneAdapter(
      dataWidth: config.dataWidth,
      addressWidth: config.addressWidth,
      xlen: xlen,
    );
    adapter.input('sba_req').srcConnection! <= dm.sbaReq;
    adapter.input('sba_we').srcConnection! <= dm.sbaWe;
    adapter.input('sba_addr').srcConnection! <= dm.sbaAddr;
    adapter.input('sba_wdata').srcConnection! <= dm.sbaWdata;
    adapter.input('sba_size').srcConnection! <= dm.sbaSize;
    adapter.input('wb_ack').srcConnection! <= bus.ack;
    adapter.input('wb_dat_miso').srcConnection! <= bus.datMiso;

    sbaRdata <= adapter.output('sba_rdata');
    sbaAck <= adapter.output('sba_ack');

    bus.cyc <= adapter.output('wb_cyc');
    bus.stb <= adapter.output('wb_stb');
    bus.we <= adapter.output('wb_we');
    bus.adr <= adapter.output('wb_adr');
    bus.datMosi <= adapter.output('wb_dat_mosi');
    bus.sel <= adapter.output('wb_sel');
  }

  @override
  int get jtagInnerIrWidth => 5; // RISC-V DTM (dtmcs/dmi) IR width

  @override
  int? get jtagDmIdcode => idcode;
}
