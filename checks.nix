{
  pkgs,
  lean,
  lake2nix,
  overlayPkgs,
}:
let
  srcOf = name: lake2nix.cleanLakeSource (./templates + "/${name}");

  minimalPkg = lake2nix.mkPackage {
    name = "minimal";
    src = srcOf "minimal";
  };

  dependencyDeps = lake2nix.buildDeps { src = srcOf "dependency"; };
  dependencyPkg = lake2nix.mkPackage {
    name = "Example";
    src = srcOf "dependency";
    lakeDeps = dependencyDeps;
    buildLibrary = true;
  };

  incrementalDeps = lake2nix.buildDeps { src = srcOf "incremental"; };
  incrementalLib = lake2nix.mkPackage {
    name = "Incremental";
    src = srcOf "incremental";
    lakeDeps = incrementalDeps;
    buildLibrary = true;
  };
  incrementalTest = lake2nix.mkPackage {
    name = "IncrementalTest";
    src = srcOf "incremental";
    lakeDeps = incrementalDeps;
    lakeArtifacts = incrementalLib;
    installArtifacts = false;
  };
  # The executable installed for standalone use: wrapped, with its own
  # modules and its dependencies' under `lib/lean`.
  incrementalBin = lake2nix.mkPackage {
    name = "IncrementalTest";
    src = srcOf "incremental";
    lakeDeps = incrementalDeps;
    lakeArtifacts = incrementalLib;
    installBin = true;
  };
  # The same chain with every artifact store archived: dependencies, the
  # library, and the executable continuing from both.
  zstdDeps = lake2nix.buildDeps {
    src = srcOf "incremental";
    depOverride = builtins.mapAttrs (_: _: { artifactsFormat = "zstd"; }) incrementalDeps;
  };
  zstdLib = lake2nix.mkPackage {
    name = "Incremental";
    src = srcOf "incremental";
    lakeDeps = zstdDeps;
    buildLibrary = true;
    artifactsFormat = "zstd";
  };
  zstdBin = lake2nix.mkPackage {
    name = "IncrementalTest";
    src = srcOf "incremental";
    lakeDeps = zstdDeps;
    lakeArtifacts = zstdLib;
    installBin = true;
  };
  # Runs an `installBin` IncrementalTest and checks the install layout around it.
  checkBin =
    name: pkg:
    pkgs.runCommand name { } ''
      [ "$(${pkg}/bin/IncrementalTest)" = "hello has 2 l chars" ]
      grep -q LEAN_PATH ${pkg}/bin/IncrementalTest
      test -f ${pkg}/lib/lean/Incremental.olean
      test -f ${pkg}/lib/lean/Batteries.olean
      test ! -e ${pkg}/.lake
      touch $out
    '';

  # An executable that evaluates a definition through the interpreter from a
  # module it does not import at compile time, so the code is not linked in
  # and Lean needs the module's IR from `lib/lean`.
  interpretSrc = lake2nix.cleanLakeSource ./test/interpret;
  interpretBin = lake2nix.mkPackage {
    name = "Interpret";
    src = interpretSrc;
    installBin = true;
  };
  interpretOleansOnly = lake2nix.mkPackage {
    name = "Interpret";
    src = interpretSrc;
    installBin = true;
    binFiles = [
      "*.olean"
      "*.olean.private"
      "*.olean.server"
    ];
  };

  # `dependency` is required from `incremental` by path, which is how Lake sees
  # a `lakefile.lean` dependency in a consumer workspace. Lake re-elaborates
  # such configs, so this exercises the writable `.lake` copies that
  # `mkLakeDerivation` sets up.
  crossDeps = dependencyDeps // {
    Example = dependencyPkg;
  };
  crossOverrides = pkgs.writers.writeJSON "package-overrides.json" {
    version = "1.1.0";
    packagesDir = ".lake/packages";
    packages = map (name: {
      inherit name;
      inherited = false;
      type = "path";
      dir = ".lake/packages/${name}";
    }) (builtins.attrNames crossDeps);
    name = "Incremental";
    lakeDir = ".lake";
  };
  crossPkg = lake2nix.mkPackage {
    name = "IncrementalTest";
    src = srcOf "incremental";
    lakeDeps = crossDeps;
    installArtifacts = false;
    prePatch = ''
      substituteInPlace lakefile.lean --replace-fail "package Incremental" 'require Example from "${dependencyPkg}"

      package Incremental'
      substituteInPlace Incremental.lean --replace-fail "import Batteries" 'import Batteries
      import Example'
      substituteInPlace IncrementalTest.lean --replace-fail "IO.println greeting" "IO.println cirno"
    '';
    preConfigure = ''
      mkdir -p .lake
      ln -s ${crossOverrides} .lake/package-overrides.json
    '';
  };
in
{
  # The toolchain builds, runs, and reports its version.
  toolchain = pkgs.testers.testVersion { package = lean; };

  # `bv-decide` shells out to `cadical`. Deliberately no `nativeBuildInputs`:
  # this asserts the toolchain supplies it.
  bv-decide = pkgs.runCommand "bv-decide" { } ''
    ${lean}/bin/lean ${./test/bv-decide.lean}
    touch $out
  '';

  # Going through the overlay must yield the same toolchain as `lib.${system}`.
  overlay = overlayPkgs.lean4-nix.fromToolchainFile ./templates/minimal/lean-toolchain;

  # A Lake executable builds and prints what it should.
  minimal = pkgs.testers.testEqualContents {
    assertion = "Call minimal";
    expected = pkgs.writeTextFile {
      name = "expected";
      text = "Da";
    };
    actual = pkgs.runCommand "actual" { } ''
      ${minimalPkg}/bin/minimal | head -c 2 > $out
    '';
  };

  # Dependencies resolved and built from `lake-manifest.json`.
  dependency = dependencyPkg;

  # A test target reusing the library target's `.lake` artifacts.
  incremental = incrementalTest;

  # An executable installed for standalone use.
  install-bin = checkBin "install-bin" incrementalBin;

  # Archived artifacts unpacked at every step of the chain.
  zstd = checkBin "zstd" zstdBin;

  # The default `binFiles` carry the IR the interpreter needs for code that
  # is not linked into the binary; without it the same program fails.
  interpret = pkgs.runCommand "interpret" { } ''
    [ "$(${interpretBin}/bin/Interpret)" = "hello from the interpreter" ]
    if ${interpretOleansOnly}/bin/Interpret 2> /dev/null; then
      echo "Interpret ran without IR files, so the check no longer tests them" >&2
      exit 1
    fi
    touch $out
  '';

  # A `lakefile.lean` dependency imported into another package.
  incremental-dep = crossPkg;
}
