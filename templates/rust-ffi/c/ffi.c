#include "lean/lean.h"
#include "rust.h"

extern uint32_t c_rs_add(uint32_t a, uint32_t b)
{
    return rs_sum_plus_one(a, b);
}

extern uint32_t c_add(uint32_t a, uint32_t b)
{
    return a + b;
}
