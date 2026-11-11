{
  pkgs,
  lib,
  stdenv,
  lean,
}:
let
  capitalize =
    s:
    let
      first = lib.toUpper (builtins.substring 0 1 s);
      rest = builtins.substring 1 (-1) s;
    in
    first + rest;
  importLakeManifest =
    manifestFile:
    let
      manifest = lib.importJSON manifestFile;
    in
    lib.warnIf (manifest.version != "1.1.0" && manifest.version != "1.2.0") (
      "Unknown version: " + builtins.toString manifest.version
    ) manifest;
  # Git packages get their own derivations and shadow directories. Path
  # packages are part of the workspace that contains them and are built there.
  isGitPackage = package: (package.type or "git") == "git";
  # An internal wrapper around `mkDerivation` which sets up the lake manifest and runs `lake build`. End users should call `buildDeps` and `mkPackage` instead
  mkLakeDerivation =
    args@{
      # Name of the build target used to build shared and static facets. When building with `mkPackage` this is not used as the `buildPhase` is overriden
      name,
      # Path to the source
      src,
      # Attr set of the Lake package's dependency derivations
      deps ? { },
      # Whether to build `shared` and `static` facets of a library target.
      buildLibrary ? false,
      # Whether to export the workspace (source and every build output) for
      # incremental builds and use as a dependency
      installArtifacts ? true,
      # Whether to record the runtime search path in `nix-support/lean-path`
      # for `wrapExecutables`. Only takes effect with `installArtifacts`.
      recordLeanPath ? false,
      ...
    }:
    let
      manifest = importLakeManifest "${src}/lake-manifest.json";
      # Creates a surrogate manifest pointing Git packages at local shadow
      # directories, which symlink source files from the Nix store. Path
      # packages keep their workspace-relative `dir`.
      replaceManifest = (
        lib.setAttr manifest "packages" (
          builtins.map (
            package:
            if isGitPackage package then
              {
                inherit (package) name;
                inherited = package.inherited or false;
                type = "path";
                dir = ".lake/packages/${package.name}";
              }
            else
              package
          ) manifest.packages
        )
      );
      replaceManifestJson = pkgs.writers.writeJSON "lake-manifest.json" replaceManifest;
    in
    stdenv.mkDerivation (
      {
        buildInputs = [
          pkgs.rsync
          lean
        ];

        # Creates shadow directories for dependencies: source files are symlinked
        # from the Nix store. For `lakefile.lean` deps (detected by `.lake/config`
        # existing), `.lake/` is replaced with real writable copies since Lake
        # re-elaborates configs and may rebuild artifacts in a consumer workspace.
        # A shadow restored from `lakeArtifacts` is replaced, since `cp -rs`
        # into an existing directory would nest a second copy inside it.
        configurePhase = ''
          runHook preConfigure
          mkdir -p .lake/packages
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (depName: depPath: ''
              rm -rf ".lake/packages/${depName}"
              cp -rs "${depPath}" ".lake/packages/${depName}"
              if [ -d "${depPath}/.lake/config" ]; then
                chmod -R +w ".lake/packages/${depName}/.lake"
                rm -rf ".lake/packages/${depName}/.lake"/*
                cp -rP --no-preserve=mode "${depPath}/.lake"/* ".lake/packages/${depName}/.lake/"
              fi
            '') deps
          )}
          if [ ! -e .lake/package-overrides.json ]; then
            ln -s ${replaceManifestJson} .lake/package-overrides.json
          fi
          runHook postConfigure
        '';

        # Builds the default facets of the Lake package as well as the shared and static facets of the `name` library. Building the `shared` and `static` facets generates the library's `.export` files for use as a dependency, which allows its Nix path to be read-only
        # NOTE: We assume most projects have the same name for the package and default library, where the latter is capitalized (e.g. `aesop` and `Aesop`, `batteries` and `Batteries`). If this is not the case, the user can provide their own `buildPhase` either in a `depOverride` for `buildDeps` or directly as an argument to in `mkPackage`. If there are multiple libraries used from the package, the user can provide a `preBuild` or `postBuild` hook to build the requisite `shared`/`static` facets
        buildPhase = ''
          runHook preBuild
          lake build ${name}
          ${lib.optionalString buildLibrary ''
            lake build ${capitalize name}:shared
            lake build ${capitalize name}:static
          ''}
          runHook postBuild
        '';

        # Copies the whole workspace to the out path: the source, every
        # package's build output (local packages and custom `buildDir`s
        # included), the dependency shadows, and anything hooks placed there.
        # The source was already filtered on the way in, so nothing else needs
        # excluding.
        #
        # With `recordLeanPath`, Lake's own search path is recorded with the
        # build directory replaced by `$out`. Entries for packages Lake
        # configured but never built do not exist and are dropped, as is the
        # toolchain's, which `LEAN_SYSROOT` covers. Normalising must not
        # resolve symlinks, or an entry reached through a dependency shadow
        # could turn into a store path and be dropped with the toolchain.
        # TODO: Compress into zstd tarball instead of cp
        # https://github.com/ipetkov/crane/blob/master/lib/setupHooks/installCargoArtifactsHook.sh#L39
        installPhase = ''
          runHook preInstall
          mkdir -p $out/
          ${lib.optionalString installArtifacts ''
            cp -rPT . "$out"
            ${lib.optionalString recordLeanPath ''
              mkdir -p "$out/nix-support"
              leanPath=()
              declare -A seenLeanPath=()
              IFS=: read -ra rawLeanPath <<< "$(lake env printenv LEAN_PATH)"
              for entry in "''${rawLeanPath[@]}"; do
                [ -n "$entry" ] || continue
                entry=$(realpath -ms "$entry")
                [ -z "''${seenLeanPath[$entry]:-}" ] || continue
                seenLeanPath[$entry]=1
                [ -e "$entry" ] || continue
                case "$entry" in
                  ${builtins.storeDir}/*) ;;
                  "$PWD"/*) leanPath+=("$out/''${entry#"$PWD"/}") ;;
                  *)
                    echo "lake2nix: LEAN_PATH entry $entry is outside the workspace and cannot be installed" >&2
                    exit 1
                    ;;
                esac
              done
              (IFS=:; printf '%s\n' "''${leanPath[*]}") > "$out/nix-support/lean-path"
            ''}
          ''}
          runHook postInstall
        '';
      }
      # Prevents implicit arguments from being coerced to input strings in `mkDerivation`
      // (builtins.removeAttrs args [
        "deps"
        "depOverride"
        "depOverrideDeriv"
        "lakeDeps"
        "lakeArtifacts"
      ])
    );

  # Builds only the dependencies of a Lake package based on its `lake-manifest.json` file. Returns an attr set of package derivations
  buildDeps =
    {
      # Path to the source
      src,
      # Path to the `lake-manifest.json` file
      manifestFile ? "${src}/lake-manifest.json",
      # Override derivation args in dependencies
      depOverride ? { },
      # Override derivation entirely in dependencies
      depOverrideDeriv ? { },
      ...
    }:
    let
      gitPackages = manifestFile: builtins.filter isGitPackage (importLakeManifest manifestFile).packages;

      # Fetches the Git source of each dependency in the manifest, accounting for subDir
      depSources = builtins.listToAttrs (
        builtins.map (info: {
          inherit (info) name;
          value =
            let
              repo = builtins.fetchGit {
                inherit (info) url rev;
                shallow = true;
              };
              subDir = info.subDir or null;
            in
            if subDir != null then "${repo}/${subDir}" else repo;
        }) (gitPackages manifestFile)
      );

      # Constructs dependency name map
      flatDeps = lib.mapAttrs (
        _name: src: builtins.map ({ name, ... }: name) (gitPackages "${src}/lake-manifest.json")
      ) depSources;

      # Builds all Git dependencies, overriding with any custom arguments from `depOverride` or pre-built derivations from `depOverrideDeriv`
      manifestDeps = builtins.listToAttrs (
        builtins.map (info: {
          inherit (info) name;
          value =
            depOverrideDeriv.${info.name} or (mkLakeDerivation (
              {
                inherit (info) name url;
                src = depSources.${info.name};
                deps = builtins.listToAttrs (
                  builtins.map (name: {
                    inherit name;
                    value = manifestDeps.${name};
                  }) flatDeps.${info.name}
                );
                buildLibrary = true;
              }
              // (depOverride.${info.name} or { })
            ));
        }) (gitPackages manifestFile)
      );
    in
    manifestDeps;

  # Builds a given target of a Lake package with `lake build`, building any dependencies first and importing them via their Nix store paths
  #
  # Optional/implicit arguments:
  # - `lakeDeps` takes an attr set of dependency derivations built by `buildDeps`. If not specified, `mkPackage` will call `buildDeps` anyway.
  # - `lakeArtifacts` takes a derivation, or a list of them, from previous `mkPackage` invocations and restores their build output into the current build directory. Useful for incremental builds, e.g. reusing a package's library target artifacts when building an executable or test target. Files the current source already has are never overwritten, and with a list, the first derivation that has a file supplies it.
  # - `depOverride` and `depOverrideDeriv` can also be passed through as args to `buildDeps`, but are overriden by `lakeDeps` if specified
  # Any input phases and hooks will be passed through to `mkDerivation`
  mkPackage =
    args@{
      # Name of the build target, must be defined in `lakefile.lean`
      name,
      # Path to the source
      src,
      # Static library dependencies, passed as `nativeBuildInputs` to `mkDerivation`
      staticLibDeps ? [ ],
      ...
    }:
    let
      deps = args.lakeDeps or (buildDeps (builtins.removeAttrs args [ "name" ]));
      # Restores the build output of earlier outputs: every `.lake` directory
      # in them, at any depth, so local packages and custom `buildDir`s under a
      # `.lake` are included. Files hooks placed elsewhere are left for this
      # derivation's own hooks to place again, and nothing the current source
      # already has is overwritten. Restored files are made writable, since
      # Lake may rebuild them, and get fresh modification times, as a plain
      # copy gives them. The package overrides belong to `configurePhase`.
      restoreArtifacts = lib.optionalString (args ? lakeArtifacts) ''
        for drv in ${lib.escapeShellArgs (map toString (lib.toList args.lakeArtifacts))}; do
          rsync -rlp --chmod=u+w --ignore-existing --prune-empty-dirs \
            --exclude=/.lake/package-overrides.json \
            --include='*/' --include='.lake/***' --exclude='*' \
            "$drv/" ./
        done
      '';
    in
    mkLakeDerivation (
      {
        recordLeanPath = true;
      }
      // args
      // {
        inherit name src deps;
        nativeBuildInputs = staticLibDeps;

        # TODO: Use zstd tarball instead of rsync
        # https://github.com/ipetkov/crane/blob/master/lib/setupHooks/inheritCargoArtifactsHook.sh#L28
        # Runs before, not instead of, the caller's own `prePatch`
        prePatch = restoreArtifacts + (args.prePatch or "");

        # Copies any executable to the out path, as well as the source and `.lake` artifacts if specified
        postInstall =
          args.postInstall or ''
            if [ -d .lake/build/bin ]; then
              cp -R .lake/build/bin $out
            fi
          '';
      }
    );

  # Wraps each executable of a `mkPackage` derivation so that modules it
  # imports at run time (`importModules`, `get_env!`) resolve: `LEAN_PATH` is
  # the search path Lake used for the build, pointing into the derivation's
  # installed workspace, and `LEAN_SYSROOT` supplies the toolchain's own
  # libraries. Reads `nix-support/lean-path` at build time, so evaluation
  # needs no import from derivation.
  wrapExecutables =
    drv:
    pkgs.runCommand drv.name
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta = drv.meta or { };
        passthru.unwrapped = drv;
      }
      ''
        leanPath=${drv}/nix-support/lean-path
        if [ ! -f "$leanPath" ]; then
          echo "wrapExecutables: $leanPath is missing; build ${drv.name} with installArtifacts = true" >&2
          exit 1
        fi
        mkdir -p $out/bin
        for exe in ${drv}/bin/*; do
          [ -f "$exe" ] && [ -x "$exe" ] || continue
          makeWrapper "$exe" "$out/bin/$(basename "$exe")" \
            --set LEAN_SYSROOT ${lean} \
            --set LEAN_PATH "$(cat "$leanPath")"
        done
      '';

  # Predicate form, for callers who need to union extra files into the source:
  #
  #   lib.cleanSourceWith {
  #     src = ./.;
  #     filter = path: type: filterLakeSources path type || myOwnFilter path type;
  #   }
  filterLakeSources =
    orig_path: type:
    let
      base = baseNameOf (toString orig_path);
      matchesSuffix = lib.any (suffix: lib.hasSuffix suffix base) [
        # Lean sources, including `lakefile.lean`
        ".lean"
        # `lakefile.toml`, and config for other Lake-adjacent tools
        ".toml"
        # `extern_lib` targets and FFI shims are compiled during `lake build`
        ".c"
        ".cpp"
        ".h"
        ".hpp"
      ];
      isLakeFile = lib.elem base [
        "lake-manifest.json"
        "lean-toolchain"
      ];
      # A developer's local build directory must never reach the store: the
      # build creates its own `.lake`, and stale artifacts would collide with
      # the dependency shadow directories set up in `configurePhase`.
      isBuildDir = base == ".lake";
    in
    !isBuildDir && (type == "directory" || matchesSuffix || isLakeFile);

  # Restrict a source tree to the files `lake build` actually reads, so that
  # editing unrelated files (flake.nix, CI config, docs) does not invalidate the
  # build. The analogue of crane's `cleanCargoSource`.
  cleanLakeSource =
    src:
    lib.cleanSourceWith {
      src = lib.cleanSource src;
      filter = filterLakeSources;
      # A fixed name keeps the store path stable regardless of what the
      # checkout directory happens to be called.
      name = "lake-source";
    };
in
{
  inherit
    mkLakeDerivation
    buildDeps
    mkPackage
    wrapExecutables
    cleanLakeSource
    filterLakeSources
    ;
}
