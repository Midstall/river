# Takes a river-ip derivation and runs FPGA synthesis + place-and-route.
#
# Usage:
#   mkFpga { ip = self'.packages.creek-v1; }
#
# Produces: synth JSON, PnR output, bitstream
{
  lib,
  stdenvNoCC,
  yosys,
  nextpnr,
  icestorm,
  trellis,
}:

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "ip"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      ip,
      name ? "river-fpga-${ip.socName}",
      ...
    }@args:

    builtins.removeAttrs args [ "ip" ]
    // {
      inherit name;

      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        yosys
        nextpnr
        icestorm # icepack
        trellis # ecppack
      ];

      buildPhase = ''
        runHook preBuild

        # Copy IP output to writable directory
        cp -r ${ip}/* .
        chmod -R u+w .

        make all

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out
        cp -r rtl $out/
        cp *.json $out/ 2>/dev/null || true
        cp *.asc $out/ 2>/dev/null || true
        cp *.config $out/ 2>/dev/null || true
        cp *.bin $out/ 2>/dev/null || true
        cp *.bit $out/ 2>/dev/null || true
        cp *.dts $out/ 2>/dev/null || true
        cp *.dot $out/ 2>/dev/null || true
        cp *.pcf $out/ 2>/dev/null || true
        cp *.lpf $out/ 2>/dev/null || true

        runHook postInstall
      '';

      passthru = {
        inherit ip;
        inherit (ip) socName;
      }
      // (args.passthru or { });
    };
}
