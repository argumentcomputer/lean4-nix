import Lake
open Lake DSL

require Blake3 from git
  "https://github.com/argumentcomputer/Blake3.lean" @ "29018d578b043f6638907f3425af839eec345361"

package "ffi" where
  version := v!"0.1.0"

lean_lib «FFI» where
  -- add library configuration options here

@[default_target]
lean_exe "ffi" where
  root := `Main
