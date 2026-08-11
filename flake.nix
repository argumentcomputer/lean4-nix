{
  description = "Lean 4 Nix Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      mkLib = pkgs: pkgs.callPackage ./lib/toolchains.nix { };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      inherit systems;

      flake = {
        # Toolchain selection, bound to this flake's nixpkgs so callers need not
        # supply one:
        #
        #   lean4-nix.lib.${system}.fromToolchainFile ./lean-toolchain
        #   lean4-nix.lib.${system}.fromToolchain "leanprover/lean4:v4.33.0"
        #   lean4-nix.lib.${system}.toolchains."v4.33.0"
        #
        # A toolchain is an ordinary derivation, so nothing here touches `pkgs`
        # and no overlay is required.
        lib = nixpkgs.lib.genAttrs systems (system: mkLib nixpkgs.legacyPackages.${system});

        # Constructs the same interface on an existing `pkgs`, for callers who
        # need the toolchain patched against their own nixpkgs rather than the
        # one pinned here — e.g. to match the stdenv they link Lean FFI code
        # with. Non-intrusive: it returns a value rather than modifying `pkgs`.
        #
        #   (lean4-nix.mkLib pkgs).fromToolchainFile ./lean-toolchain
        inherit mkLib;

        # Optional convenience for callers already building a `pkgs` with
        # overlays. Purely additive: it introduces a `lean4-nix` attribute and
        # overrides nothing, so `pkgs.lean` from nixpkgs is left alone.
        #
        #   pkgs.lean4-nix.fromToolchainFile ./lean-toolchain
        overlays.default = final: _prev: { lean4-nix = mkLib final; };

        lake = import ./lib/lake.nix;
        templates = import ./templates;
      };

      perSystem =
        { system, pkgs, ... }:
        let
          lean = (mkLib pkgs).fromToolchainFile ./templates/minimal/lean-toolchain;
          lake2nix = pkgs.callPackage self.lake { inherit lean; };
          overlayPkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
        in
        {
          packages = (mkLib pkgs).toolchains // {
            default = lean;
            toolchain-fetch = pkgs.callPackage ./lib/toolchain-fetch.nix { };
          };

          devShells.default = pkgs.mkShell {
            buildInputs = [ pkgs.prek ];
          };

          checks = import ./checks.nix {
            inherit
              pkgs
              lean
              lake2nix
              overlayPkgs
              ;
          };

          # The treefmt wrapper around `nixfmt`, so `nix fmt .` can take a
          # directory; bare `nixfmt` only accepts individual files.
          formatter = pkgs.nixfmt-tree;
        };
    };
}
