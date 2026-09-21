{
  description = "ripwire — ranked, deterministic codebase maps (Nix grammar lane)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = nixpkgs.lib.systems.flakeExposed;
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          ripwire = pkgs.callPackage ./package.nix { src = self; };
        in
        {
          inherit ripwire;
          default = ripwire;
        }
      );

      apps = forAllSystems (pkgs: {
        ripwire = {
          type = "app";
          program = "${self.packages.${pkgs.system}.ripwire}/bin/ripwire";
        };
        default = self.apps.${pkgs.system}.ripwire;
      });

      # Gate workbench: everything test/*.sh and scripts/*.sh reach for.
      # formatcheck pins clang-format major 22; nixpkgs ships 21, so gates run
      # with RIPWIRE_FORMAT_ANY_VERSION=1 (set in the shellHook).
      devShells = forAllSystems (
        pkgs:
        let
          gates = [
            pkgs.git
            pkgs.python3
            pkgs.libxml2 # xmllint
            pkgs.poppler-utils or pkgs.poppler_utils # pdftotext — attr renamed across pins
            pkgs.jq
            pkgs.shellcheck
            pkgs.coreutils # timeout
          ];
        in
        {
          default = pkgs.mkShell {
            packages = gates ++ [
              pkgs.cmake
              pkgs.ninja
              pkgs.clang-tools
            ];
            shellHook = ''
              export RIPWIRE_FORMAT_ANY_VERSION=1
              echo "ripwire lane devShell — build: cmake -S . -B build && cmake --build build -j"
            '';
          };
        }
      );
    };
}
