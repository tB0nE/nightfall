import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from check_xr_engine import validate_engine


class EngineValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix="nf-engine-validator-")
        self.addCleanup(self.temp.cleanup)
        self.out=Path(self.temp.name)
        view={"position":[0,0,0],"orientation":[0,0,0,1],"fov":[-.8,.8,.8,-.8]}
        self.records=[{"display_time_ns":i+1,"frame_id":i+1,"offset":i,"bytes":1,
            "width":4,"height":2,"views":[view,view]} for i in range(2)]
        self.write_records()
        (self.out / "monado-stereo.h264").write_bytes(b"ab")
        (self.out / "decoded.rgb").write_bytes(bytes([0,0,0,100,0,0,0,200,0,0,0,255])*4)
        self.app="ENGINE_XR_READY renderer=mobile\nENGINE_XR_COMPLETE\nENGINE_XR_STOPPING\n"
        self.service="\n".join(["METEOR_ENGINE_EXIT_REQUESTED","METEOR_ENCODER_INIT",
            "METEOR_ENCODER_DRAIN frames=2 surfaces=1","METEOR_ENCODER_RELEASED",
            "METEOR_IMAGE_LEASE retain=1 image=0","METEOR_IMAGE_LEASE retain=0 image=0",
            "METEOR_SOURCE_FORMAT left=43 right=43 packed=43",
            "METEOR_STEREO_SOURCE shared_image=1",
            "METEOR_EYE_SOURCE eye=0 array_layers=2 slice=0",
            "METEOR_EYE_SOURCE eye=1 array_layers=2 slice=1"])

    def write_records(self):
        (self.out / "monado-stereo.jsonl").write_text("\n".join(json.dumps(r) for r in self.records)+"\n")

    def validate(self):
        with patch("check_xr_engine.subprocess.run"):
            validate_engine(self.out,self.app,2,2,self.service)

    def test_valid(self): self.validate()

    def test_known_shutdown_warning_remains_visible(self):
        self.app+="ERROR: 3 RID allocations of type 'N9OpenXRAPI18InteractionProfileE' were leaked at exit.\n"
        self.validate()
        report=json.loads((self.out / "engine-outcome.json").read_text())
        self.assertFalse(report["engine_shutdown_clean"])
        self.assertEqual(len(report["shutdown_diagnostics"]),1)

    def test_unexpected_engine_error_fails(self):
        self.app+="ERROR: framebuffer failure\n"
        with self.assertRaises(RuntimeError): self.validate()

    def test_missing_lease_release_fails(self):
        self.service=self.service.replace("METEOR_IMAGE_LEASE retain=0 ","missing ")
        with self.assertRaises(RuntimeError): self.validate()

    def test_wrong_slice_fails(self):
        self.service=self.service.replace("slice=1","slice=0")
        with self.assertRaises(RuntimeError): self.validate()

    def test_nonmonotonic_metadata_fails(self):
        self.records[1]["display_time_ns"]=1; self.write_records()
        with self.assertRaises(RuntimeError): self.validate()

    def test_blank_output_fails(self):
        (self.out / "decoded.rgb").write_bytes(bytes(48))
        with self.assertRaises(RuntimeError): self.validate()


if __name__=="__main__": unittest.main()
