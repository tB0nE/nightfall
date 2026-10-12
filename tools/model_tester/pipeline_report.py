#!/usr/bin/env python3
"""Still-image model comparison using the production native SDR shaders."""
import argparse
import ast
import base64
import hashlib
import json
import re
import time
from pathlib import Path

import moderngl
import numpy as np
from PIL import Image
from run_models import robust_range

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "extensions/nightfall-xr/src/fast_xr_renderer_android.cpp"
CAPTURE = ROOT / "addons/nightfall-stream/src/video/texture_uploader.cpp"


def write_html(output, report):
    """Embed images so local-file previews and shared HTML need no sibling access."""
    images = {}
    for path in [output / "original.png", *output.glob("*/*.png")]:
        key = path.relative_to(output).as_posix()
        images[key] = "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode("ascii")
    template = Path(__file__).with_name("pipeline_report.html").read_text()
    html = template.replace("__REPORT_JSON__", json.dumps(report).replace("<", "\\u003c"))
    html = html.replace("__IMAGES_JSON__", json.dumps(images))
    (output / "index.html").write_text(html)


def shader(name):
    block = NATIVE.read_text().split(f"static const char *{name} =", 1)[1]
    parts = []
    for line in block.splitlines():
        match = re.match(r'\s*("(?:\\.|[^"\\])*")', line)
        if match:
            parts.append(ast.literal_eval(match[1]))
            if line.rstrip().endswith(";"):
                break
    if not parts:
        raise ValueError(f"Missing shader {name}")
    return "".join(parts)


def desktop(source):
    source = re.sub(r"#version \d+ es", "#version 430 core\n#define NIGHTFALL_TEXTURE_2D", source)
    return re.sub(r"precision \w+ \w+;", "", source)


def working_size(video_size, depth_size):
    width, height = video_size
    dw, dh = depth_size
    grid = (max(1,width//4), max(1,height//4))
    if abs((dw/dh)/(width/height)-1) < .05:
        return max(dw,grid[0]), max(dh,grid[1])
    return grid


class Renderer:
    def __init__(self):
        self.ctx = moderngl.create_standalone_context(backend="egl", require=430)
        self.vbo = self.ctx.buffer(np.array([[-1,-1,0,0],[1,-1,1,0],[-1,1,0,1],[1,1,1,1]], np.float32).tobytes())
        self.programs = {}
        for name in ("UPSAMPLE_FRAGMENT_SRC", "OFFSET_FRAGMENT_SRC", "FRAGMENT_SRC"):
            self.programs[name] = self.ctx.program(vertex_shader=desktop(shader("VERTEX_SRC")), fragment_shader=desktop(shader(name)))
        capture = CAPTURE.read_text().split('GLES_DEPTH_CAPTURE_FRAGMENT_SHADER = R"(', 1)[1].split(')";', 1)[0]
        capture = re.sub(r"#extension[^\n]*", "", capture).replace("samplerExternalOES", "sampler2D").replace("v_uv", "v_plain")
        self.programs["capture"] = self.ctx.program(vertex_shader=desktop(shader("VERTEX_SRC")), fragment_shader=desktop(capture))

    def texture(self, array):
        if array.ndim == 2:
            array = array[..., None]
        tex = self.ctx.texture((array.shape[1], array.shape[0]), array.shape[2], np.ascontiguousarray(array[::-1]).tobytes())
        tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
        tex.repeat_x = tex.repeat_y = False
        return tex

    def draw(self, name, size, textures, uniforms):
        program = self.programs[name]
        tex = self.ctx.texture(size, 4)
        tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
        tex.repeat_x = tex.repeat_y = False
        fbo = self.ctx.framebuffer([tex])
        fbo.use()
        self.ctx.viewport = (0, 0, *size)
        for unit, (key, value) in enumerate(textures.items()):
            value.use(unit)
            if key in program:
                program[key].value = unit
        for key, value in uniforms.items():
            if key in program:
                program[key].value = value
        if "u_texmatrix" in program:
            program["u_texmatrix"].write(np.eye(4, dtype=np.float32).tobytes())
        vao = self.ctx.vertex_array(program, [(self.vbo, "2f 2f", "a_position", "a_texcoord")])
        vao.render(moderngl.TRIANGLE_STRIP)
        pixels = np.frombuffer(fbo.read(components=4, alignment=1), np.uint8).reshape(size[1], size[0], 4)[::-1].copy()
        vao.release()
        fbo.release()
        return tex, pixels


def unpack(output, layout):
    if layout == "packed2x2":
        a = output[0]
        if a.ndim != 3 or a.shape[-1] != 4:
            raise ValueError(f"Expected NHWC packed four-channel output, got {output.shape}")
        return a.reshape(a.shape[0], a.shape[1], 2, 2).transpose(0,2,1,3).reshape(a.shape[0]*2,a.shape[1]*2)
    if layout == "nchw":
        return output[0,0]
    if layout == "nhwc":
        return output[0,:,:,0]
    if layout == "hw":
        return np.squeeze(output)
    raise ValueError(f"Unknown output layout {layout}")


def infer(spec, rgb, base):
    path = (base / spec["path"]).resolve()
    data = rgb.astype(np.float32) / 255
    if spec.get("preprocessing", "rgb01") == "imagenet":
        data = (data - np.array([.485,.456,.406], np.float32)) / np.array([.229,.224,.225], np.float32)
    elif spec.get("preprocessing", "rgb01") != "rgb01":
        raise ValueError("Unsupported preprocessing")
    if spec["input_layout"] in ("nchw", "ntchw"):
        data = data.transpose(2,0,1)
    elif spec["input_layout"] != "nhwc":
        raise ValueError("Input layout must be nhwc, nchw or ntchw")
    data = np.ascontiguousarray(data[None])
    if spec["input_layout"] == "ntchw":
        data = data[:,None]
    start = time.perf_counter()
    if path.suffix.lower() == ".tflite":
        from ai_edge_litert.interpreter import Interpreter
        session = Interpreter(model_path=str(path), num_threads=4)
        session.allocate_tensors()
        detail = session.get_input_details()[0]
        if detail["dtype"] != np.float32 or tuple(detail["shape"]) != data.shape:
            raise ValueError(f"This runner requires matching float32 input: {detail['shape']} {detail['dtype']}, supplied {data.shape}")
        session.set_tensor(detail["index"], data)
        session.invoke()
        output = session.get_tensor(session.get_output_details()[0]["index"])
    elif path.suffix.lower() == ".onnx":
        import onnxruntime as ort
        session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        output = session.run([spec.get("output_name", session.get_outputs()[0].name)], {session.get_inputs()[0].name: data})[0]
    else:
        raise ValueError(f"Unsupported model: {path}")
    raw = unpack(output, spec["output_layout"]).astype(np.float32)
    if raw.ndim != 2 or not np.isfinite(raw).all():
        raise ValueError("Depth must be a finite 2D array")
    return raw, {"model_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "load_and_inference_ms": (time.perf_counter()-start)*1000, "backend": "desktop CPU"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--meteor-models", type=Path, help="Add installed Meteor ONNX models from this directory, using controlled native input")
    parser.add_argument("--include-vda", action="store_true", help="Include Meteor VDA cold-start ONNX (requires --meteor-models; no temporal history)")
    parser.add_argument("--separation", type=float, default=75, help="UI percentage")
    parser.add_argument("--convergence", type=float, default=50, help="UI percentage")
    args = parser.parse_args()
    specs = json.loads(args.manifest.read_text())
    if args.meteor_models:
        for filename, label, size in (
            ("zipdepth_edgepad_384.onnx", "Meteor EdgePad-384", [384,384]),
            ("zipdepth_wide_512x288.onnx", "Meteor EdgePad-512 widescreen", [512,288]),
            ("zipdepth_wide_672x384.onnx", "Meteor EdgePad-672 widescreen", [672,384]),
        ):
            path = args.meteor_models.resolve() / filename
            if not path.is_file():
                raise FileNotFoundError(f"Missing Meteor model: {path}")
            specs.append({"name":label+" (controlled input)", "path":str(path),
                          "input_size":size,"input_layout":"nchw","output_layout":"nchw"})
    if args.include_vda:
        if not args.meteor_models:
            parser.error("--include-vda requires --meteor-models")
        path = args.meteor_models.resolve() / "vda_s_518x294_cold.onnx"
        if not path.is_file():
            raise FileNotFoundError(path)
        specs.append({"name":"Meteor VDA Small 518×294 (cold start, controlled input)",
                      "path":str(path),"input_size":[518,294],"input_layout":"ntchw",
                      "output_layout":"nchw","output_name":"depth","preprocessing":"imagenet"})
    args.output.mkdir(parents=True, exist_ok=True)
    rgb = np.asarray(Image.open(args.image).convert("RGB"))
    renderer = Renderer()
    source = renderer.texture(rgb)
    Image.fromarray(rgb).save(args.output / "original.png")
    report = {"scope": "Production native SDR shaders on desktop EGL; CPU inference, canonical upright capture, first-frame normalization. Not live Quest/Meteor parity; no temporal history, HDR, transport, SurfaceTexture transform or picture controls.", "renderer": renderer.ctx.info["GL_RENDERER"], "separation_pct": args.separation, "convergence_pct": args.convergence, "native_sha256": hashlib.sha256(NATIVE.read_bytes()).hexdigest(), "capture_sha256": hashlib.sha256(CAPTURE.read_bytes()).hexdigest(), "models": []}
    separation, convergence = .006 * args.separation / 100, args.convergence / 100
    for index, spec in enumerate(specs):
        print(f"Processing {spec['name']}", flush=True)
        folder = args.output / str(index)
        folder.mkdir(exist_ok=True)
        w, h = spec["input_size"]
        pad = spec.get("pad_rows", 0)
        if w <= 0 or h <= 2*pad or pad < 0:
            raise ValueError("Invalid capture/padding dimensions")
        capture_tex, captured = renderer.draw("capture", (w,h-2*pad), {"u_video":source}, {})
        model_rgb = np.pad(captured[:,:,:3], ((pad,pad),(0,0),(0,0)), mode="edge")
        Image.fromarray(model_rgb).save(folder / "input.png")
        raw, info = infer(spec, model_rgb, args.manifest.resolve().parent)
        if pad:
            if raw.shape != (h,w):
                raise ValueError("Padded models currently require output at input resolution")
            raw = raw[pad:-pad]
        np.save(folder / "raw.npy", raw)
        lo, hi = robust_range(raw, .02, 512)
        depth = (np.clip((raw-lo)/max(hi-lo,1e-6),0,1)*255).astype(np.uint8)
        Image.fromarray(depth).save(folder / "normalized.png")
        depth_tex = renderer.texture(depth)
        size = working_size((rgb.shape[1],rgb.shape[0]), (raw.shape[1],raw.shape[0]))
        working, _ = renderer.draw("UPSAMPLE_FRAGMENT_SRC", size, {"u_texture":source,"u_depth":depth_tex,"u_depthGuide":capture_tex}, {"u_sigmaR":1000.,"u_sharp":0.,"u_linear":1})
        offsets, _ = renderer.draw("OFFSET_FRAGMENT_SRC", size, {"u_depth":working}, {"u_dispTexels":separation*size[0],"u_convergence":convergence})
        offsets.filter = (moderngl.NEAREST, moderngl.NEAREST)
        for label, mode, eye in (("depth",7,0),("left",0,0),("right",0,1),("offset",12,0)):
            final, pixels = renderer.draw("FRAGMENT_SRC", (rgb.shape[1],rgb.shape[0]), {"u_texture":source,"u_depth":working,"u_offsets":offsets}, {"u_disparity":separation if eye==0 else -separation,"u_occlusion":1.,"u_eyeIndex":float(eye),"u_convergence":convergence,"u_dispTexels":separation*size[0],"u_lowResWidth":float(size[0]),"u_frameWidth":float(rgb.shape[1]),"u_debugSolid":0.,"u_stereoMode":mode,"u_depthProcessStage":5})
            Image.fromarray(pixels[:,:,:3]).save(folder / f"{label}.png")
            final.release()
        report["models"].append({"name":spec["name"],"directory":str(index),"spec":spec,"depth_shape":list(raw.shape),"working_size":list(size),"normalization_range":[float(lo),float(hi)],**info})
        for tex in (capture_tex,depth_tex,working,offsets):
            tex.release()
    (args.output / "report.json").write_text(json.dumps(report, indent=2)+"\n")
    write_html(args.output, report)
    print(args.output / "index.html")


if __name__ == "__main__":
    main()
