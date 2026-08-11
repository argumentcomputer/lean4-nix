{ pkgs, writeShellApplication }:
writeShellApplication {
  name = "toolchain-fetch";
  runtimeInputs = with pkgs; [
    jq
    wget
    coreutils
    nix
  ];
  # Inlined rather than `exec`d so that `writeShellApplication` runs shellcheck
  # over the actual script instead of a one-line wrapper.
  text = builtins.readFile ./toolchain-fetch.sh;
}
