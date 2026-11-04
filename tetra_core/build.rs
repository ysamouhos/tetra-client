//! Compiles the vendored ETSI EN 300 395-2 ACELP reference codec (same copy
//! the brew-server uses) into the core library. Works for host builds and for
//! Android NDK / iOS cross-builds, because `cc` picks up the target's C
//! compiler from cargo-ndk / Xcode.
fn main() {
    let src = "third_party/tetra-codec/source";
    println!("cargo:rerun-if-changed={src}");
    println!("cargo:rerun-if-changed=third_party/tetra-codec/include");
    cc::Build::new()
        .file(format!("{src}/tetra-codec.c"))
        .file(format!("{src}/tetra-codec-impl.c"))
        .include(src)
        .include("third_party/tetra-codec/include")
        .warnings(false)
        .opt_level(2)
        .compile("tetra-codec");
}
