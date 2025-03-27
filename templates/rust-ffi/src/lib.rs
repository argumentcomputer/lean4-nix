#[unsafe(no_mangle)]
extern "C" fn rs_sum_plus_one(left: u32, right: u32) -> u32 {
    left + right + 1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        let result = rs_sum_plus_one(2, 2);
        assert_eq!(result, 5);
    }
}
