{system, pkgs, fenix, crane, lean4-nix}:
let
  # Pins the Rust toolchain
  rustToolchain = fenix.packages.${system}.fromToolchainFile {
    file = ./rust-toolchain.toml;
    sha256 = "sha256-hpWM7NzUvjHg0xtIgm7ftjKCc1qcAeev45XqD3KMeQo=";
  };

  # Rust package
  craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
  src = craneLib.cleanCargoSource ./.;
  commonArgs = {
    inherit src;
    strictDeps = true;

    buildInputs = [
      # Add additional build inputs here
    ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
      # Additional darwin specific inputs can be set here
      pkgs.libiconv
    ];
  };
  craneLibLLvmTools = craneLib.overrideToolchain rustToolchain;
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  rustPkg = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
  });

  # C Package
  cPkg = let
    # Function to get all files in `./c` ending with given extension
    getFiles = ext: builtins.filter (file: builtins.match (".*" + ext) file != null) (builtins.attrNames (builtins.readDir "${toString ./c}"));
    # Gets all C files in `./c`, without the extension
    cFiles = let ext = ".c"; in builtins.map (file: builtins.replaceStrings [ext] [""] file) (getFiles ext);
    # Creates `gcc -c` command for each C file
    buildCmd = builtins.map (file: "gcc -Wall -Werror -Wextra -c ${file}.c -o ${file}.o") cFiles;
    # Final `buildPhase` instructions
    buildSteps = buildCmd ++
    [
      "ar rcs libffi_c.a ${builtins.concatStringsSep " " (builtins.map (file: "-o ${file}.o") cFiles)}"
    ];
    # Gets all header files in `./c`
    hFiles = getFiles ".h";
    # Final `installPhase` instructions
    installSteps =
    [
      "mkdir -p $out/lib $out/include"
      "cp libffi_c.a $out/lib/"
      "cp ${builtins.concatStringsSep " " hFiles} $out/include/"
    ];
  in
  pkgs.stdenv.mkDerivation {
    pname = "ffi_c";
    version = "0.1.0";
    src = ./c;
    buildInputs = [ pkgs.gcc pkgs.lean.lean-all rustPkg ];
    # Builds the C files
    buildPhase = builtins.concatStringsSep "\n" buildSteps;
    # Installs the library files
    installPhase = builtins.concatStringsSep "\n" installSteps;
  };

  # Lean package
  # Fetches external dependencies
  leanPkgBase = (lean4-nix.lake { inherit pkgs; }).mkPackage {
      src = ./.;
      roots = ["RustFFI" "Main"];
  };
  # Builds final library and links to FFI static libs
  # Any external FFI libraries must be linked explicitly in `linkFlags`, per
  # https://github.com/argumentcomputer/lean4-nix/issues/8
  leanPkg = (pkgs.lean.buildLeanPackage {
    name = "ffi_rust";
    src = ./.;
    deps = [ leanPkgBase ];
    roots = ["RustFFI" "Main"];
    linkFlags = [ "-L${rustPkg}/lib" "-lffi_rs" "-L${cPkg}/lib" "-lffi_c" ];
  });
  # Builds test package
  leanTest = (pkgs.lean.buildLeanPackage {
    name = "ffi_test";
    src = ./.;
    deps = [ leanPkg ];
    roots = ["Tests.Main" "RustFFI"];
    linkFlags = [ "-L${rustPkg}/lib" "-lffi_rs" "-L${cPkg}/lib" "-lffi_c" ];
  });
  lib = {
    inherit
      rustToolchain
      leanPkg
      leanTest
      cPkg;
  };
in
{
  inherit lib;
}
