fn main() {
    // A little C, so the fixture exercises the per-target C compiler too.
    cc::Build::new().file("csrc/add.c").compile("dnix_fixture_c");
    println!("cargo:rerun-if-changed=csrc/add.c");
}
