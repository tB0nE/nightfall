"""Real GPU layer contract: capabilities, decoded output and same-session recovery.

Requires the isolated runtime from probe_monado_runtime.sh --build and NVIDIA
encoding. Does not register a runtime, launch Steam or require a headset.
"""
import argparse
import json
from pathlib import Path
from smoke_xr_quad_composition import run


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root",type=Path)
    args=parser.parse_args()
    root=args.root.resolve()
    results=[]
    for codec in ("h264","h265"):
        for fixture in ("quads","panorama","cylinder","stack"):
            panorama=fixture=="panorama"
            output=run(root,eye_size=512,eye_height=768,codec=codec,
                live_bitrate=fixture=="quads",live_foveation=fixture=="quads",
                panorama=panorama,layer_matrix=True,cylinder=fixture=="cylinder",stack=fixture=="stack")
            results.append({"codec":codec,"fixture":fixture,
                "diagnostics":str(output),"outcome":"passed"})
    for radius in (0.0,float("inf")):
        output=run(root,eye_size=512,eye_height=768,codec="h265",cylinder=True,
            cylinder_radius=radius,layer_matrix=True)
        results.append({"codec":"h265","fixture":"cylinder","radius":str(radius),
            "diagnostics":str(output),"outcome":"passed"})
    report=root / ".build-cache/meteor-xr/layer-compatibility-report.json"
    report.write_text(json.dumps({"outcome":"passed","cases":results,
        "supported_layers":["stereo_projection","quad","equirect2","cylinder"],
        "rejection_recovery":["invalid_view_count","unsupported_type",
            "invalid_source_rect","invalid_cylinder","cube","equirect1","null_layer"]},indent=2)+"\n")
    print(f"PASS: complete advertised layer contract and same-session recovery; {report}",flush=True)


if __name__=="__main__":
    main()
