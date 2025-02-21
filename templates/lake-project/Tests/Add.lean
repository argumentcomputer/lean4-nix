import LSpec

open LSpec

def two := 2

def main := lspecIO $ test "1 + 1 = 2" (two == 1 + 1)
