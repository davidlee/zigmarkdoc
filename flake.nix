{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls-overlay.url = "github:omega-800/zls-overlay";
  };
  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
    zls-overlay,
  }:
    flake-utils.lib.eachSystem ["x86_64-linux"] (system: let
      zigPackage = zig-overlay.packages.${system}."default";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      formatter = pkgs.nixpkgs-fmt;

      packages.default = pkgs.stdenv.mkDerivation {
        pname = "zigmarkdoc";
        version = "0.0.1";
        src = ./.;

        nativeBuildInputs = [zigPackage];

        dontConfigure = true;
        dontInstall = true;

        buildPhase = ''
          export XDG_CACHE_HOME="$TMPDIR"
          zig build --prefix $out -Doptimize=ReleaseSafe
        '';
      };

      devShells.default = pkgs.mkShell {
        name = "zigmarkdoc";
        packages = [
          zls-overlay.packages.x86_64-linux."0.15.0"
          zigPackage
        ];
      };
    });
}
