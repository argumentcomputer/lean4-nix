# Workspace snapshots in `lake2nix`

Status: proposal.

## Summary

`lake2nix` models a Lake project as one root package plus Git dependencies,
and installs, restores and runs only what is in the root `.lake`. Three
common patterns fall outside that model:

- **Local packages** (`require foo from "Foo"`), whose build output lives
  in their own `.lake` directories.
- **Reusing more than one earlier build**, such as a test executable that
  links two libraries built in separate derivations.
- **Executables that import modules at run time** (`importModules`,
  `get_env!`), which need a `LEAN_PATH` covering every package they reach.

This proposal handles all three with one rule: **a `lake2nix` output is a
snapshot of the workspace as it was built.** Restoring copies the snapshot
back, and the runtime search path is the one Lake computed, moved into the
snapshot. Nothing in Nix names a package's directories, and everything
else stays in the consumer's existing hooks.

## Background

A `mkPackage` build today:

- **`buildDeps`** builds one derivation per manifest package with
  `builtins.fetchGit { url; rev; }`.
- **`configurePhase`** shadows each dependency under `.lake/packages/<name>`
  and links a generated `package-overrides.json` pointing every manifest
  package at its shadow.
- **`installPhase`**, with `installArtifacts`, runs
  `rsync -a --exclude=".lake" --filter=":- .gitignore" ./ $out/`, then
  copies the root `.lake`.
- **`lakeArtifacts`** copies one earlier derivation's root `.lake` into
  place. It is `mkPackage`'s *default* `prePatch`, so any caller
  `prePatch` turns it off.
- **`postInstall`** copies `.lake/build/bin` to `$out/bin`. The runtime
  search path is left to the consumer.

## Problem

1. **`buildDeps` fetches local packages.** A `path` entry has no `url` or
   `rev`, so a consumer must filter it out of the result.
2. **The generated overrides relocate local packages** to
   `.lake/packages/<name>`, where they are not shadowed. A consumer must
   write its own overrides file.
3. **Installs drop everything outside the root `.lake` that the build
   produced.** The unanchored `--exclude=".lake"` drops local packages'
   build output, and the `.gitignore` filter drops files a hook placed in
   the workspace, such as a prebuilt static library under `target/`.
   Blake3.lean copies `rust/target` back in by hand in `postInstall`.
4. **Restores cover one derivation's root `.lake`.** Local packages
   rebuild in every downstream derivation. Merging two earlier builds, as
   Blake3.lean's test does, means writing a `prePatch`, which turns the
   restore off.
5. **Nothing records the runtime search path.** A package missing from a
   hand-built `LEAN_PATH` fails at run time with `unknown module prefix`.

## Goals

- Local packages build, install, restore and resolve at run time with no
  per-package Nix.
- One rule for what an output contains, instead of a list of directories
  and exceptions.
- Fewer rebuilds: each derivation reuses everything earlier ones built.
- Projects without local packages behave as today.

## Non-goals

- Making lakefile build steps that can't run in the sandbox work (Cargo,
  Git clones). A consumer patches those in its own hooks, as today. This
  proposal only guarantees that whatever a hook puts in the workspace is
  kept in the output.
- Building local packages as separate derivations.
- Changing how Git dependencies are built.
- Compressing installed artifacts (the existing zstd TODO).

## Design

### 1. Local packages stay in the workspace

- **`buildDeps`** builds only entries with `type == "git"`, both in the
  top-level manifest and in each Git dependency's own dependency list
  (`flatDeps`).
- **The generated overrides** shadow only Git entries and pass `path`
  entries through unchanged, so Lake resolves them relative to the
  workspace root, as in a checkout.

### 2. The output is the workspace

**Install** copies the whole build directory, symlinks as symlinks:

```sh
cp -rP . "$out/"
```

That replaces the `rsync` filter and the separate `.lake` copy. The source
is already filtered on the way in (`cleanLakeSource`), so the build
directory holds the source, every package's build output wherever its
`buildDir` points inside the workspace, the dependency shadows, and
anything a hook placed. Shadows are mostly symlinks into dependency store
paths and cost little.

**Restore** takes one derivation or a list for `lakeArtifacts`. It brings
back build output only, meaning every `.lake` directory at any depth, and
fills in what the current workspace does not already have:

```sh
for drv in $lakeArtifacts; do
  rsync -rlp --chmod=u+w --ignore-existing --prune-empty-dirs \
    --exclude=/.lake/package-overrides.json \
    --include='*/' --include='.lake/***' --exclude='*' \
    "$drv/" ./
done
```

Files are made writable as they are copied, since store permissions would
otherwise stop Lake rebuilding them and stop rsync creating entries in
restored directories. Leaving out `-t` gives restored files fresh
modification times, as today's `cp -R` does. The package overrides are
left to `configurePhase`.

- **Only build output is restored.** Install keeps the whole workspace, so
  that files hooks placed travel with a package used as a dependency. A
  restore leaves those files out, because the derivation's own hooks place
  them again. Restoring them would break any hook that creates them, such
  as ix's `ln -s … target/release/`, which fails on an existing file. A
  `buildDir` outside every `.lake` is not restored, so it rebuilds, which
  costs time but is still correct.
- **Source files come from the current `src`.** `--ignore-existing` never
  overwrites them, so a restore from an older build cannot replace edited
  source.
- **Build output is merged.** Lake decides from its stored traces what is
  up to date, as it does for the restored root `.lake` today. With a list,
  the first derivation that has a file supplies it.
- **The restore always runs.** It is prepended to the caller's hook
  (`prePatch = restore + (args.prePatch or "")`), not used as a default
  for it. It runs before `configurePhase`, which creates the dependency
  shadows. Shadowing removes a restored `.lake/packages/<name>` before
  `cp -rs`, which would otherwise nest a copy inside it.

### 3. Record and apply the runtime search path

After the build, Lake reports its search path:

```sh
lake env printenv LEAN_PATH
```

`mkPackage`'s `installPhase` writes it to `$out/nix-support/lean-path`;
`buildDeps` derivations skip this step. Entries are
absolute and may contain `..`, so each is normalised lexically
(`realpath -ms`), and only its first occurrence is kept, which preserves
precedence. Normalisation does not resolve symlinks. Today's shadows are
real directories holding symlinked files, so resolving would change
nothing. But a shadow that symlinked a whole directory would otherwise
turn into a store path and be dropped as the toolchain. Each entry then
becomes:

| entry | becomes |
|---|---|
| missing after the build (a package configured but never built) | dropped |
| in the Nix store (the toolchain) | dropped; `LEAN_SYSROOT` covers it |
| inside the build directory | the same path under `$out` |
| anywhere else (a `buildDir` outside the workspace) | an error naming it |

Because `$out` is the workspace, every rewritten entry exists. A Git
dependency's entry goes through its shadow in `$out/.lake/packages`, so it
points at the files this build used. That includes a `lakefile.lean`
dependency's writable copy, where Lake may have built more than the
dependency's own derivation did.

A helper applies the file:

```nix
lake2nix.wrapExecutables drv
```

It wraps each `drv/bin/*` with `makeWrapper`, setting `LEAN_SYSROOT` to the
toolchain and `LEAN_PATH` from `drv/nix-support/lean-path`. It reads the
file at build time, so evaluation needs no import from derivation.

## Extending: ix

ix is the most complex consumer: four local packages, a custom `buildDir`,
Crane-built Rust, and Mathlib-only dependencies it never builds. This
design does not try to cover it fully. It removes ix's general workarounds
and leaves the specific ones in its own hooks:

| ix workaround | after |
|---|---|
| `removeAttrs` over `buildDeps`, its own `package-overrides.json` | removed (part 1) |
| local packages lost at install, rebuilt downstream | fixed (part 2) |
| `wrapBin`, `leanPath`, the `.lake/kernel` special case | `lake2nix.wrapExecutables` (part 3) |
| `cargo` patched to `true`, Crane archive linked into `target/release` | unchanged, in `postPatch` / `postConfigure` |
| `depOverride` stubs for the Mathlib-only packages | unchanged |
| the `ix-tests` check copying `.lake` from its test derivation | unchanged |

`ix-kernel`'s `buildDir := "../.lake/kernel"` needs nothing special: it is
inside the workspace, so it is in the snapshot and its search-path entry
is rewritten like any other.

## Effect on the other consumers

- **Blake3.lean:** the merging `prePatch` becomes
  `lakeArtifacts = [ blake3C blake3Rust ]`. The `rust/target`
  `postInstall` goes away, since the archive `postConfigure` links is now
  part of the output. Its Cargo and Git patches stay.
- **lean-ffi:** no change. Its patches stay.
- **LSpec:** no change.

## Compatibility

- **Projects without local packages:** the output is the same as today's,
  plus anything hooks placed in the workspace and one file under
  `nix-support`.
- **`installArtifacts = false`:** root executables are still copied to
  `$out/bin`. The workspace and `lean-path` are not installed, and
  `wrapExecutables` on such a derivation fails, naming the missing file.
- **Executables:** as today, only the root's `.lake/build/bin` is copied
  to `$out/bin`. Local packages' executables are in the snapshot but not
  exported or wrapped.
- **A consumer's own overrides:** an existing `.lake/package-overrides.json`
  still wins through the `[ ! -e ]` check.
- **A consumer's own `prePatch`:** it now runs after the restore, instead
  of replacing it. A `prePatch` that merges `.lake` by hand still works;
  it is just redundant.
- **An unfiltered `src`:** anything in it, such as a stray `result`
  symlink, is now installed too. `cleanLakeSource` already excludes these.

## Testing

A new `local` template:

- a root package requiring a local package by path, and a second local
  package that is required but never built;
- an executable importing the local package's module at run time through
  `importModules`.

Checks:

- **Build:** the template builds with no overrides.
- **Run time:** its `wrapExecutables` output resolves the local module.
- **Restore:** a second `mkPackage` with `lakeArtifacts` passes
  `lake build --no-build` for the local library, which fails if anything
  would rebuild.
- **Merge:** `lakeArtifacts = [ a b ]` from two targets passes
  `--no-build` for both.

`incremental-dep` is unrelated and stays as it is: it adds a `require`
that its manifest doesn't list, which is why it has its own overrides.

## Open questions

- **Does `lake env` load the configuration without network access in the
  build sandbox?** On the pinned Lean (4.34.1), the `minimal` template
  (TOML, no dependencies) ran it in the Nix build sandbox in 0.035 s. Lake
  reported
  `/build/lake-source/.lake/build/lib/lean:<lean>/lib/lean`, and
  `lean-path` became `$out/.lake/build/lib/lean`. The `dependency` template
  (a `lakefile.lean` root with aesop and batteries as Git dependencies)
  ran it in 0.22 s. Lake listed batteries, aesop, the root and the
  toolchain, in that order, and all three workspace entries were rewritten
  under `$out`. Shadow directories are real directories of symlinked
  files, so each rewritten dependency entry resolves into that
  dependency's store path. Still to confirm: a `lakefile.lean`
  dependency's writable `.lake` copy (both dependencies here use TOML),
  local packages, and consumers whose configurations do more, such as
  reading environment variables.
- **Output size.** Each output holds a copy of everything restored into
  it, as the root `.lake` does today, now including local packages. Hard
  links to unchanged files could deduplicate later.
