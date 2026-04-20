# Declarative SoC definitions.
# Each device has a base config and a set of targets (FPGA or ASIC).
{
  river-hdl,
  sky130-pdk ? null,
  gf180mcu-pdk ? null,
}:
let
  creek-v1-base = {
    socName = "creek_v1";
    cores = [ "rc1-s" ];
    interconnect = "wishbone";
    clockFreq = 48000000;
    memories = [
      "0x20000000:16M:flash"
      "0x80000000:128M:dram"
    ];
    devices = [
      "clint:0x02000000"
      "plic:0x04000000"
      "uart:0x10000000:ns16550a"
    ];
  };

  stream-v1-base = {
    socName = "stream_v1";
    cores = [ "rc1-n" ];
    interconnect = "wishbone";
    clockFreq = 12000000;
    memories = [
      "0x20000000:16M:flash"
      "0x80000000:1M:sram"
    ];
    devices = [
      "clint:0x02000000"
      "plic:0x04000000"
      "uart:0x10000000:ns16550a"
    ];
  };
in
{
  creek-v1-orangecrab = {
    ip = river-hdl.mkSoC (
      creek-v1-base
      // {
        target = "ecp5:lfe5u-25f:CSFBGA285";
        clockFreq = 48000000;
        oscFreq = 48000000;
        memories = [
          "0x20000000:16M:flash:orangecrab"
          "0x80000000:64K:sram"
          "0x90000000:128M:dram:orangecrab"
        ];
        bootProgram = "monitor";
        pins = [
          "clk=A9"
          "uart_tx=uart@tx:N17"
          "uart_rx=uart@rx:M18"
        ];
      }
    );
  };

  # Digilent Arty S7-50 (xc7s50, csga324, 100MHz osc), Xilinx via the openXC7
  # flow. DDR3 runs as x8 on the low byte-lane (arty-s7-x8, 128MB): the
  # hardware-verified read and write path at cmdslot=2,wrshift=-1. The x16 high
  # lane (per-lane write-leveling) is still under debug. Boot monitor runs from
  # the 64K EBR SRAM and DDR is promoted separately. Pins from the working
  # bring-up (clk=R2, UART R12/V12).
  creek-v1-arty = {
    ip = river-hdl.mkSoC (
      creek-v1-base
      // {
        target = "spartan7:xc7s50:csga324";
        clockFreq = 25000000;
        oscFreq = 100000000;
        memories = [
          "0x20000000:16M:flash:arty-s7"
          "0x80000000:64K:sram"
          "0x90000000:128M:dram:arty-s7-x8:ddr3fast=true,clockfreq=400000000,cmdslot=2,wrshift=-1,trainable=true"
        ];
        bootProgram = "monitor";
        pins = [
          "clk=R2"
          "uart_tx=uart@tx:R12"
          "uart_rx=uart@rx:V12"
        ];
      }
    );
  };

  creek-v1-sky130 = {
    ip = river-hdl.mkSoC (
      creek-v1-base
      // {
        target = "sky130:hd";
        pdkRoot = "${sky130-pdk}/${sky130-pdk.pdkPath}";
      }
    );
    # asix.mkTapeout metadata: topCell matches the genip SoC name, and the
    # clock period is derived from the device's target frequency.
    topCell = creek-v1-base.socName;
    clockPeriodNs = 1.0e9 / creek-v1-base.clockFreq;
    pdk = sky130-pdk;
  };

  creek-v1-gf180mcu = {
    ip = river-hdl.mkSoC (
      creek-v1-base
      // {
        target = "gf180mcu:3v3";
        pdkRoot = "${gf180mcu-pdk}/${gf180mcu-pdk.pdkPath}";
      }
    );
    topCell = creek-v1-base.socName;
    clockPeriodNs = 1.0e9 / creek-v1-base.clockFreq;
    pdk = gf180mcu-pdk;
  };

  # iCESugar v1.5 (iCE40UP5K-SG48, 12MHz). The up5k holds only ~128KB on-chip,
  # so the shared 16M-flash/1M-sram base map does not fit. Override it with a
  # single 64KB on-chip data SRAM and drop the external regions.
  stream-v1-ice40 = {
    ip = river-hdl.mkSoC (
      stream-v1-base
      // {
        target = "ice40:up5k:sg48";
        memories = [
          "0x20000000:16M:flash"
          "0x80000000:128K:sram"
        ];
        # No PLIC: this board has no routed interrupt sources and the unused
        # 32-source arbiter costs ~900 cells of the up5k. The CLINT covers the
        # timer. External IRQs can return with a slimmer controller if needed.
        devices = [
          "clint:0x02000000"
          "uart:0x10000000:ns16550a"
        ];
        # Serial boot monitor in the boot ROM (no cache-as-RAM): prints a banner
        # then loads checksummed payloads into the SRAM over the UART.
        bootProgram = "monitor";
        # Board UART (iCELink USB-CDC bridge): FPGA tx=6, rx=4 per the official
        # iCESugar pcf. Pins 14/15 are SPI-flash lines, not the UART.
        pins = [
          "clk=35"
          "uart_tx=uart@tx:6"
          "uart_rx=uart@rx:4"
        ];
      }
    );
  };

  # OrangeCrab r0.2 (LFE5U-25F, csfbga285, 48MHz osc). Pins proven on this
  # board by the NixVegas SoC (clk=A9, uart on feather N17/M18 via an
  # external USB-TTL adapter; the USB-C port is raw, no onboard bridge).
  # Same monitor profile as the iCESugar: rc1-n + 64KB byte-masked EBR SRAM.
  stream-v1-orangecrab = {
    ip = river-hdl.mkSoC (
      stream-v1-base
      // {
        target = "ecp5:lfe5u-25f:CSFBGA285";
        clockFreq = 48000000;
        # The OrangeCrab oscillator is 48MHz (not the 12MHz default): with
        # the default the system PLL multiplies x4 and the whole SoC would
        # run at 192MHz on hardware.
        oscFreq = 48000000;
        # DDR3 (MT41K64M16, 128MB, hardware-verified) sits beside the SRAM
        # boot path; promoting it to main RAM at 0x80000000 is a follow-up.
        # The dram region pulls the board's full sdram_* pad constraint set
        # with it.
        memories = [
          "0x20000000:16M:flash:orangecrab"
          "0x80000000:64K:sram"
          "0x90000000:128M:dram:orangecrab"
        ];
        bootProgram = "monitor";
        pins = [
          "clk=A9"
          "uart_tx=uart@tx:N17"
          "uart_rx=uart@rx:M18"
        ];
      }
    );
  };

  stream-v1-gf180mcu = {
    ip = river-hdl.mkSoC (
      stream-v1-base
      // {
        target = "gf180mcu:3v3";
        pdkRoot = "${gf180mcu-pdk}/${gf180mcu-pdk.pdkPath}";
      }
    );
    topCell = stream-v1-base.socName;
    clockPeriodNs = 1.0e9 / stream-v1-base.clockFreq;
    pdk = gf180mcu-pdk;
  };
}
