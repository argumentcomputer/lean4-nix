{
  description = "Lean 4 Example Project";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
    lean4-nix.url = "github:argumentcomputer/lean4-nix";
    # TODO: Add a Nix flake for LSpec so it doesn't have to be rebuilt in each caller
    lspec = {
      url = "github:argumentcomputer/LSpec?ref=ca8e2803f89f0c12bf9743ae7abbfb2ea6b0eeec";
      flake = false;
    };
  };

  outputs = inputs @ {
    nixpkgs,
    flake-parts,
    lean4-nix,
    lspec,
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
      }: {
        _module.args.pkgs = import nixpkgs {
          inherit system;
          overlays = [(lean4-nix.readToolchainFile ./lean-toolchain)];
        };

        packages.default = ((lean4-nix.lake {inherit pkgs;}).mkPackage {
            name = "LakeProject";
            src = ./.;
            roots = ["Main" "LakeProject"]; # Add each `lean_lib` as a root
          }).executable;

        packages.lspec = ((lean4-nix.lake {inherit pkgs;}).mkPackage {
          name = "LSpec";
          src = "${lspec}";
          roots = ["Main" "LSpec"];
        }).executable;

        devShells.default = pkgs.mkShell {
          packages = with pkgs.lean; [lean lean-all];
        };
      };
    };
}
