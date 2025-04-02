import Blake3

abbrev input : ByteArray := ⟨#[0]⟩

def myHash := (Blake3.hash input).val.data

def main : IO Unit :=
  IO.println s!"Hash of [0]: {myHash}"
