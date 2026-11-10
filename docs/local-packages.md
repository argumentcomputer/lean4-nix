# Local packages in `lake2nix`

Status: proposal.

## Summary

`lake2nix` models a Lake project as one root package plus Git dependencies.
Local packages (`require foo from "Foo"`, `type: "path"` in
`lake-manifest.json`) fall outside that model. Each consumer then has to
work around them in its own flake: filtering them out of `buildDeps`,
writing its own `package-overrides.json`, carrying their build output
between derivations by hand and assembling a runtime `LEAN_PATH` that lists
them.

This proposal makes local packages first-class, with Lake as the single
source of truth:

1. `buildDeps` and the generated package overrides leave local packages to
   the workspace.
2. `mkLakeDerivation` installs every workspace package's build directory,
   and `lakeArtifacts` restores all of them.
3. Each build records the runtime search path Lake computed for it, and a
   wrapper helper applies that path to the derivation's executables.

No consumer then needs to name its local packages, their directories or
their build directories in Nix.

## Background

A `mkPackage` build today goes through these steps:

- **`buildDeps`** reads `lake-manifest.json` and builds one derivation per
  package with `builtins.fetchGit { url; rev; }`.
- **`configurePhase`** shadows each dependency under `.lake/packages/<name>`
  and links a generated `package-overrides.json` (`replaceManifest`) that
  points every manifest package at its shadow directory.
- **`installPhase`**, with `installArtifacts`, copies the source with
  `rsync -a --exclude=".lake" --filter=":- .gitignore"`, then the root
  `.lake`.
- **`lakeArtifacts`** (in `prePatch`) copies a previous derivation's root
  `.lake` into place, so a test or executable target reuses a library
  target's build.
- **The runtime search path** is left to the consumer. An executable that
  imports modules at run time (`importModules`, `get_env!`) needs a
  `LEAN_PATH` naming every package's `lib/lean`, which each flake assembles
  itself.

## Problem

In a workspace with local packages, every step above goes wrong.

1. **`buildDeps` fetches local packages.** It maps `fetchGit` over every
   manifest entry, and a local package has no `url` or `rev`. A consumer
   must remove local packages from the result and rely on Nix's laziness
   never to evaluate them.
2. **The generated overrides relocate local packages.** `replaceManifest`
   rewrites every entry to `dir = ".lake/packages/<name>"`, including local
   ones, which are not shadowed there. A consumer must write its own
   overrides file that keeps local entries as they are, and link it in
   `preConfigure`, before `configurePhase`'s `[ ! -e ]` check.
3. **Installs drop local packages' build output.** Lake builds a local
   package into `<dir>/.lake/build`. That directory is dropped twice: by
   `rsync`'s unanchored `--exclude=".lake"`, and by the `.gitignore` filter,
   since projects commonly ignore `**/.lake`. Only the root `.lake` is then
   copied.
4. **`lakeArtifacts` reuse covers only the root package.** Every derivation
   downstream of a library recompiles each local package, even when the
   library derivation already built it.
5. **Nothing exports the runtime search path.** A consumer's `LEAN_PATH`
   lists the packages it knows about. A local package missing from it fails
   at run time, not at build time, with `unknown module prefix`.

The checks in this repository hit gaps 2 and 4 already. `incremental-dep`
requires `dependency` by path, through a hand-written
`package-overrides.json`.

### Case study: ix

[ix](https://github.com/argumentcomputer/ix) has four local packages:
`aiur` (`Aiur/`), `ixvm` (`IxVM/`), `multiStark` (`MultiStark/`) and
`ix-kernel` (`IxC/`). Its flake works around every gap:

- **Gap 1:** it calls
  `builtins.removeAttrs (buildDeps …) <names of type "path">`.
- **Gap 2:** it writes `lake-package-overrides.json`, keeping `path`
  entries, and links it in `preConfigure`.
- **Gap 5:** its `wrapBin` sets `LEAN_PATH` to the root package's
  `.lake/build/lib/lean`, `.lake/kernel/lib/lean` and each Git dependency's
  `lib/lean`.
- **Gaps 3 and 4:** `ix-kernel` is reachable only because its lakefile sets
  `buildDir := "../.lake/kernel"`, which moves its output under the root
  `.lake`. The other three local packages build into their own directories,
  so their build output is lost at every install, rebuilt in each
  downstream derivation, and missing from `LEAN_PATH`.

This surfaced when a test suite started importing `IxVM` modules at run
time. The Nix check failed with `unknown module prefix 'Aiur'`, while the
same suite passed in the dev shell, where `lake env` supplies the full
path. The workaround within the flake alone is to list the three packages'
directories in every install, restore and search path, which breaks
whenever a package is added or its `buildDir` changes.

## Goals

- Local packages build, install, restore and resolve at run time with no
  per-package Nix in the consumer.
- The set of build directories and the search path come from Lake's view
  of the workspace, custom `buildDir`s included, not from conventions
  repeated in Nix.
- Single-package projects and Git-only workspaces behave exactly as today.

## Non-goals

- Building local packages as separate derivations. They stay part of the
  workspace build, as Lake builds them.
- Reproducing Lake's dependency resolution in Nix.
- Compressing installed artifacts (the existing zstd TODO), which is
  orthogonal.

## Design

### 1. Local packages stay in the workspace

- **`buildDeps`** builds only entries with `type == "git"`. A local package
  is built by the workspace that contains it, so it gets no derivation of
  its own.
- **`replaceManifest`** shadows only Git entries and passes `path` entries
  through unchanged, so Lake resolves them relative to the workspace root as
  in a checkout. That makes ix's and `incremental-dep`'s hand-written
  overrides unnecessary.

### 2. Install and restore every workspace build directory

At the end of `buildPhase`, `mkLakeDerivation` asks Lake for the
workspace's library directories:

```sh
lake env printenv LEAN_PATH > .lake/nix-lean-path
```

`lake env` sets `LEAN_PATH` from each package's resolved `leanLibDir`
(`<buildDir>/lib/lean`), so custom build directories such as
`../.lake/kernel` come out right with no special case.

The entries fall into three groups:

| entry | handling |
|---|---|
| under the build directory, outside `.lake/packages` | the workspace's own packages: install them |
| under `.lake/packages/<name>` | Git dependencies: already in their own derivations; install nothing |
| under the toolchain | Lean's own libraries; install nothing |

For each workspace entry, `installPhase` copies the enclosing build
directory (the entry minus `/lib/lean`), keeping its path relative to the
workspace root. It records the relative paths in
`$out/nix-support/lake-build-dirs`. The root `.lake` copy stays as today.

`lakeArtifacts` restoration reads `lake-build-dirs` from the previous
derivation and copies each directory back into place, writable, alongside
the root `.lake`. Lake decides what is up to date from its stored traces,
as it already does for the restored root `.lake`.

### 3. Export the runtime search path

`installPhase` also writes `$out/nix-support/lean-path`: the `lake env`
entries, rewritten to store paths.

| entry | rewritten to |
|---|---|
| a workspace entry | `$out/<relative path>` |
| a `.lake/packages/<name>/<suffix>` entry | `<store path of deps.<name>>/<suffix>`. Resolve it by dependency name, not with `readlink`: for `lakefile.lean` dependencies, `configurePhase` replaces the shadow's `.lake` with writable copies, so the build-time path is not a symlink into the store. |
| a toolchain entry | dropped; `LEAN_SYSROOT` covers it |

A new helper applies the file:

```nix
lake2nix.wrapExecutables drv
```

It wraps each `drv/bin/*` with `makeWrapper`, setting `LEAN_SYSROOT` to the
toolchain and `LEAN_PATH` from `drv/nix-support/lean-path`, which it reads
at build time, so evaluation needs no import from derivation. ix's
`wrapBin`, its hand-assembled `leanPath` and the `.lake/kernel` special
case become `lake2nix.wrapExecutables`.

## Effect on ix

These go away:

- the `removeAttrs` over `buildDeps` and the `lakePackageOverrides` file
  (part 1);
- `wrapBin` and `leanPath` (part 3);
- any listing of `Aiur`, `IxVM` or `MultiStark` directories in the flake;
- the rebuild of the three local packages in `ix`, `IxTests` and other
  downstream derivations (part 2).

`ix-kernel`'s `buildDir := "../.lake/kernel"` keeps working, because its
library directory comes from Lake like any other. The flake still marks
the Mathlib-only packages as unbuilt (`depOverride`); that is unrelated to
local packages.

## Compatibility

- **A single-package project:** `lake env` reports only the root library
  directory and the Git dependencies, so installs and restores are as
  today, plus two small files under `nix-support`.
- **`installArtifacts = false`:** nothing is installed, and no
  `lake-build-dirs` or `lean-path` is written. `wrapExecutables` on such a
  derivation is an error that names the missing file.
- **A consumer's own overrides:** an existing `.lake/package-overrides.json`
  still wins, through the `[ ! -e ]` check, so current workarounds keep
  working until they are removed.

## Testing

- **A new `local` template:** a root package that requires a local package
  by path, and an executable that imports the local package's module at run
  time through `importModules`.
- **New checks:**
  - **Build:** the template builds with no overrides.
  - **Run time:** its wrapped executable resolves the local module.
  - **Restore:** a second `mkPackage` with `lakeArtifacts` rebuilds nothing
    in the local package (assert on `lake build`'s job output).
- **Migrate `incremental-dep`** onto the new behaviour, removing its
  hand-written `crossOverrides`.

## Open questions

- **Does `lake env` re-elaborate the workspace configuration?** If so, does
  it do so without touching the network, after the build? It should, since
  the manifest and overrides are already in place, but this needs
  confirming on the pinned Lake.
- **What does a custom `buildDir` outside the workspace root look like?** A
  workspace entry is defined as one under the build directory, which also
  holds the root package. A `buildDir` pointing outside the workspace
  (`../../x`) would be skipped; Lake allows it, so the install should
  probably reject it with an error rather than skip it silently.
- **Is copying every build directory too large?** Each derivation's output
  holds its own copy of each local package's build. Hard links or symlinks
  to the restored `lakeArtifacts` copy could deduplicate unchanged packages
  later.
