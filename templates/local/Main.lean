import Greeting
import Lean

open Lean

/-- Prints the greeting, then loads its module again at run time, which only
works when `LEAN_PATH` covers the local package's build output. -/
def main : IO Unit := do
  IO.println greeting
  initSearchPath (← findSysroot)
  let env ← importModules #[{ module := `Greeting }] {}
  IO.println s!"Imported at run time: {env.contains `greeting}"
