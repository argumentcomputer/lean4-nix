import Lean
open Lean

/-- `evalConst` runs the interpreter over `Greeting.greeting`, whose code is
not linked into this binary, so Lean must find the module's IR next to its
olean on `LEAN_PATH`. -/
unsafe def evalGreeting (env : Environment) : IO String :=
  IO.ofExcept (env.evalConst String {} `Greeting.greeting)

@[implemented_by evalGreeting]
opaque evalGreetingSafe (env : Environment) : IO String

def main : IO Unit := do
  initSearchPath (← findSysroot)
  let env ← importModules #[{ module := `Greeting }] {} 0
  IO.println (← evalGreetingSafe env)
