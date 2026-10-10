//! Compiles the TensorRT shim (native/tensorrt.cpp) against the vendored
//! headers. Needs only a C++ compiler: TensorRT itself is opened at run time.

fn main() {
    println!("cargo:rerun-if-changed=native/tensorrt.cpp");
    println!("cargo:rerun-if-changed=third_party/tensorrt");
    let mut build = cc::Build::new();
    build.cpp(true).std("c++17").file("native/tensorrt.cpp");
    for dir in ["third_party/tensorrt/include", "third_party/tensorrt/cuda_stub"] {
        if build.get_compiler().is_like_msvc() {
            build.include(dir);
        } else {
            // System includes, so warnings in NVIDIA's headers stay quiet.
            build.flag("-isystem").flag(dir);
        }
    }
    build.compile("meteor_tensorrt");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-lib=dl");
    }
}
