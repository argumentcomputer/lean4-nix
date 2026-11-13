module

/-- Evaluated through the interpreter by `Interpret`, which never imports
this module at compile time, so its code is not linked into the binary. A
`module` keeps its compiled code in the `.ir` files beside the olean rather
than in the olean itself. -/
public def Greeting.greeting : String := "hello from the interpreter"
