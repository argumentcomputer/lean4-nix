{
  description = "Example LSpec Project";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
    lean4-nix.url = "github:argumentcomputer/lean4-nix";
    lspec = {
      url = "github:argumentcomputer/LSpec";
      inputs.lean4-nix.follows = "lean4-nix";
      #rev = "";
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
        self',
        ...
      }:
        let
          lspecLib = (lspec.lib {inherit pkgs lean4-nix;}).lib;
        in
      {
        _module.args.pkgs = import nixpkgs {
          inherit system;
          overlays = [(lean4-nix.readToolchainFile ./lean-toolchain)];
        };

        packages = lspecLib.mkTests ./. // {
          default = ((lean4-nix.lake {inherit pkgs;}).mkPackage {
          name = "LSpecProject";
          src = ./.;
          roots = ["Main" "LSpecProject"]; # Add each `lean_lib` as a root
        }).executable;
          lspec = lspecLib.allTests ./.;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs.lean; [lean lean-all];
        };
      };
    };
}
