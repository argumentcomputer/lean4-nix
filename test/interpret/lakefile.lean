import Lake
open Lake DSL

package interpret

lean_lib Greeting

@[default_target]
lean_exe Interpret where
  supportInterpreter := true
  needs := #[`@/Greeting]
