{
  description = "FFI Nix flake template (Lean4 + C + Rust)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    lean4-nix = {
      url = "github:argumentcomputer/lean4-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs = inputs @ { nixpkgs, flake-parts, lean4-nix, fenix, crane, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Systems we want to build for
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      
      # Exporting the library as a flake allows other packages to use the FFI static libraries
      flake = {
        lib = import ./lib.nix;
        inputs.fenix = fenix;
        inputs.crane = crane;
      };

      perSystem = { system, pkgs, ... }:
      let
        lib = (import ./lib.nix { inherit system pkgs fenix crane lean4-nix; }).lib;
      in {
        # Lean overlay
        _module.args.pkgs = import nixpkgs {
          inherit system;
          overlays = [(lean4-nix.readToolchainFile ./lean-toolchain)];
        };

        packages = {
          default = lib.leanPkg.executable;
          test = lib.leanTest.executable;
        };

        devShells.default = pkgs.mkShell {
          LEAN_SYSROOT="${pkgs.lean.lean-all}";
          packages = with pkgs; [
            pkg-config
            openssl
            ocl-icd
            gcc
            clang
            lib.rustToolchain
            rust-analyzer
            lean.lean         # Lean compiler
            lean.lean-all     # Includes Lake, stdlib, etc.
          ];
        };
      };
    };
}
