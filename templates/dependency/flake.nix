{
  description = "Lean 4 Example Project";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    lean4-nix = {
      url = "github:argumentcomputer/lean4-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    blake3-lean = {
      url = "github:argumentcomputer/Blake3.lean";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    nixpkgs,
    flake-parts,
    lean4-nix,
    blake3-lean,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem = {
        system,
        pkgs,
        ...
      }: 
      let
        blake3C = blake3-lean.packages.${system}.staticLib;
      in
      {
        _module.args.pkgs = import nixpkgs {
          inherit system;
          overlays = [(lean4-nix.readToolchainFile ./lean-toolchain)];
        };

        packages.default =
          ((lean4-nix.lake {inherit pkgs;}).mkPackage {
            src = ./.;
            roots = ["Main"];
            staticLibDeps = [ "${blake3C}/lib" ];
          })
          .executable;

        devShells.default = pkgs.mkShell {
          packages = with pkgs.lean; [lean lean-all];
        };
      };
    };
}
