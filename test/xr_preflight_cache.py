"""Cache source/command/toolchain-matched DEV helpers, never an unvalidated build."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ARTIFACTS=("live-foveation-tests", "foveated-qp-tests", "live-bitrate-tests", "encoder-bitrate-tests", "eye-rect-tests", "eye-format-tests", "image-lease-tests", "quad-math-tests", "frame-time-tests",
           "latest-job-tests", "async-transport-tests",
           "libmeteor-tracking-probe.so", "libmeteor-nvenc-probe.so")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint(root, reference):
    hashed=hashlib.sha256()
    files=[Path(__file__),root / "tools/build_support/probe_monado_nvenc.sh"]
    for directory in (root / "test",root / "extensions/nightfall-xr/include",
                      reference / "external/ffnvcodec"):
        files.extend(path for path in directory.rglob("*")
                     if path.is_file() and path.suffix in (".c",".cpp",".h"))
    for path in sorted(set(files)):
        hashed.update(str(path.resolve()).encode()+b"\0"+path.read_bytes()+b"\0")
    shaders=root / ".build-cache/meteor-xr/monado-linux-spike"
    for stage in ("vert","frag"):
        source=root / "test" / f"meteor_quad.{stage}"
        if not source.exists(): continue # Minimal unit-test fixture.
        header=shaders / f"meteor_quad.{stage}.h"
        stamp=shaders / f"meteor_quad.{stage}.sha256"
        if not stamp.exists() or stamp.read_text().split()[0]!=digest(source):
            raise RuntimeError("Quad shaders need rebuilding with probe_monado_runtime.sh --build")
        hashed.update(source.read_bytes()+header.read_bytes())
    for compiler in ("cc","c++"):
        executable=Path(shutil.which(compiler)).resolve()
        hashed.update(str(executable).encode()+str(executable.stat().st_mtime_ns).encode())
        hashed.update(subprocess.check_output([compiler,"--version"]))
    return hashed.hexdigest()


def valid(directory, key):
    try:
        manifest=json.loads((directory / "validated.json").read_text())
        return manifest["key"]==key and all(
            (directory / name).is_file() and os.access(directory / name,os.X_OK)
            and digest(directory / name)==manifest["artifacts"][name] for name in ARTIFACTS)
    except (OSError,ValueError,KeyError,TypeError):
        return False


def build(root, reference, directory):
    directory.mkdir(mode=0o700,parents=True,exist_ok=True)
    common=["-Wall","-Wextra","-Werror"]
    subprocess.run(["c++","-std=c++17",*common,str(root / "test/meteor_live_foveation_test.cpp"),
                    "-o",str(directory / "live-foveation-tests")],check=True)
    subprocess.run([str(directory / "live-foveation-tests")],check=True,timeout=10)
    subprocess.run(["c++","-std=c++17",*common,str(root / "test/meteor_foveated_qp_test.cpp"),
                    "-o",str(directory / "foveated-qp-tests")],check=True)
    subprocess.run([str(directory / "foveated-qp-tests")],check=True,timeout=10)
    subprocess.run(["c++","-std=c++17",*common,str(root / "test/meteor_live_bitrate_test.cpp"),
                    "-o",str(directory / "live-bitrate-tests")],check=True)
    subprocess.run([str(directory / "live-bitrate-tests")],check=True,timeout=10)
    for source,name,extra in (
        ("meteor_tracking_contention_test.cpp","tracking-contention-tests",
         ["-pthread","-I",str(root / "extensions/nightfall-xr/include")]),
        ("monado_tracking_relation_test.cpp","tracking-relation-tests",
         ["-Wno-unused-function","-ldl"]),
        ("monado_controller_mapping_test.cpp","controller-mapping-tests",
         ["-Wno-unused-function","-ldl"])):
        subprocess.run(["c++","-std=c++20",*common,*extra,str(root / "test" / source),
                        "-o",str(directory / name)],check=True)
        subprocess.run([str(directory / name)],check=True,timeout=10)
    subprocess.run(["c++","-std=c++17",*common,str(root / "test/meteor_encoder_bitrate_test.cpp"),
                    "-o",str(directory / "encoder-bitrate-tests")],check=True)
    subprocess.run([str(directory / "encoder-bitrate-tests")],check=True,timeout=10)
    tests=[("meteor_eye_rect_test.c","eye-rect-tests",[]),
           ("meteor_frame_timestamp_test.c","frame-time-tests",[]),
           ("meteor_quad_math_test.c","quad-math-tests",[]),
           ("meteor_eye_format_test.c","eye-format-tests",[]),
           ("monado_image_lease_test.c","image-lease-tests",[]),
           ("meteor_latest_job_queue_test.c","latest-job-tests",["-pthread"]),
           ("monado_async_transport_test.c","async-transport-tests",["-pthread","-D_POSIX_C_SOURCE=200809L"])]
    for source,name,extra in tests:
        subprocess.run(["cc","-std=c11",*common,*extra,str(root / "test" / source),
                        "-o",str(directory / name),"-lm"],check=True)
        subprocess.run([str(directory / name)],check=True,timeout=10)
    cpp=["c++","-std=c++17","-O2","-fPIC","-shared","-pthread",*common]
    subprocess.run([*cpp,"-I",str(root / "extensions/nightfall-xr/include"),
        str(root / "test/meteor_tracking_client_bridge.cpp"),"-o",
        str(directory / "libmeteor-tracking-probe.so")],check=True)
    subprocess.run([*cpp,"-DMETEOR_MONADO_BRIDGE","-Wno-missing-field-initializers",
        "-I",str(root / ".build-cache/meteor-xr/monado-linux-spike"),
        "-I",str(reference / "external/ffnvcodec"),str(root / "test/meteor_vulkan_nvenc_probe.cpp"),
        "-lvulkan","-ldl","-o",str(directory / "libmeteor-nvenc-probe.so")],check=True)


def prepare(root, reference, output):
    start=time.monotonic()
    cache=root / ".build-cache/meteor-xr/helper-cache"
    cache.mkdir(mode=0o700,parents=True,exist_ok=True)
    cache.chmod(0o700)
    key=fingerprint(root,reference)
    directory=cache / key
    with (cache / "prepare.lock").open("a") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        hit=valid(directory,key)
        if not hit:
            build(root,reference,directory)
            if fingerprint(root,reference) != key:
                raise RuntimeError("XR helper inputs changed during preparation; retry with stable sources")
            manifest={"key":key,"artifacts":{name:digest(directory / name) for name in ARTIFACTS}}
            temporary=directory / "validated.tmp"
            temporary.write_text(json.dumps(manifest))
            temporary.replace(directory / "validated.json")
        output.mkdir(parents=True,exist_ok=True)
        for name in ARTIFACTS:
            shutil.copy2(directory / name,output / name)
    print(f"XR_PREFLIGHT cache={'hit' if hit else 'validated_build'} elapsed_ms={(time.monotonic()-start)*1000:.1f} key={key}",flush=True)
    return hit


if __name__=="__main__":
    prepare(*(Path(arg).resolve() for arg in sys.argv[1:]))
