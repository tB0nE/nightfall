//! Compiles the TensorRT shim (native/tensorrt.cpp) against the vendored
//! headers. Needs only a C++ compiler: TensorRT itself is opened at run time.

fn main() {
    build_vda_vulkan();
    println!("cargo:rerun-if-changed=native/video_decoder.cpp");
    println!("cargo:rerun-if-changed=third_party/ffmpeg");
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("native/video_decoder.cpp")
        .include("third_party/ffmpeg/include")
        .compile("meteor_video_decoder");
    println!("cargo:rerun-if-changed=native/tensorrt.cpp");
    println!("cargo:rerun-if-changed=third_party/tensorrt");
    let mut build = cc::Build::new();
    build.cpp(true).std("c++17").file("native/tensorrt.cpp");
    for dir in [
        "third_party/tensorrt/include",
        "third_party/tensorrt/cuda_stub",
    ] {
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

fn build_vda_vulkan() {
    use std::{path::PathBuf, process::Command};
    println!("cargo:rerun-if-env-changed=METEOR_VDA_NCNN_SDK");
    println!("cargo:rerun-if-changed=native/vda_vulkan.cpp");
    println!("cargo:rerun-if-changed=native/vda_finite.h");
    println!("cargo:rerun-if-changed=native/vulkan_processing.h");
    for entry in std::fs::read_dir("tools")
        .expect("kernel headers")
        .flatten()
    {
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "h") {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os != "linux" && os != "windows" {
        return;
    }
    let sdk = std::env::var_os("METEOR_VDA_NCNN_SDK")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(if os == "windows" {
                "target/ncnn-windows"
            } else {
                "target/ncnn"
            })
        });
    if !sdk.join("include/ncnn/net.h").is_file() {
        println!(
            "cargo:warning=Optional VDA Vulkan runtime not built: set METEOR_VDA_NCNN_SDK to the matching ncnn SDK"
        );
        return;
    }
    let sdk = sdk.canonicalize().expect("ncnn SDK");
    let out_dir = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    let output = out_dir.join(if os == "windows" {
        "meteor_vda_vulkan.dll"
    } else {
        "libmeteor_vda_vulkan.so"
    });
    // Build into a fresh inode: truncating a loaded .so can crash a running
    // development instance during a rebuild.
    let compiled = out_dir.join(if os == "windows" {
        "meteor_vda_vulkan.pending.dll"
    } else {
        "libmeteor_vda_vulkan.pending.so"
    });
    let compiler = cc::Build::new().cpp(true).get_compiler();
    let mut command: Command = compiler.to_command();
    if compiler.is_like_msvc() {
        command
            .args(["/nologo", "/O2", "/std:c++17", "/EHsc", "/LD", "/MD"])
            .arg(format!("/I{}", sdk.join("include/ncnn").display()))
            .arg(format!("/Fo{}", out_dir.join("vda_vulkan.obj").display()))
            .arg("native/vda_vulkan.cpp")
            .arg("/link")
            .arg(format!("/LIBPATH:{}", sdk.join("lib").display()))
            .arg("ncnn.lib")
            .arg(format!(
                "/IMPLIB:{}",
                out_dir.join("meteor_vda_vulkan.lib").display()
            ))
            .arg(format!("/OUT:{}", compiled.display()));
    } else {
        command
            .args([
                "-O2",
                "-std=c++17",
                "-shared",
                "-fPIC",
                "native/vda_vulkan.cpp",
            ])
            .arg(format!("-I{}", sdk.join("include/ncnn").display()))
            .arg(format!("-L{}", sdk.join("lib").display()))
            .arg("-lncnn");
        if os == "linux" {
            command
                .arg("-Wl,-rpath,$ORIGIN")
                .arg(format!("-Wl,-rpath,{}", sdk.join("lib").display()));
        }
        command.arg("-o").arg(&compiled);
    }
    let status = command.status().expect("Compile VDA Vulkan runtime");
    assert!(status.success(), "VDA Vulkan runtime compilation failed");
    std::fs::rename(&compiled, &output)
        .expect("Install compiled VDA runtime (stop Meteor before rebuilding on Windows)");
    println!(
        "cargo:rustc-env=METEOR_VDA_VULKAN_LIBRARY={}",
        output.display()
    );
}
