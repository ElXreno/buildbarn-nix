{
  description = "Buildbarn remote execution packages and NixOS module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: _prev: {
        bb-storage = final.callPackage ./packages/bb-storage { };
        bb-remote-execution = final.callPackage ./packages/bb-remote-execution { };
      };

      packages = forAllSystems (pkgs: {
        bb-storage = pkgs.callPackage ./packages/bb-storage { };
        bb-remote-execution = pkgs.callPackage ./packages/bb-remote-execution { };
      });

      nixosModules = {
        buildbarn = ./modules/buildbarn.nix;
        default = self.nixosModules.buildbarn;
      };

      checks = forAllSystems (pkgs: {
        nixos = pkgs.testers.runNixOSTest (import ./tests/nixos.nix self);
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
