{
  description = "Zig project dev environment";

  inputs = {
    # zig-overlay has every Zig release; pick the exact version below.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    # ZLS (Zig language server) for 0.17 comes from unstable nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, zig-overlay, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      zig = zig-overlay.packages.${system}."0.17.0";
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          zig
          pkgs.zls_0_17 # language server; keep its minor version in step with zig
        ];
      };
    };
}
