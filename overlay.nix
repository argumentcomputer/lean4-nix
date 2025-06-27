let
  readSrc = {
    src,
    bootstrap,
  }: final: prev:
    prev
    // rec {
      lean =
        (prev.callPackage ./lib/packages.nix {inherit src bootstrap;})
        // {
          lake = lean.Lake-Main.executable;
        };
    };
  readFromGit = {
    args,
    bootstrap,
  }:
    readSrc {
      src = builtins.fetchGit args;
      inherit bootstrap;
    };
  readRev = {
    rev,
    bootstrap,
    tag,
  }:
    readFromGit {
      args = {
        url = "https://github.com/leanprover/lean4.git";
        ref = "refs/tags/${tag}";
        inherit rev;
      };
      inherit bootstrap;
    };
  readToolchain = toolchain:
    builtins.addErrorContext "Only leanprover/lean4:{tag} toolchains are supported" (let
      matches = builtins.match "^[[:space:]]*leanprover/lean4:([a-zA-Z0-9\\-\\.]+)[[:space:]]*$" toolchain;
      tag = builtins.head matches;
      tagSrc = builtins.fetchGit {
        url = "https://github.com/argumentcomputer/lean4-nix.git";
        ref = "refs/tags/${tag}";
        # Update this when the commit changes. `nix build` will print the correct hash on error
        narHash = "sha256-UsS42vHKe9TUXXj6gRlDXZ5qUx2akBW8tRPD2ziQLgE=";
      };
      manifest = import (tagSrc.outPath + "/lib/bootstrap.nix");
      in
        readRev { inherit (manifest) tag rev bootstrap; }
    );

  readToolchainFile = toolchainFile: readToolchain (builtins.readFile toolchainFile);
in {
  inherit readSrc readFromGit readRev readToolchain readToolchainFile;
}
