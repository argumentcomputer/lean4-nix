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

  # A `lakefile.lean` dependency imported into another package.
  incremental-dep = crossPkg;
}
