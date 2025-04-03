import Lake
open Lake DSL

-- NOTE: We can't use a hyphen in the package name as it will be exported to `lake-manifest.json` as "«ffi-rust»".
-- Nix fails to parse the `«»` chars properly because they can't be used in a file path
-- The error would look something like this:
-- ```
-- > clang: error: no such file or directory: '$/nix/store/<hash>--ffi-rust--lib/lib302253ffi-rust302273.a'
-- ```
package "ffi_rust" where
  version := v!"0.1.0"

lean_lib «FFIRust» where
  -- add library configuration options here

@[default_target]
lean_exe "ffi-rust" where
  root := `Main

require LSpec from git
  "https://github.com/argumentcomputer/LSpec" @ "0f9008e70927c4afac8ad2bc32f2f4fbda044096"

section Tests

lean_lib Tests

@[test_driver]
lean_exe Tests.Main

end Tests

section FFI

/-- Build the static lib for the Rust crate -/
extern_lib ffi_rust pkg := do
  proc { cmd := "cargo", args := #["build", "--release"], cwd := pkg.dir } (quiet := true)
  let libName := nameToStaticLib "ffi_rust"
  inputBinFile $ pkg.dir / "target" / "release" / libName

/-- Build the static lib for the C files -/
extern_lib ffi_c pkg := do
  let compiler := "cc"
  let cDir := pkg.dir / "c"
  let buildCDir := pkg.buildDir / "c"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString, "-I", cDir.toString]

  let cDirEntries ← cDir.readDir

  -- Include every C header file in the trace mix
  let extraDepTrace := cDirEntries.foldl (init := getLeanTrace) fun acc dirEntry =>
    let filePath := dirEntry.path
    if filePath.extension == some "h" then do
      let x ← acc
      let y ← computeTrace $ TextFilePath.mk filePath
      pure $ x.mix y
    else acc

  -- Collect a build job for every C file in `cDir`
  let mut buildJobs := #[]
  for dirEntry in cDirEntries do
    let filePath := dirEntry.path
    if filePath.extension == some "c" then
      let oFile := buildCDir / dirEntry.fileName |>.withExtension "o"
      let srcJob ← inputTextFile filePath
      let buildJob ← buildO oFile srcJob weakArgs #[] compiler extraDepTrace
      buildJobs := buildJobs.push buildJob

  let libName := nameToStaticLib "ffi_c"
  buildStaticLib (pkg.nativeLibDir / libName) buildJobs

end FFI
