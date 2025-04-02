import Lake
open Lake DSL

require Blake3 from git
  "https://github.com/argumentcomputer/Blake3.lean/" @ "929682f937d6b5fec4958472af621fce991b7169"

package Example

@[default_target]
lean_exe Example where
  root := `Main
