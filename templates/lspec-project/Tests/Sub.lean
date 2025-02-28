import LSpec

open LSpec

def zero := 0

def main := lspecIO $ test "1 - 1 = 0" (1 - 1 == zero)
