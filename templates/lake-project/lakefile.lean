import Lake
open Lake DSL

require LSpec from git
  "https://github.com/argumentcomputer/LSpec" @ "ca8e2803f89f0c12bf9743ae7abbfb2ea6b0eeec"

section Tests

-- Run with `lake exe Tests.Add` or `nix run .#test`
lean_exe Tests.Add

end Tests

-- NOTE: kebab-case in the package name isn't supported with Nix due to `«»` parsing
package LakeProject where
  version := v!"0.1.0"

@[default_target]
lean_lib «LakeProject» where
  -- add library configuration options here

-- Run with `lake exe lake-project` or `nix run`
@[default_target]
lean_exe "lake-project" where
  root := `Main
