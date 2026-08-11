# Lean 4 Nix

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fargumentcomputer%2Flean4-nix)](https://garnix.io/repo/argumentcomputer/lean4-nix)

Nix flake build for Lean 4.

Features:

- Provide released Lean toolchains, patched to run under Nix
- Select a toolchain from a `lean-toolchain` file or a version tag
- Build Lake projects (with executables, libraries, and facets) incrementally
  with Nix
- Convert `lake-manifest.json` into Nix dependencies

Toolchains are the released binaries from `leanprover/lean4`; Lean is not built
from source. A toolchain is a plain derivation, so no overlay is required —
though an optional additive one is provided.

## Example

The default minimal template is for projects requiring manual dependency
management:

``` sh
nix flake new --template github:argumentcomputer/lean4-nix ./minimal
```

The `.#dependency` template shows an example of using `lake-manifest.json` to
fetch dependencies automatically.

``` sh
nix flake new --template github:argumentcomputer/lean4-nix#dependency ./dependency
```

The `.#incremental` template shows an example of incremental builds.

## Caching

This project has CI by Garnix and uses
[`cache.garnix.io`](https://garnix.io/docs/caching) for binary caching. To use
the cache, there must be a match between the nixpkgs version listed in
`flake.lock` and the downstream project. Only the newest version will be cached.

## Flake outputs

### Toolchains

A toolchain is an ordinary derivation containing `bin/lean`, `bin/lake`,
`bin/leanc`, and the Lean libraries. Add it to a `devShell` or use it to build a
package; it does not need to be applied to `pkgs`.

```nix
lean = lean4-nix.lib.${system}.fromToolchainFile ./lean-toolchain;
```

- `lib.${system}.fromToolchainFile file`: Reads the toolchain from a
  `lean-toolchain` file. Due to Nix's pure evaluation principle, this only
  supports `leanprover/lean4:{tag}` files where the tag refers to a stable
  version listed in `data/toolchains.json`.
- `lib.${system}.fromToolchain toolchain`: The same, with the file contents
  given directly as a string.
- `lib.${system}.toolchains`: An attribute set of every version in
  `data/toolchains.json`, keyed by tag.
- `packages.${system}.{tag}`: The same set, as flake packages.
  `packages.${system}.default` is the version used by the templates.

These are patched against this flake's `nixpkgs`, which is also what the binary
cache is built from. To use your own `nixpkgs` instead — for example to match the
`stdenv` you link Lean FFI code with — go through `mkLib`, which exposes the
same three attributes:

```nix
lean = (lean4-nix.mkLib pkgs).fromToolchainFile ./lean-toolchain;
```

The minimal supported version is `v4.11.0`, since it is the version when Lean's
official Nix flake was deprecated.

To use a nightly or release candidate that is not listed yet, add it to
`data/toolchains.json`; see [Development](#development).

### Overlay

`overlays.default` is an optional convenience for projects already assembling a
`pkgs` with overlays. It is purely additive: it introduces a `lean4-nix`
attribute and overrides nothing, so nixpkgs' own `pkgs.lean` is left as it is.

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [ lean4-nix.overlays.default ];
};
lean = pkgs.lean4-nix.fromToolchainFile ./lean-toolchain;
```

The overlay exposes the same attributes as `mkLib`, and resolves them against
the `pkgs` it is applied to.

### `lake2nix`

Use `lake2nix = pkgs.callPackage lean4-nix.lake { inherit lean; }` to generate
the lake utilities for a given toolchain.

`lake2nix.cleanLakeSource src` restricts a source tree to the files `lake build`
actually reads, so that editing unrelated files (`flake.nix`, CI config, docs)
does not invalidate the build. It is the analogue of crane's
`cleanCargoSource`, and keeps directories plus:

- `*.lean` (including `lakefile.lean`)
- `*.toml` (including `lakefile.toml`)
- `*.c`, `*.cpp`, `*.h`, `*.hpp`, for `extern_lib` targets and FFI shims
- `lake-manifest.json` and `lean-toolchain`

A local `.lake` build directory is always excluded, since the build creates its
own and stale artifacts would collide with the dependency shadow directories.

```nix
src = lake2nix.cleanLakeSource ./.;
```

To keep additional files, compose with the underlying predicate
`lake2nix.filterLakeSources`:

```nix
src = pkgs.lib.cleanSourceWith {
  src = ./.;
  filter = path: type: lake2nix.filterLakeSources path type || myOwnFilter path type;
};
```

`lake2nix.buildDeps { ... }` automatically reads the `lake-manifest.json` file
and builds its dependencies using `lake build`. The output is an attr set of
derivations for each dependency. It takes the following arguments:

- `src`: The source directory
- `manifestFile ? ${src}/lake-manifest.json`: Path to the manifest file
- `depOverride ? {}`: Attr set of any custom arguments to use when building a
  given dependency, such as `buildPhase` or `preConfigure`.
- `depOverrideDeriv ? {}`: Attr set of derivations to use instead of building dependencies

`lake2nix.mkPackage { ... }` builds the given build target of the Lake project
using `lake build`, optionally with the dependencies built by `buildDeps`. The
output is a derivation. It takes the following arguments:

- `name`: The name of the desired target to build
- `src`: The source directory name from `manifestFile`
- `staticLibDeps ? []`: List of static libraries to link with.
- `lakeDeps`: If provided, use these dependencies instead of calling `buildDeps` internally
- `lakeArtifacts`: If provided, copy the `.lake` artifacts from another
  derivation for incremental builds
- `buildLibrary ? false`: Whether to build library facets for the `name` build target
- `installArtifacts ? true`: Whether to export `.lake` artifacts and source in the derivation `outPath` for incremental builds
- `configurePhase`: If provided, override the configure phase
- `buildPhase`: If provided, override the build phase
- `installPhase`: If provided, override the install phase

## Troubleshooting

### Only `leanprover/lean4:{tag}` toolchains are supported

The Lean version is not listed in `data/toolchains.json`. Add it; see
[Development](#development).

### Cadical Failure

``` sh
bv-decide.lean:19:2: error: Failed to execute external prover:
could not execute external process 'cadical'
```

`bv-decide` shells out to `cadical`, which the release tarball does not ship.
The toolchain bundles it: `bin/lean`, `bin/lake`, `bin/leanc`, and `bin/leanmake`
are wrapped so it is on `PATH`, and nothing needs to be added to a derivation or
`devShell`.

This error therefore only appears when Lean is invoked in a way that bypasses
those wrappers, such as running `lib/lean/…` directly.

## Development

Use the provided pre-commit config:

``` sh
prek install
```

Use `nix flake check` to check the template builds.

Update the template `lean-toolchain` files when new Lean versions come out. When
a new version is released, execute

``` sh
nix run .#toolchain-fetch $VERSION [$VERSION_TAG]
```

from the repository root. This prefetches the release tarballs for all four
supported systems and writes the version into `data/toolchains.json`; no new
file is added and nothing else needs editing. Supply `$VERSION_TAG` to address
any version tag mismatches (e.g. `4.20.1` ships `lean-4.20.0-*` assets), which
also records the explicit URLs.

All code must be formatted with `nixfmt` before merging into `main`. To use
it, execute

```sh
nix fmt .
```
