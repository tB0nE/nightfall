import json
from pathlib import Path
import tempfile
import unittest
from report_xr_pipeline import report, summary


class PipelineReportTests(unittest.TestCase):
    def test_summary(self):
        self.assertIsNone(summary([]))
        self.assertEqual(summary([3,1,2])["p95_us"],3)

    def test_stages_and_missing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)
            (path / "service.log").write_text("GPU_PACK frame=1 us=200\n"
                "METEOR_DIRECT_TIMING frame=1 send_us=10 ack_us=1000\n")
            (path / "monado-stereo.jsonl").write_text("\n".join(
                json.dumps({"display_time_ns":value}) for value in [1,20_000_001,40_000_001]))
            result=report(path)
            self.assertEqual(result["encoded_display_timestamp_hz"],50)
            self.assertEqual(result["stages"]["gpu_pack_wall"]["p50_us"],200)
            self.assertEqual(result["stages"]["codec_input_ack_roundtrip"]["max_us"],1000)
            self.assertIsNone(result["stages"]["raw_queue_wait"])
            self.assertIsNone(result["application_diagnostic_monitor"])
            (path / "probe.log").write_text("ENGINE_MONITOR_TIMING mode=incremental polls=2 bytes=100 total_us=30 max_us=20 draws=3 draw_span_us=40000 draw_max_us=20000\n")
            monitor=report(path)["application_diagnostic_monitor"]
            self.assertEqual(monitor["bytes_read"],100)
            self.assertEqual(monitor["mode"],"incremental")
            (path / "monado-stereo.jsonl").write_text('{"display_time_ns":1}\n'*2)
            with self.assertRaises(ValueError): report(path)


if __name__=="__main__": unittest.main()
