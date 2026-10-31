//! Runs the upstream as its patches leave it: `f` returns 2 after the first, and the
//! second, which applies only over the first, adds `g`.
extern fn f() c_int;
extern fn g() c_int;

pub fn main() u8 {
    return if (f() == 2 and g() == 3) 0 else 1;
}
