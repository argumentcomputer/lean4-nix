{
  tag = "v4.30.0";
  rev = "d024af099ca4bf2c86f649261ebf59565dc8c622";
  toolchain = {
    aarch64-linux = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.30.0/lean-4.30.0-linux_aarch64.tar.zst";
      hash = "sha256-yZxvDt1EaVbUdYxZ1Dg+jmQR/2zHGgH5yqvl66RUEh0=";
    };
    x86_64-linux = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.30.0/lean-4.30.0-linux.tar.zst";
      hash = "sha256-Ta10FBwsEZyhqmJmVr6DuOFCOK+6lycf178es/CBsxk=";
    };
    x86_64-darwin = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.30.0/lean-4.30.0-darwin.tar.zst";
      hash = "sha256-s43YoltbUJbGyQGef/rdvZGiP8tTgnUyJeMxRRV2jKI=";
    };
    aarch64-darwin = {
      url = "https://github.com/leanprover/lean4/releases/download/v4.30.0/lean-4.30.0-darwin_aarch64.tar.zst";
      hash = "sha256-By3KSjj7wNPO25b+qIbMJDtCTyvRYkdZYgC5qauT8PU=";
    };
  };
  inherit (import ./v4.19.0.nix) overlay;
  inherit (import ./v4.29.0.nix) bootstrap;
  inherit (import ./v4.27.0.nix) buildLeanPackage;
}
