# Takes a river-ip derivation and runs FPGA synthesis + place-and-route.
#
# Usage:
#   mkFpga { ip = self'.packages.creek-v1; }
#   mkFpga { ip = self'.packages.creek-v1-arty; seed = 3; }
#
# Two flows, picked from the IP target vendor:
#   - iCE40 / ECP5: yosys + nextpnr + icestorm/trellis (nixpkgs tools).
#   - spartan7 (Xilinx 7-series): the openXC7 flow (nextpnr-xilinx + prjxray).
#     The generated Makefile drives synth -> pnr -> pack; this derivation
#     feeds it the chipdb, prjxray-db and part, plus the python path that
#     prjxray's fasm2frames script imports.
#
# Produces: synth JSON, PnR output, bitstream
{
  lib,
  stdenvNoCC,
  yosys,
  nextpnr,
  icestorm,
  trellis,
  openxc7 ? null,
  openxc7Nixpkgs ? null,
}:

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "ip"
    "seed"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      ip,
      name ? "river-fpga-${ip.socName}",
      # nextpnr-xilinx placer seed. creek is dense on the xc7s50, so the route
      # is seed-sensitive; bump this if a build fails to route.
      seed ? 2,
      ...
    }@args:

    let
      targetParts = lib.splitString ":" (ip.target or "");
      vendor = if targetParts != [ ] then builtins.head targetParts else null;
      # openXC7 Xilinx 7-series flow.
      isOpenXc7 = vendor == "spartan7";
      device = builtins.elemAt targetParts 1; # e.g. xc7s50
      package = builtins.elemAt targetParts 2; # e.g. csga324
      part = "${device}${package}";

      # openXC7 toolchain pieces (only forced on the spartan7 path).
      chipdb = "${openxc7.nextpnr-xilinx-chipdb.spartan7}/${part}.bin";
      xrayDb = "${openxc7.nextpnr-xilinx}/share/nextpnr/external/prjxray-db";
      pyPkgs = openxc7Nixpkgs.python312Packages;
      # prjxray's fasm2frames is a bare python script. Reproduce the openXC7
      # devShell PYTHONPATH so its fasm/prjxray/textx imports resolve.
      fasmPythonPath = lib.concatStringsSep ":" [
        "${openxc7.fasm}/lib/python3.12/site-packages"
        "${openxc7.prjxray}/usr/share/python3"
        "${pyPkgs.textx}/lib/python3.12/site-packages"
        "${pyPkgs.arpeggio}/lib/python3.12/site-packages"
        "${pyPkgs.pyyaml}/lib/python3.12/site-packages"
        "${pyPkgs.intervaltree}/lib/python3.12/site-packages"
        "${pyPkgs.sortedcontainers}/lib/python3.12/site-packages"
        "${pyPkgs.simplejson}/lib/python3.12/site-packages"
      ];

      latticeTools = [
        yosys
        nextpnr
        icestorm # icepack
        trellis # ecppack
      ];
      xilinxTools = [
        yosys
        openxc7.nextpnr-xilinx
        openxc7.prjxray
        openxc7Nixpkgs.python312
      ];
    in

    builtins.removeAttrs args [
      "ip"
      "seed"
    ]
    // {
      inherit name;

      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs =
        (args.nativeBuildInputs or [ ]) ++ (if isOpenXc7 then xilinxTools else latticeTools);

      buildPhase = ''
        runHook preBuild

        # Copy IP output to writable directory
        cp -r ${ip}/* .
        chmod -R u+w .

        ${
          if isOpenXc7 then
            ''
              export PYTHONPATH="${fasmPythonPath}''${PYTHONPATH:+:$PYTHONPATH}"
              make all \
                CHIPDB=${chipdb} \
                XRAY_DB=${xrayDb} \
                PART=${part}-1 \
                SEED=${toString seed}
            ''
          else
            ''
              make all
            ''
        }

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out
        cp -r rtl $out/
        cp *.json $out/ 2>/dev/null || true
        cp *.asc $out/ 2>/dev/null || true
        cp *.config $out/ 2>/dev/null || true
        cp *.fasm $out/ 2>/dev/null || true
        cp *.bin $out/ 2>/dev/null || true
        cp *.bit $out/ 2>/dev/null || true
        cp *.dts $out/ 2>/dev/null || true
        cp *.dot $out/ 2>/dev/null || true
        cp *.pcf $out/ 2>/dev/null || true
        cp *.lpf $out/ 2>/dev/null || true
        cp *.xdc $out/ 2>/dev/null || true

        runHook postInstall
      '';

      passthru = {
        inherit ip;
        inherit (ip) socName;
      }
      // (args.passthru or { });
    };
}
