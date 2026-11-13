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
  # the workspace tree.
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
      # incremental builds and use as a dependency. A package installed with
      # `installBin` is a leaf nothing builds on, so it exports nothing unless
      # asked, as crane's `buildPackage` keeps no cargo artifacts; everything
      # else exports, since libraries are consumed as dependencies through
      # `mkPackage` without any other marker.
      installArtifacts ? !installBin,
      # How exported artifacts are stored: "tree" keeps the workspace layout
      # in the output, "zstd" packs it into one `lake-artifacts.tar.zst` that
      # consumers unpack. Oleans and objects compress several times over, and
      # the archive is a single file for Nix to hash, scan for references,
      # and fix up.
      artifactsFormat ? "tree",
      # Whether to record the runtime search path in `nix-support/lean-path`
      # for `wrapExecutables`. Only takes effect with a "tree" export, since
      # the paths it records must exist in the output.
      recordLeanPath ? false,
      # Whether to install the package's executables for standalone use. Each
      # binary under `bin/` is wrapped with `LEAN_SYSROOT` set and `lib/lean`
      # prepended to `LEAN_PATH`; that directory holds the module files of
      # every module on Lake's search path for the workspace: the package's
      # own, its local packages', those inherited through `lakeArtifacts`,
      # and its dependencies'. The output is self-contained, so the runtime
      # closure carries none of the build trees.
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
      writesLeanPath = recordLeanPath && installArtifacts && artifactsFormat == "tree";
      usesZstd =
        artifactsFormat == "zstd"
        || lib.any (drv: artifactsFormatOf drv == "zstd") (
          lib.toList (args.lakeArtifacts or [ ]) ++ builtins.attrValues deps
        );
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
        # Archived dependencies unpack to real writable copies either way. A
        # shadow restored from `lakeArtifacts` is replaced, since `cp -rs`
        # into an existing directory would nest a second copy inside it.
        configurePhase = ''
          runHook preConfigure
          mkdir -p .lake/packages
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              depName: depPath:
              ''
                rm -rf ".lake/packages/${depName}"
              ''
              + unpackArtifacts depPath ".lake/packages/${depName}"
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

        # Exports the whole workspace: the source, every package's build
        # output (local packages and custom `buildDir`s included), and
        # anything hooks placed there. The source was already filtered on the
        # way in, so nothing else needs excluding. A "tree" export also keeps
        # the dependency shadows; an archive leaves them out, since consumers
        # recreate them from their own dependencies and the store paths they
        # point at would be hidden from Nix's reference scan inside it.
        #
        # Lake's own search path drives both `recordLeanPath` and `installBin`:
        # its entries inside the workspace, in Lake's order. Entries for
        # packages Lake configured but never built do not exist and are
        # dropped, as is the toolchain's, which `LEAN_SYSROOT` covers.
        # Normalising must not resolve symlinks, or an entry reached through a
        # dependency shadow could turn into a store path and be dropped with
        # the toolchain.
        installPhase = ''
          runHook preInstall
          mkdir -p $out/
          ${lib.optionalString installArtifacts (
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
                    --exclude=./.lake/packages \
                    -c . \
                    | zstd "-T''${NIX_BUILD_CORES:-0}" -o "$out/${artifactsArchive}"
                )
              ''
            else
              ''
                cp -rPT . "$out"
              ''
          )}
          ${lib.optionalString (writesLeanPath || installBin) ''
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
                "$PWD"/*) leanPath+=("''${entry#"$PWD"/}") ;;
                *)
                  echo "lake2nix: LEAN_PATH entry $entry is outside the workspace and cannot be installed" >&2
                  exit 1
                  ;;
              esac
            done
          ''}
          ${lib.optionalString writesLeanPath ''
            mkdir -p "$out/nix-support"
            (IFS=:; printf '%s\n' "''${leanPath[*]/#/$out/}") > "$out/nix-support/lean-path"
          ''}
          ${lib.optionalString installBin ''
            # Earlier search path entries take precedence, as in Lean's lookup.
            mkdir -p $out/lib/lean $out/bin
            for entry in "''${leanPath[@]}"; do
              rsync -aL --ignore-existing --prune-empty-dirs --include='*/' ${binIncludes} --exclude='*' \
                "$entry"/ $out/lib/lean/
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
        nativeBuildInputs =
          (args.nativeBuildInputs or [ ])
          ++ lib.optional usesZstd pkgs.zstd
          ++ lib.optional installBin pkgs.makeWrapper;

        # The dependency shadows make the output tens of thousands of
        # symlinks, all pointing at other store paths. stdenv's post-fixup
        # hooks that rewrite symlinks into the output as relative ones and
        # reject dangling ones walk every symlink in a shell loop, which
        # dominates fixup: about a minute for ix's library output, against
        # about a second with both off. Neither applies here: no symlink
        # points into the output itself, and every target is a dependency in
        # the closure.
        dontRewriteSymlinks = true;
        dontCheckForBrokenSymlinks = true;
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
      # An archive is unpacked aside first so both formats merge by the same
      # rule.
      restoreTree = dir: ''
        rsync -rlp --chmod=u+w --ignore-existing --prune-empty-dirs \
          --exclude=/.lake/package-overrides.json \
          --include='*/' --include='.lake/***' --exclude='*' \
          "${dir}/" ./
      '';
      restoreArtifacts = lib.concatMapStrings (
        drv:
        if artifactsFormatOf drv == "zstd" then
          ''
            restoreDir=$(mktemp -d)
            ${extractArchive drv ''-C "$restoreDir"''}
            ${restoreTree "$restoreDir"}
            rm -rf "$restoreDir"
          ''
        else
          restoreTree drv
      ) (lib.toList (args.lakeArtifacts or [ ]));
    in
    mkLakeDerivation (
      {
        recordLeanPath = true;
      }
      // args
      // {
        inherit name src deps;
        nativeBuildInputs = staticLibDeps ++ (args.nativeBuildInputs or [ ]);

        # Runs before, not instead of, the caller's own `prePatch`
        prePatch = restoreArtifacts + (args.prePatch or "");

        # Copies any executable to the out path. `installBin` installs and
        # wraps them itself.
        postInstall =
          args.postInstall or (lib.optionalString (!(args.installBin or false)) ''
            if [ -d .lake/build/bin ]; then
              cp -R .lake/build/bin $out
            fi
          '');
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
          echo "wrapExecutables: $leanPath is missing; build ${drv.name} with installArtifacts = true and artifactsFormat = \"tree\", or use installBin" >&2
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
