{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      systems,
      treefmt-nix,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { inputs, ... }:
      {
        systems = import inputs.systems;

        perSystem =
          {
            lib,
            system,
            pkgs,
            ...
          }:
          let
            treefmtEval = inputs.treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
            version = "0.1.0-git+${self.shortRev or "dirty"}";
            pubspecLock = lib.importJSON ./pubspec.lock.json;

            inherit (pkgs) buildDartApplication;

            gitHashes = {
              rohd_hcl = "sha256-YobXIH2PTUXxp6MfcAIJG8aXhkc1MZOLthOEaQUJxOM=";
            };

            buildDartTest =
              args:
              (buildDartApplication (
                args
                // {
                  pname = "${args.pname}-tests";

                  nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
                    pkgs.lcov
                  ];

                  buildPhase = ''
                    runHook preBuild
                    mkdir -p $out $out/coverage

                    dart --old_gen_heap_size=40960 --packages=.dart_tool/package_config.json --pause-isolates-on-exit --disable-service-auth-codes --enable-vm-service=8181 $(packagePath test)/bin/test.dart $packageRoot --file-reporter=json:$out/report.json -r expanded &

                    packageRun coverage -e collect_coverage --wait-paused --uri=http://127.0.0.1:8181/ -o $out/coverage/report.json --resume-isolates --scope-output=${args.pname}
                    packageRun coverage -e format_coverage --packages=.dart_tool/package_config.json --lcov -i $out/coverage/report.json -o $out/coverage/lcov.info

                    if [[ -s $out/coverage/lcov.info ]]; then
                      genhtml -o $out/coverage/html $out/coverage/lcov.info
                    fi

                    runHook postBuild
                  '';

                  dontInstall = true;
                }
              )).overrideAttrs
                { outputs = [ "out" ]; };
          in
          {
            _module.args.pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [ ];
            };

            formatter = treefmtEval.config.build.wrapper;

            checks = {
              formatting = treefmtEval.config.build.check self;
            }
            // lib.mapAttrs' (name: lib.nameValuePair "${name}-tests") (
              lib.genAttrs
                [
                  "bintools"
                  "riscv"
                  "river"
                  "river_adl"
                  "river_emulator"
                  "river_hdl"
                ]
                (
                  pname:
                  buildDartTest {
                    inherit
                      pname
                      version
                      pubspecLock
                      gitHashes
                      ;

                    src = ./.;
                    packageRoot = "packages/${pname}";
                  }
                )
            );

            packages = {
              default = buildDartApplication {
                pname = "river";
                inherit version pubspecLock gitHashes;

                src = ./.;

                dartEntryPoints = {
                  "bin/river-emulator" = "packages/river_emulator/bin/river_emulator.dart";
                  "bin/river-hdlgen" = "packages/river_hdl/bin/river_hdlgen.dart";
                };

                preBuild = ''
                  mkdir -p bin
                '';
              };
              emulator = buildDartApplication {
                pname = "river-emulator";
                inherit version pubspecLock gitHashes;

                src = ./.;
                packageRoot = "packages/river_emulator";

                dartEntryPoints."bin/river-emulator" = "packages/river_emulator/bin/river_emulator.dart";

                preBuild = ''
                  mkdir -p bin
                '';
              };
              hdl = buildDartApplication {
                pname = "river-hdl";
                inherit version pubspecLock gitHashes;

                src = ./.;
                packageRoot = "packages/river_hdl";

                dartEntryPoints."bin/river-hdlgen" = "packages/river_hdl/bin/river_hdlgen.dart";

                preBuild = ''
                  mkdir -p bin
                '';
              };
            };

            devShells.default = pkgs.mkShell {
              packages =
                with pkgs;
                (
                  [
                    yq
                    dart
                    yosys
                    icestorm
                    nextpnr
                    gtkwave
                    surfer
                    pkgsCross.riscv32-embedded.stdenv.cc
                    pkgsCross.riscv64-embedded.stdenv.cc
                  ]
                  ++ lib.optionals (!stdenv.hostPlatform.isDarwin) [
                    icesprog
                    (openroad.overrideAttrs {
                      doCheck = !pkgs.stdenv.hostPlatform.isAarch64;
                    })
                  ]
                );
            };
          };
      }
    );
}
