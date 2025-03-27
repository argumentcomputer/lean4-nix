import RustFFI
import LSpec

open LSpec

def addSuite : List LSpec.TestSeq :=
[
  test "CAdd" (CAdd 1 1 = 2) $
  test "CRsAdd" (CRsAdd 1 1 = 3) $
  test "RsAdd" (RsAdd 1 1 = 3)
]

def main := LSpec.lspecIO (.ofList [
  ("addition", addSuite),
])
