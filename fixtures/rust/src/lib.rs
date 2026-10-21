//! A minimal library for exercising the dnix build on every target.

extern "C" {
    fn dnix_fixture_c_add(a: i32, b: i32) -> i32;
}

/// Adds two numbers, through the C half of the fixture.
#[no_mangle]
pub extern "C" fn dnix_fixture_add(a: i32, b: i32) -> i32 {
    unsafe { dnix_fixture_c_add(a, b) }
}

/// The version string, to check that strings and statics survive.
#[no_mangle]
pub extern "C" fn dnix_fixture_version() -> *const u8 {
    b"dnix fixture 0.1.0\0".as_ptr()
}
