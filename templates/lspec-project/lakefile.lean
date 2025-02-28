import Lake
open Lake DSL

require LSpec from git
  "https://github.com/argumentcomputer/LSpec" @ "ca8e2803f89f0c12bf9743ae7abbfb2ea6b0eeec"

section Tests

-- Run with `lake exe Tests.Add` or `nix run .#test`
lean_exe Tests.Add
lean_exe Tests.Sub

end Tests

-- NOTE: kebab-case in the package name isn't supported with Nix due to `«»` parsing
package LSpecProject where
  version := v!"0.1.0"

@[default_target]
lean_lib «LSpecProject» where
  -- add library configuration options here

-- Run with `lake exe lspec-project` or `nix run`
@[default_target]
lean_exe "lspec-project" where
  root := `Main
