{
  description = "Lean 4 Example Project with Local Packages";

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
        in
        {
          # `wrapExecutables` sets `LEAN_PATH` to the search path Lake used, so
          # the executable can import the local package's modules at run time
          packages.default = lake2nix.wrapExecutables (
            lake2nix.mkPackage {
              name = "local";
              src = lake2nix.cleanLakeSource ./.;
            }
          );

          devShells.default = pkgs.mkShell {
            packages = [ lean ];
          };
        };
    };
}
