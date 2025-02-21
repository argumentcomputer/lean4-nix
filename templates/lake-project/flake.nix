{
  description = "Lean 4 Example Project";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
    lean4-nix.url = "github:argumentcomputer/lean4-nix";
  };

  outputs = inputs @ {
    nixpkgs,
    flake-parts,
    lean4-nix,
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

        packages.test = ((lean4-nix.lake {inherit pkgs;}).mkPackage {
            name = "Test";
            src = ./.;
            roots = ["Tests.Add" "LakeProject"];
          }).executable;

        devShells.default = pkgs.mkShell {
          packages = with pkgs.lean; [lean lean-all];
        };
      };
    };
}
