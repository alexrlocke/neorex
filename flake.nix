{
  description = "A Rex-native Neovim frontend built in Zig";

  inputs = {
    # zig-overlay has every Zig release; pick the exact version below.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    # ZLS (Zig language server) for 0.17 comes from unstable nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, zig-overlay, ... }:
    let
      # nixpkgs unstable has dropped x86_64-darwin; Intel Macs use the release binaries
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # one version, kept in build.zig.zon
      version = builtins.head
        (builtins.match ".*\n *\\.version = \"([^\"]+)\",.*" (builtins.readFile ./build.zig.zon));
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "neorex";
          inherit version;
          src = self;
          # the hook runs zig build -Doptimize=ReleaseSafe with --prefix $out,
          # which also installs share/neorex/runtime
          nativeBuildInputs = [ pkgs.zig_0_17.hook ];
          meta = {
            description = "A Rex-native Neovim frontend built in Zig";
            homepage = "https://github.com/alexrlocke/neorex";
            license = pkgs.lib.licenses.mit;
            mainProgram = "neorex";
            platforms = systems;
          };
        };
      });

      # adds pkgs.neorex; uses this flake's build so the user's nixpkgs
      # doesn't need Zig 0.17
      overlays.default = final: prev: {
        neorex = self.packages.${final.stdenv.hostPlatform.system}.default;
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.17.0"
            pkgs.zls_0_17 # language server; keep its minor version in step with zig
          ];
        };
      });
    };
}
