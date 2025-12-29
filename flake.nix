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
      # Refer to https://github.com/mitchellh/zig-overlay if you want to use a specific version of Zig
      zigPackage = zig-overlay.packages.${system}."default"; #"master";
      pkgs = nixpkgs.legacyPackages.${system};
      packageName = "zsdl3";
    in {
      formatter = pkgs.nixpkgs-fmt;

      devShells.default = pkgs.mkShell {
        name = packageName;
        packages =
          #with pkgs;
          [
            # vulkan-validation-layers
            zls-overlay.packages.x86_64-linux."0.15.0"
            zigPackage
          ];
        # LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
        #   mesa
        #   alsa-lib
        #   libdecor
        #   libusb1
        #   libxkbcommon
        #   vulkan-loader
        #   wayland
        #   xorg.libX11
        #   xorg.libXext
        #   xorg.libXi
        #   xorg.libXrandr
        #   xorg.libXinerama
        #   xorg.libXcursor
        #   xorg.libXfixes
        #   udev
        #   dbus
        #   wayland
        #   wayland-protocols
        # ]);
      };
    });
}
