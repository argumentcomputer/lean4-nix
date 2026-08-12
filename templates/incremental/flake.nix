{
  description = "Lean 4 Example Project";

  inputs = {
    nixpkgs.follows = "lean4-nix/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    lean4-nix.url = "github:argumentcomputer/lean4-nix";
  };

  outputs =
    inputs@{
      flake-parts,
      lean4-nix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          ...
        }:
        let
          lean = lean4-nix.lib.${system}.fromToolchainFile ./lean-toolchain;
          lake2nix = pkgs.callPackage lean4-nix.lake { inherit lean; };
          # Restrict the build inputs to the files `lake build` reads, so edits
          # to the flake or docs don't invalidate the build.
          src = lake2nix.cleanLakeSource ./.;
          # Build all dependencies from `lake-manifest.json`
          lakeDeps = lake2nix.buildDeps {
            inherit src;
          };
          # Arguments shared by all build targets
          commonArgs = {
            inherit lakeDeps src;
          };
          incLib = lake2nix.mkPackage (
            commonArgs
            // {
              name = "Incremental";
              # Build library facets ahead of time for use as a dependency
              buildLibrary = true;
            }
          );
          incTest = lake2nix.mkPackage (
            commonArgs
            // {
              name = "IncrementalTest";
              # Copy `.lake` artifacts from library derivation
              lakeArtifacts = incLib;
              # Don't export source code or `.lake` artifacts, since a test won't be used as a dependency
              installArtifacts = false;
            }
          );
        in
        {
          packages = {
            default = incLib;
            test = incTest;
          };

          devShells.default = pkgs.mkShell {
            packages = [ lean ];
          };
        };
    };
}
