{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.river;

  # Compile the ACPI DSDT that genip emitted into the IP package (one `.asl`)
  # into an AML blob for Weir to embed via `-Daml`.
  aml =
    pkgs.runCommand "river.aml"
      {
        nativeBuildInputs = [ pkgs.acpica-tools ];
      }
      ''
        iasl -p ./river ${cfg.ipPackage}/*.asl
        mv ./river.aml $out
      '';

  # Compile the device tree source that genip emitted into the IP package (one
  # `.dts`) into a DTB for Weir to embed via `-Ddtb`.
  dtb =
    pkgs.runCommand "river.dtb"
      {
        nativeBuildInputs = [ pkgs.dtc ];
      }
      ''
        dtc -I dts -O dtb -o $out ${cfg.ipPackage}/*.dts
      '';

  weirFirmware = pkgs.weir.overrideAttrs (
    f: p: {
      zigBuildFlags = (p.zigBuildFlags or [ ]) ++ [
        "-Daml=${aml}"
        "-Ddtb=${dtb}"
      ];
    }
  );
in
{
  options.hardware.river = {
    enable = lib.mkEnableOption "River hardware support";
    ipPackage = lib.mkOption {
      description = ''
        The IP package for the configuration of River.
      '';
      type = lib.types.package;
    };
  };

  config = lib.mkIf cfg.enable {
    boot.extraModulePackages = [ config.boot.kernelPackages.harbor-kmod ];

    system.build.river-firmware = weirFirmware;
  };
}
