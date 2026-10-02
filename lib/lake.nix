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
  # Name of the archive an `artifactsFormat = "zstd"` output holds in place of
  # the source and `.lake` tree.
  artifactsArchive = "lake-artifacts.tar.zst";
  # How a derivation built here stores its artifacts. Derivations from
  # elsewhere (e.g. `depOverrideDeriv`) are plain trees.
  artifactsFormatOf = drv: drv.lakeArtifactsFormat or "tree";
  # Shell snippet streaming the archive of `drv` into `tar -x` with the given
  # extraction arguments. The archive stores every entry with `u+w`, so the
  # copy comes out writable without a `chmod` pass.
  extractArchive = drv: tarArgs: ''
    zstd -d "${drv}/${artifactsArchive}" --stdout | tar -x ${tarArgs}
  '';
  # Shell snippet placing the artifacts of `drv` at `dest`, whichever format
  # they are stored in. A tree is shadowed: directories are created and files
  # symlinked into the store. An archive unpacks to a real writable copy.
  unpackArtifacts =
    drv: dest:
    if artifactsFormatOf drv == "zstd" then
      ''
        mkdir -p "${dest}"
        ${extractArchive drv ''-C "${dest}"''}
      ''
    else
      ''
        cp -rs "${drv}" "${dest}"
      '';
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
      # Whether to export `.lake` artifacts and source for incremental builds
      # and for packages that depend on this one. A package installed with
      # `installBin` is a leaf nothing builds on, so it exports nothing unless
      # asked, as crane's `buildPackage` keeps no cargo artifacts; everything
      # else exports, since libraries are consumed as dependencies through
      # `mkPackage` without any other marker.
      installArtifacts ? !installBin,
      # How exported artifacts are stored: "tree" keeps the directory layout
      # in the output, "zstd" packs the source and `.lake` into one
      # `lake-artifacts.tar.zst` that consumers unpack. Oleans and objects
      # compress several times over, and the archive is a single file for
      # Nix to hash, scan for references, and fix up.
      artifactsFormat ? "tree",
      # Whether to install the package's executables for standalone use. Each
      # binary under `bin/` is wrapped with `LEAN_SYSROOT` set and `lib/lean`
      # prepended to `LEAN_PATH`; that directory holds the module files of
      # every module the binary can import at runtime: its own, those
      # inherited through `lakeArtifacts`, and its dependencies'. The output
      # is self-contained, so the runtime closure carries none of the build
      # trees.
      installBin ? false,
      # Module files `installBin` keeps, as `find`-style name patterns.
      # Lean reads all three olean parts unconditionally when importing a
      # module compiled with `module`, so they belong together. The IR files
      # serve the interpreter for declarations that have no native code in
      # the binary: a classic module carries its IR inside the olean, but a
      # `module` keeps it in `.ir.sig` and `.ir`, so without them evaluating
      # such a declaration fails. A package whose binaries link every module
      # they import can drop them.
      binFiles ? [
        "*.olean"
        "*.olean.private"
        "*.olean.server"
        "*.ir.sig"
        "*.ir"
      ],
      ...
    }:
    assert lib.assertOneOf "artifactsFormat" artifactsFormat [
      "tree"
      "zstd"
    ];
    let
      manifest = importLakeManifest "${src}/lake-manifest.json";
      # Creates a surrogate manifest with paths to local shadow directories.
      # These shadow directories symlink source files from the Nix store.
      replaceManifest = (
        lib.setAttr manifest "packages" (
          builtins.map (
            {
              name,
              inherited ? false,
              ...
            }:
            {
              inherit name inherited;
              type = "path";
              dir = ".lake/packages/${name}";
            }
          ) manifest.packages
        )
      );
      replaceManifestJson = pkgs.writers.writeJSON "lake-manifest.json" replaceManifest;
      lakeArtifacts = args.lakeArtifacts or null;
      usesZstd =
        artifactsFormat == "zstd"
        || (lakeArtifacts != null && artifactsFormatOf lakeArtifacts == "zstd")
        || lib.any (dep: artifactsFormatOf dep == "zstd") (builtins.attrValues deps);
      binIncludes = lib.concatMapStringsSep " " (p: "--include='${p}'") binFiles;
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
        # Archived dependencies unpack to real writable copies either way.
        configurePhase = ''
          runHook preConfigure
          mkdir -p .lake/packages
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              depName: depPath:
              unpackArtifacts depPath ".lake/packages/${depName}"
              + lib.optionalString (artifactsFormatOf depPath != "zstd") ''
                if [ -d "${depPath}/.lake/config" ]; then
                  chmod -R +w ".lake/packages/${depName}/.lake"
                  rm -rf ".lake/packages/${depName}/.lake"/*
                  cp -rP --no-preserve=mode "${depPath}/.lake"/* ".lake/packages/${depName}/.lake/"
                fi
              ''
            ) deps
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

        # Exports the source and `.lake` artifacts for later reuse as a
        # dependency or through `lakeArtifacts`, respecting `.gitignore`, and
        # installs wrapped executables with their runtime module files. The
        # two optional blocks sit on one line so that, with neither of the
        # new modes selected, the phase is byte-identical to its previous
        # form and existing derivations keep their hashes.
        installPhase = ''
          runHook preInstall
          mkdir -p $out/
          ${
            lib.optionalString installArtifacts (
              if artifactsFormat == "zstd" then
                # Reproducible archive, as crane writes its cargo artifacts:
                # fixed ordering, timestamps and ownership, no atime/ctime pax
                # headers, and `u+w` so consumers can unpack straight into a
                # writable build directory. Lake tracks inputs by content hash,
                # so the flattened timestamps do not trigger rebuilds.
                ''
                  (
                    export SOURCE_DATE_EPOCH=1
                    tar \
                      --sort=name \
                      --mtime="@$SOURCE_DATE_EPOCH" \
                      --owner=0 \
                      --group=0 \
                      --mode=u+w \
                      --numeric-owner \
                      --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
                      --exclude-vcs-ignores \
                      -c . \
                      | zstd "-T''${NIX_BUILD_CORES:-0}" -o "$out/${artifactsArchive}"
                  )
                ''
              else
                ''
                  rsync -a --exclude=".lake" --filter=":- .gitignore" ./ "$out/"
                  cp -rP .lake $out
                ''
            )
          }${lib.optionalString installBin ''
            mkdir -p $out/lib/lean $out/bin
            for dir in .lake/build/lib/lean .lake/packages/*/.lake/build/lib/lean; do
              [ -d "$dir" ] || continue
              rsync -aL --prune-empty-dirs --include='*/' ${binIncludes} --exclude='*' \
                "$dir"/ $out/lib/lean/
            done
            if [ -d .lake/build/bin ]; then
              find .lake/build/bin -maxdepth 1 -type f -executable \
                -exec install -Dm755 -t $out/bin {} +
            fi
            # `lib/lean` is prepended rather than set: under `lake env` the
            # project's own search path must stay visible behind it.
            for exe in $out/bin/*; do
              wrapProgram "$exe" \
                --set LEAN_SYSROOT "${lean}" \
                --prefix LEAN_PATH : "$out/lib/lean"
            done
          ''}
          runHook postInstall
        '';

        passthru = (args.passthru or { }) // {
          lakeArtifactsFormat = artifactsFormat;
        };
      }
      # The extra tools only enter a derivation whose mode needs them, so the
      # inputs of every existing package are unchanged.
      // lib.optionalAttrs (args ? nativeBuildInputs || usesZstd || installBin) {
        nativeBuildInputs =
          (args.nativeBuildInputs or [ ])
          ++ lib.optional usesZstd pkgs.zstd
          ++ lib.optional installBin pkgs.makeWrapper;
      }
      # Prevents implicit arguments from being coerced to input strings in `mkDerivation`
      // (builtins.removeAttrs args [
        "deps"
        "depOverride"
        "depOverrideDeriv"
        "lakeDeps"
        "lakeArtifacts"
        "artifactsFormat"
        "installBin"
        "binFiles"
        "nativeBuildInputs"
        "passthru"
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
      manifest = importLakeManifest manifestFile;

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
        }) manifest.packages
      );

      # Constructs dependency name map
      flatDeps = lib.mapAttrs (
        _name: src:
        let
          manifest = importLakeManifest "${src}/lake-manifest.json";
          deps = builtins.map ({ name, ... }: name) manifest.packages;
        in
        deps
      ) depSources;

      # Builds all dependencies, overriding with any custom arguments from `depOverride` or pre-built derivations from `depOverrideDeriv`
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
        }) manifest.packages
      );
    in
    manifestDeps;

  # Builds a given target of a Lake package with `lake build`, building any dependencies first and importing them via their Nix store paths
  #
  # Optional/implicit arguments:
  # - `lakeDeps` takes an attr set of dependency derivations built by `buildDeps`. If not specified, `mkPackage` will call `buildDeps` anyway.
  # - `lakeArtifacts` takes a derivation from a previous `mkPackage` invocation and copies the `.lake` directory to the current build directory. Useful for incremental builds, e.g. reusing a package's library target artifacts when building an executable or test target.
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
    in
    mkLakeDerivation (
      args
      // {
        inherit name src deps;
        nativeBuildInputs = staticLibDeps ++ (args.nativeBuildInputs or [ ]);

        # Brings any given Lake artifacts into the build directory, so Lake
        # replays what they already contain.
        prePatch =
          args.prePatch or (
            if args ? lakeArtifacts then
              if artifactsFormatOf args.lakeArtifacts == "zstd" then
                extractArchive args.lakeArtifacts "./.lake"
              else
                ''
                  cp -R ${args.lakeArtifacts.outPath}/.lake .
                  chmod -R +w .lake
                ''
            else
              ""
          );

        # Copies any executable to the out path. `installBin` installs
        # and wraps them itself.
        postInstall =
          args.postInstall or (lib.optionalString (!(args.installBin or false)) ''
            if [ -d .lake/build/bin ]; then
              cp -R .lake/build/bin $out
            fi
          '');
      }
    );
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
    cleanLakeSource
    filterLakeSources
    ;
}
