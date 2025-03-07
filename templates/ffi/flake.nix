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
      url = "github:argumentcomputer/Blake3.lean?rev=29018d578b043f6638907f3425af839eec345361";
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
        blake3 = blake3-lean.inputs.blake3;
        blake3Mod = (blake3-lean.lib { inherit pkgs lean4-nix blake3; }).lib;
        blake3Lib = blake3Mod.blake3-lib;
        blake3C = blake3Mod.blake3-c;
      in
      {
        _module.args.pkgs = import nixpkgs {
          inherit system;
          overlays = [(lean4-nix.readToolchainFile ./lean-toolchain)];
        };

        packages.default = (pkgs.lean.buildLeanPackage {
          name = "ffi";
          src = ./.;
          roots = ["FFI" "Main"];
          deps = [ blake3Lib ];
          staticLibDeps = [ blake3C ];
          linkFlags = [ "-L${blake3C}/lib" "-lblake3" ];
        }).executable;

        devShells.default = pkgs.mkShell {
          packages = with pkgs.lean; [lean lean-all];
        };
      };
    };
}
