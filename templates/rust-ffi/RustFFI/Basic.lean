-- Function defined in C
-- Adds two numbers
@[extern "c_add"]
opaque CAdd : UInt32 → UInt32 → UInt32

-- Function defined in Rust, called from C
-- Adds two numbers plus 1
@[extern "c_rs_add"]
opaque CRsAdd : UInt32 → UInt32 → UInt32

-- Function defined in Rust
-- Adds two numbers plus 1
@[extern "rs_sum_plus_one"]
opaque RsAdd : UInt32 → UInt32 → UInt32
