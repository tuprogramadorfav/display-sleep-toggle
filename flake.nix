{
  description = "Menu bar switch that keeps a Mac's display on, with brightness key shortcuts";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "aarch64-darwin" ]
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: { default = pkgs.callPackage ./package.nix { }; });
      darwinModules.default = ./module.nix;
    };
}
