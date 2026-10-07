//! Compiles the TensorRT shim (native/tensorrt.cpp) against the vendored
//! headers. Needs only a C++ compiler: TensorRT itself is opened at run time.

fn main() {
    println!("cargo:rerun-if-changed=native/tensorrt.cpp");
    println!("cargo:rerun-if-changed=third_party/tensorrt");
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("native/tensorrt.cpp")
        // System includes, so warnings in NVIDIA's headers stay quiet.
        .flag("-isystem")
        .flag("third_party/tensorrt/include")
        .flag("-isystem")
        .flag("third_party/tensorrt/cuda_stub")
        .compile("meteor_tensorrt");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-lib=dl");
    }
}
