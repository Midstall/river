import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
// river.dart re-exports harbor (UsbEp0Engine, UsbDfuRamSink, Wishbone*,
// BusSlavePort, HarborDeviceTreeNode(Provider), BusAddressRange, etc.).
import 'package:river/river.dart';

/// [BridgeModule] wrapper that merges the two SoC masters (River core + DFU
/// RAM-sink writeback master) onto a single decoder master. Exposes two CONSUMER
/// master ports (`m0`, `m1`) the upstream masters connect into and one PROVIDER
/// `slave` port into the decoder. Single bus clock domain (12 MHz `bus_clk` /
/// `bus_reset`); the USB crossing already happened in [UsbDfuRamSink]'s CDC FIFO.
class RiverWishboneArbiter extends BridgeModule {
  RiverWishboneArbiter(WishboneConfig config, {String? name})
    : super('RiverWishboneArbiter', name: name ?? 'wb_arbiter2') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Two upstream masters: this module is the CONSUMER (it receives the
    // master's CYC/ADR/... and drives ACK/DAT_MISO back), so the upstream
    // PROVIDER interfaces connect down into these.
    final m0Ref = addInterface(
      WishboneInterface(config),
      name: 'm0',
      role: PairRole.consumer,
    );
    final m1Ref = addInterface(
      WishboneInterface(config),
      name: 'm1',
      role: PairRole.consumer,
    );
    // Downstream merged slave: this module is the PROVIDER, driving the decoder.
    final slaveRef = addInterface(
      WishboneInterface(config),
      name: 'slave',
      role: PairRole.provider,
    );

    final m0 = m0Ref.internalInterface as WishboneInterface;
    final m1 = m1Ref.internalInterface as WishboneInterface;
    final s = slaveRef.internalInterface as WishboneInterface;

    // Arbitration is inline (not via the raw WishboneArbiter Module): the slave
    // response signals (ACK/DAT_MISO) driven in by the parent decoder must be
    // consumed within this module's boundary; nesting the raw arbiter would tap
    // them across the module edge, which ROHD forbids.
    //
    // Grant policy: registered CYC-held round-robin. The grant only changes while
    // no transfer is in flight, so a burst is never torn mid-transaction.
    final clk = input('clk');
    final reset = input('reset');

    // grantM1: 0 -> master 0 (core) is granted, 1 -> master 1 (DFU sink).
    final grantM1 = Logic(name: 'grant_m1');
    // last: who was served last, for round-robin fairness.
    final last = Logic(name: 'last_grant');

    final m0Req = m0.cyc;
    final m1Req = m1.cyc;
    final grantedCyc = mux(grantM1, m1Req, m0Req); // current grantee's CYC
    final busIdle = ~grantedCyc;

    Sequential(clk, [
      If(
        reset,
        then: [grantM1 < Const(0), last < Const(0)],
        orElse: [
          // Re-arbitrate only when the bus is idle (no granted transfer running).
          If(
            busIdle,
            then: [
              // Round-robin: prefer the master that was NOT served last.
              If(
                last & m0Req,
                then: [grantM1 < Const(0), last < Const(0)],
                orElse: [
                  If(
                    ~last & m1Req,
                    then: [grantM1 < Const(1), last < Const(1)],
                    orElse: [
                      // Otherwise keep whichever single master is requesting.
                      If(m0Req, then: [grantM1 < Const(0), last < Const(0)]),
                      If(
                        m1Req & ~m0Req,
                        then: [grantM1 < Const(1), last < Const(1)],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    // Forward the granted master to the slave.
    s.cyc <= mux(grantM1, m1.cyc, m0.cyc);
    s.stb <= mux(grantM1, m1.stb, m0.stb);
    s.we <= mux(grantM1, m1.we, m0.we);
    s.adr <= mux(grantM1, m1.adr, m0.adr);
    s.datMosi <= mux(grantM1, m1.datMosi, m0.datMosi);
    s.sel <= mux(grantM1, m1.sel, m0.sel);

    // Route the slave response back: ACK gated per master, DAT_MISO broadcast.
    m0.ack <= s.ack & ~grantM1;
    m1.ack <= s.ack & grantM1;
    m0.datMiso <= s.datMiso;
    m1.datMiso <= s.datMiso;
  }
}

/// Small Wishbone SLAVE status/control block the maskrom polls to drive a USB
/// DFU download into RAM. Single-cycle registered ACK, bus (12 MHz) domain.
///
/// Word-mapped registers (word offset within [baseAddress]):
///   0x00  STATUS   (R)  bit0 = image_ready (sticky from the RAM sink).
///   0x04  CONTROL  (R/W) bit0 = usb_enable: write 1 to assert the USB pull-up
///                       enable so the host enumerates. Reads back latched value.
///   0x08  ENTRY    (R)  RAM entry address the image landed at (= sink loadBase).
///   0x0C  BYTES    (R)  image bytes written so far (debug).
///
/// Status inputs come from [UsbDfuRamSink]'s bus-domain outputs; usb_enable is
/// the only writable bit, surfaced as an output to gate the USB pull-up.
class RiverDfuStatus extends BridgeModule with HarborDeviceTreeNodeProvider {
  final int baseAddress;
  final int busAddressWidth;
  final int busDataWidth;

  /// The control bit the CPU writes to enable USB (drives the pull-up enable).
  Logic get usbEnable => output('usb_enable');

  late final BusSlavePort bus;

  RiverDfuStatus({
    required this.baseAddress,
    this.busAddressWidth = 32,
    this.busDataWidth = 32,
    String? name,
  }) : super('RiverDfuStatus', name: name ?? 'dfu_status') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Bus-domain status inputs from the RAM sink.
    createPort('image_ready', PortDirection.input);
    createPort('entry_addr', PortDirection.input, width: busAddressWidth);
    createPort('bytes_written', PortDirection.input, width: 32);

    addOutput('usb_enable');

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: BusProtocol.wishbone,
      addressWidth: busAddressWidth,
      dataWidth: busDataWidth,
    );

    final clk = input('clk');
    final reset = input('reset');

    final imageReadyIn = input('image_ready');
    final entryAddrIn = input('entry_addr');
    final bytesWrittenIn = input('bytes_written');

    // Sticky image_ready: once the sink pulses/holds it, latch it so the
    // maskrom poll cannot miss a transient.
    final imageReadySticky = Logic(name: 'image_ready_sticky');
    // usb_enable control bit (R/W).
    final usbEnableReg = Logic(name: 'usb_enable_reg');
    // Registered ACK: one cycle per strobe.
    final ackReg = Logic(name: 'dfu_status_ack');

    final stb = bus.stb;
    final we = bus.we;
    // Word offset (drop the in-word byte bits). A 32-bit bus has a 4-byte word;
    // the register select is addr bits above the byte offset.
    final wordSel = bus.addr.getRange(2, 4); // bits [3:2] -> 0..3

    Sequential(clk, [
      If(
        reset,
        then: [
          imageReadySticky < Const(0),
          usbEnableReg < Const(0),
          ackReg < Const(0),
        ],
        orElse: [
          // Latch image_ready forever once seen.
          If(imageReadyIn, then: [imageReadySticky < Const(1)]),

          // ACK is a single-cycle pulse on an unacked strobe.
          ackReg < (stb & ~ackReg),

          // Register write: CONTROL (word offset 1, byte addr 0x04).
          If(
            stb & we & ~ackReg & wordSel.eq(Const(1, width: 2)),
            then: [usbEnableReg < bus.dataIn.getRange(0, 1)],
          ),
        ],
      ),
    ]);

    bus.ack <= ackReg;
    output('usb_enable') <= usbEnableReg;

    // Read mux: select the addressed register, zero-extended to the bus width.
    final statusWord = imageReadySticky
        .zeroExtend(busDataWidth)
        .named('status_word');
    final controlWord = usbEnableReg
        .zeroExtend(busDataWidth)
        .named('control_word');
    final entryWord = entryAddrIn.zeroExtend(busDataWidth).named('entry_word');
    final bytesWord = bytesWrittenIn
        .zeroExtend(busDataWidth)
        .named('bytes_word');

    bus.dataOut <=
        mux(
          wordSel.eq(Const(0, width: 2)),
          statusWord,
          mux(
            wordSel.eq(Const(1, width: 2)),
            controlWord,
            mux(wordSel.eq(Const(2, width: 2)), entryWord, bytesWord),
          ),
        );
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['river,dfu-status'],
    reg: BusAddressRange(baseAddress, 0x1000),
  );
}

/// The USB DFU subsystem: EP0 enumeration engine + RAM-sink writeback master +
/// line tristate pads, so the SoC sees one bus MASTER and a few pads.
///
/// Dual clock domain: `usb_clk`/`usb_reset` is the raw 48 MHz osc (already the
/// SoC `clk`; runs [UsbEp0Engine] and the USB side of [UsbDfuRamSink]).
/// `bus_clk`/`bus_reset` is the 12 MHz core/bus domain (the sink's Wishbone
/// master + CDC FIFO bus side). The FIFO inside the sink bridges the two.
///
/// Exposed: PROVIDER Wishbone `bus` (RAM-sink master); `usb_dp`/`usb_dm` inOut
/// pads (PHY dp_out/dm_out + oe tristate, pad fed back to the PHY); `usb_pullup`
/// (D+ enable, gated by `usb_enable`); status outputs image_ready/entry_addr/
/// bytes_written and a `usb_enable` input for the [RiverDfuStatus] slave.
class RiverDfuSubsystem extends BridgeModule {
  final int loadBase;
  final int busAddressWidth;
  final int busDataWidth;

  RiverDfuSubsystem({
    this.loadBase = 0x80000000,
    this.busAddressWidth = 32,
    this.busDataWidth = 32,
    String? name,
  }) : super('RiverDfuSubsystem', name: name ?? 'usb_dfu') {
    // Bus-domain clock/reset (12 MHz). Named clk/reset so addMaster auto-wires
    // them from the bus domain; the 48 MHz usb_clk/usb_reset are wired manually.
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);

    // USB line pads (bidirectional) + pull-up enable + the user button.
    createPort('usb_dp', PortDirection.inOut);
    createPort('usb_dm', PortDirection.inOut);
    addOutput('usb_pullup');

    // Control/status bridge to the RiverDfuStatus slave (bus domain).
    createPort('usb_enable', PortDirection.input);
    addOutput('image_ready');
    addOutput('entry_addr', width: busAddressWidth);
    addOutput('bytes_written', width: 32);

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('clk');
    final busReset = input('reset');

    // EP0 enumeration engine (48 MHz USB domain).
    final engine = UsbEp0Engine(name: 'ep0');
    addSubModule(engine);
    engine.input('clk').srcConnection! <= usbClk;
    engine.input('reset').srcConnection! <= usbReset;

    // RAM writeback sink (dual domain, Wishbone master).
    final ramSink = UsbDfuRamSink(
      loadBase: loadBase,
      busAddressWidth: busAddressWidth,
      busDataWidth: busDataWidth,
      // Depth-8 is plenty: sink_ready back-pressure means the engine never
      // outruns the bus drain, so a deep FIFO buys nothing but local cells.
      fifoDepth: 8,
      name: 'ram_sink',
    );
    addSubModule(ramSink);
    ramSink.input('usb_clk').srcConnection! <= usbClk;
    ramSink.input('usb_reset').srcConnection! <= usbReset;
    ramSink.input('bus_clk').srcConnection! <= busClk;
    ramSink.input('bus_reset').srcConnection! <= busReset;

    // engine <-> ramSink sink stream (USB domain).
    ramSink.input('sink_data').srcConnection! <= engine.output('sink_data');
    ramSink.input('sink_valid').srcConnection! <= engine.output('sink_valid');
    ramSink.input('dnload_done').srcConnection! <= engine.output('dnload_done');
    ramSink.input('image_target').srcConnection! <=
        engine.output('image_target');
    ramSink.input('alt_setting').srcConnection! <= engine.output('alt_setting');
    engine.input('sink_ready').srcConnection! <= ramSink.output('sink_ready');

    // Status outputs (bus domain) to the slave.
    output('image_ready') <= ramSink.output('image_ready');
    output('entry_addr') <= ramSink.output('entry_addr');
    output('bytes_written') <= ramSink.output('bytes_written');

    // USB line tristate pads: drive when oe is high, else high-Z, and feed the
    // pad value back into the PHY's dp/dm inputs.
    final dpPad = inOut('usb_dp');
    final dmPad = inOut('usb_dm');
    final oe = engine.output('oe');
    final dpDrive = TriStateBuffer(engine.output('dp_out'), enable: oe);
    final dmDrive = TriStateBuffer(engine.output('dm_out'), enable: oe);
    dpPad <= dpDrive.out;
    dmPad <= dmDrive.out;
    engine.input('dp').srcConnection! <= dpPad;
    engine.input('dm').srcConnection! <= dmPad;

    // Pull-up enable, gated by the CPU-written usb_enable so the device only
    // connects once the maskrom has armed DFU mode.
    output('usb_pullup') <= engine.output('usb_pullup') & input('usb_enable');

    // Expose the RAM-sink Wishbone master as this subsystem's `bus`.
    pullUpInterface(ramSink.interface('bus'), newIntfName: 'bus');
  }
}

/// The lean, software-driven USB DFU subsystem (CAR target): the cheap
/// alternative to [RiverDfuSubsystem] for the LFE5U-25F. Drops the whole
/// hardware RAM-sink tier (no [UsbDfuRamSink], no [HarborCdcFifo], no
/// [RiverWishboneArbiter], no second bus master); this block is a single MMIO
/// SLAVE and the River core is the only bus participant. Keeps the PHY (inside
/// [UsbEp0Engine]) and a small register file with a one-byte receive handshake.
///
/// The maskrom drives the download in software: poll STATUS for a captured byte,
/// read RXDATA, store into Cache-as-RAM (via the rcache CSRs), ack to release the
/// next byte. No SRAM region; the DFU target is CAR.
///
/// Byte path / CDC: engine `sink_valid`/`sink_data` are 48 MHz USB domain, the
/// bus is 12 MHz. A single-entry two-phase handshake crosses each byte: a USB
/// `producer toggle` flips per byte, the bus domain syncs it ([HarborCdcSync])
/// and on an edge captures RXDATA + sets sticky `rx_valid`; the CPU's CONTROL
/// `advance` write flips a `consumer toggle` synced back so `sink_ready` re-arms.
/// sink_ready == (producer == consumer) is the depth-1 back-pressure, so no deep
/// FIFO is needed.
///
/// Word-mapped registers (word offsets within [baseAddress]):
///   0x00 STATUS  (R)  bit0 = rx_valid, bit1 = dnload_done, bit2 = configured,
///                     bits[7:4] = dfu_state, rest reserved 0.
///   0x04 CONTROL (R/W) bit0 = usb_enable (pull-up/connect), bit1 = advance
///                     (W1P: ack current byte, release next). usb_enable reads back.
///   0x08 RXDATA  (R)  bits[7:0] = captured download byte.
///   0x0C BYTES   (R)  running count of bytes captured (debug).
class RiverDfuSubsystemSw extends BridgeModule
    with HarborDeviceTreeNodeProvider {
  final int baseAddress;
  final int busAddressWidth;
  final int busDataWidth;

  RiverDfuSubsystemSw({
    required this.baseAddress,
    this.busAddressWidth = 32,
    this.busDataWidth = 32,
    String? name,
  }) : super('RiverDfuSubsystemSw', name: name ?? 'usb_dfu_sw') {
    // Bus-domain clock/reset (12 MHz). Auto-wired from the bus domain by
    // addPeripheral. The 48 MHz usb_clk/usb_reset are wired manually.
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('usb_clk', PortDirection.input);
    createPort('usb_reset', PortDirection.input);

    // USB line pads (bidirectional) + pull-up enable.
    createPort('usb_dp', PortDirection.inOut);
    createPort('usb_dm', PortDirection.inOut);
    addOutput('usb_pullup');

    final usbClk = input('usb_clk');
    final usbReset = input('usb_reset');
    final busClk = input('clk');
    final busReset = input('reset');

    // MMIO slave (bus / 12 MHz domain).
    final bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: BusProtocol.wishbone,
      addressWidth: busAddressWidth,
      dataWidth: busDataWidth,
    );

    // EP0 enumeration engine + PHY (48 MHz USB domain).
    final engine = UsbEp0Engine(name: 'ep0');
    addSubModule(engine);
    engine.input('clk').srcConnection! <= usbClk;
    engine.input('reset').srcConnection! <= usbReset;

    final sinkData = engine.output('sink_data'); // [7:0], USB domain
    final sinkValid = engine.output('sink_valid'); // pulse, USB domain
    final dnloadDoneUsb = engine.output('dnload_done'); // pulse, USB domain

    // Bus-domain control regs first (so the consumer toggle exists).
    final usbEnableReg = Logic(name: 'usb_enable_reg');
    final advancePulse = Logic(name: 'advance_pulse'); // bus-domain W1P decode
    // consumerToggle (bus domain): flips each time the CPU acks a byte.
    final consumerToggle = Logic(name: 'consumer_toggle');

    // Synchronize the consumer toggle into the USB domain so the engine knows
    // its last byte was consumed and it may release the next.
    final consSyncUsb = HarborCdcSync(stages: 2, name: 'cons_sync');
    addSubModule(consSyncUsb);
    consSyncUsb.input('async_in').srcConnection! <= consumerToggle;
    consSyncUsb.input('dst_clk').srcConnection! <= usbClk;
    consSyncUsb.input('dst_reset').srcConnection! <= usbReset;
    final consumerInUsb = consSyncUsb.output('sync_out');

    // USB-domain producer side: latch byte + flip producer toggle.
    final producerToggle = Logic(name: 'producer_toggle');
    final byteHold = Logic(name: 'byte_hold', width: 8);
    final doneHold = Logic(name: 'done_hold');
    // sink_ready: the engine may push the next byte/marker only once the prior
    // one has been consumed, i.e. producer and (synchronized) consumer toggles
    // match. This is the depth-1 back-pressure that replaces the deep FIFO.
    final sinkReady = producerToggle.eq(consumerInUsb).named('sink_ready');

    Sequential(usbClk, [
      If(
        usbReset,
        then: [
          producerToggle < Const(0),
          byteHold < Const(0, width: 8),
          doneHold < Const(0),
        ],
        orElse: [
          // Capture a byte (or the done marker) only when the engine actually
          // strobes AND we are allowed to advance (sink_ready high).
          If(
            sinkReady & (sinkValid | dnloadDoneUsb),
            then: [
              byteHold < sinkData,
              doneHold < dnloadDoneUsb,
              producerToggle < ~producerToggle,
            ],
          ),
        ],
      ),
    ]);

    // Drive the engine's back-pressure input.
    engine.input('sink_ready').srcConnection! <= sinkReady;

    // Synchronize the producer toggle into the bus domain.
    final prodSyncBus = HarborCdcSync(stages: 2, name: 'prod_sync');
    addSubModule(prodSyncBus);
    prodSyncBus.input('async_in').srcConnection! <= producerToggle;
    prodSyncBus.input('dst_clk').srcConnection! <= busClk;
    prodSyncBus.input('dst_reset').srcConnection! <= busReset;
    final producerInBus = prodSyncBus.output('sync_out');

    // Bus-domain capture + register file.
    final rxData = Logic(name: 'rx_data_reg', width: 8);
    final rxValid = Logic(name: 'rx_valid_reg');
    final dnloadDoneSticky = Logic(name: 'dnload_done_sticky');
    final bytesCount = Logic(name: 'bytes_count', width: 32);
    final ackReg = Logic(name: 'sw_ack');
    // Last seen producer toggle (bus domain) to detect a fresh byte edge.
    final prodSeen = Logic(name: 'prod_seen');

    final stb = bus.stb;
    final we = bus.we;
    final wordSel = bus.addr.getRange(2, 4); // bits [3:2] -> 0..3

    // A new byte is present when the synchronized producer toggle differs from
    // what we last captured.
    final newByte = producerInBus.neq(prodSeen).named('new_byte');

    Sequential(busClk, [
      If(
        busReset,
        then: [
          usbEnableReg < Const(0),
          consumerToggle < Const(0),
          rxData < Const(0, width: 8),
          rxValid < Const(0),
          dnloadDoneSticky < Const(0),
          bytesCount < Const(0, width: 32),
          ackReg < Const(0),
          prodSeen < Const(0),
          advancePulse < Const(0),
        ],
        orElse: [
          // Single-cycle registered ACK.
          ackReg < (stb & ~ackReg),

          // Capture a freshly-crossed byte into RXDATA, set rx_valid.
          If(
            newByte,
            then: [
              rxData < byteHold,
              prodSeen < producerInBus,
              rxValid < Const(1),
              If(doneHold, then: [dnloadDoneSticky < Const(1)]),
              bytesCount < bytesCount + Const(1, width: 32),
            ],
          ),

          // Register writes (CONTROL at word offset 1).
          advancePulse < Const(0),
          If(
            stb & we & ~ackReg & wordSel.eq(Const(1, width: 2)),
            then: [
              usbEnableReg < bus.dataIn.getRange(0, 1),
              // advance (bit1, write-1-pulse): ack the current byte.
              If(
                bus.dataIn.getRange(1, 2).eq(Const(1, width: 1)),
                then: [
                  consumerToggle < ~consumerToggle,
                  rxValid < Const(0),
                  advancePulse < Const(1),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    bus.ack <= ackReg;

    // Read mux.
    final dfuState = engine.output('dfu_state'); // [3:0], USB domain (slow)
    final configured = engine.output('configured');
    // configured/dfu_state are slow status; sampling them directly across the
    // domain is acceptable for polling (they change at human/USB-transfer rate).
    final statusWord = [
      Const(0, width: busDataWidth - 8),
      dfuState, // [7:4]
      Const(0), // [3] reserved
      configured, // [2]
      dnloadDoneSticky, // [1]
      rxValid, // [0]
    ].swizzle().named('status_word');
    final controlWord = usbEnableReg
        .zeroExtend(busDataWidth)
        .named('ctrl_word');
    final rxWord = rxData.zeroExtend(busDataWidth).named('rx_word');
    final bytesWord = bytesCount.zeroExtend(busDataWidth).named('bytes_word');

    bus.dataOut <=
        mux(
          wordSel.eq(Const(0, width: 2)),
          statusWord,
          mux(
            wordSel.eq(Const(1, width: 2)),
            controlWord,
            mux(wordSel.eq(Const(2, width: 2)), rxWord, bytesWord),
          ),
        );

    // USB line tristate pads.
    final dpPad = inOut('usb_dp');
    final dmPad = inOut('usb_dm');
    final oe = engine.output('oe');
    final dpDrive = TriStateBuffer(engine.output('dp_out'), enable: oe);
    final dmDrive = TriStateBuffer(engine.output('dm_out'), enable: oe);
    dpPad <= dpDrive.out;
    dmPad <= dmDrive.out;
    engine.input('dp').srcConnection! <= dpPad;
    engine.input('dm').srcConnection! <= dmPad;

    // Pull-up enable, gated by the CPU-written usb_enable.
    output('usb_pullup') <= engine.output('usb_pullup') & usbEnableReg;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['river,dfu-sw'],
    reg: BusAddressRange(baseAddress, 0x1000),
  );
}
