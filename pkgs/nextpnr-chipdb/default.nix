# Builds a nextpnr-xilinx chip database (.bin) for a single 7-series part, from
# the prjxray-db and bbaexport that ship inside a given nextpnr-xilinx. The BBA
# schema is tied to the nextpnr SOURCE version, so this MUST be built from the
# same nextpnr-xilinx that will consume it (that is the whole reason it lives
# here rather than reusing a mismatched prebuilt chipdb).
{
  lib,
  stdenvNoCC,
  nextpnr-xilinx,
  pypy310,
}:

{
  device, # e.g. "xc7s50"
  package, # e.g. "csga324"
  family ? "spartan7",
}:

let
  part = "${device}${package}";
in
stdenvNoCC.mkDerivation {
  name = "nextpnr-xilinx-chipdb-${part}";
  inherit (nextpnr-xilinx) version;

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [ pypy310 ];

  buildPhase = ''
    runHook preBuild
    mkdir -p $out
    db=${nextpnr-xilinx}/share/nextpnr/external/prjxray-db/${family}
    # Pick the first speed grade directory for the part (e.g. ${part}-1).
    sg=$(basename $(ls -d $db/${part}-* | sort -n | head -1))
    echo "bba-exporting $sg -> ${part}.bin"
    pypy3.10 ${nextpnr-xilinx}/share/nextpnr/python/bbaexport.py --device "$sg" --bba ${part}.bba
    ${nextpnr-xilinx}/bin/bbasm -l ${part}.bba $out/${part}.bin
    runHook postBuild
  '';

  dontInstall = true;

  meta = {
    description = "nextpnr-xilinx chipdb for ${part}";
    platforms = lib.platforms.all;
  };
}
