"""Regression tests for the GUI report's visibility and latency evidence checks."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("check_logic", Path(__file__).resolve().parents[1] / "check-logic.py")
logic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logic)


def sample(warm="true", origin="launch-detected pid=42"):
    return "\n".join([
        f"2026-11-15T00:00:00.000Z {origin}",
        "2026-11-15T00:00:00.010Z overlay-alpha=0.000 phase=prepared",
        f"2026-11-15T00:00:00.120Z first-frame age=0.120 warm={warm} segment=intro",
        "2026-11-15T00:00:00.120Z overlay-alpha=0.000 phase=before-show",
        "2026-11-15T00:00:00.120Z player-show location=launch-screen frame={{0, 0}, {800, 500}}",
        "2026-11-15T00:00:00.130Z overlay-alpha=0.020 phase=fade-in",
    ])


class LaunchLatencyEvidenceTests(unittest.TestCase):
    def test_warm_launch_and_cold_preview_report_seconds(self):
        self.assertEqual(logic.assert_first_frame_before_show(sample(), True)["seconds"], 0.120)
        self.assertFalse(logic.assert_first_frame_before_show(sample("false", "preview-requested"), False)["warm"])

    def test_show_before_first_frame_is_rejected_even_with_equal_timestamps(self):
        lines = sample().splitlines()
        lines[2], lines[4] = lines[4], lines[2]
        with self.assertRaises(AssertionError):
            logic.assert_first_frame_before_show("\n".join(lines))

    def test_visible_alpha_before_show_is_rejected(self):
        with self.assertRaises(AssertionError):
            logic.assert_first_frame_before_show(sample().replace("overlay-alpha=0.000 phase=prepared", "overlay-alpha=1.000 phase=prepared"))

    def test_missing_alpha_or_first_frame_is_rejected(self):
        for token in ("overlay-alpha", "first-frame"):
            text = "\n".join(line for line in sample().splitlines() if token not in line)
            with self.assertRaises(AssertionError):
                logic.assert_first_frame_before_show(text)

    def test_age_must_include_selection_and_preparation(self):
        with self.assertRaises(AssertionError):
            logic.assert_first_frame_before_show(sample().replace("age=0.120", "age=0.020"))

    def test_timestamp_inversion_and_wrong_warm_flag_are_rejected(self):
        with self.assertRaises(AssertionError):
            logic.assert_first_frame_before_show(sample().replace("00.120Z first-frame", "00.121Z first-frame"))
        with self.assertRaises(AssertionError):
            logic.assert_first_frame_before_show(sample(), False)

    def test_missing_geometry_and_malformed_age_are_rejected(self):
        for text in (sample().replace("frame={{0, 0}, {800, 500}}", ""), sample().replace("age=0.120", "age=0.12")):
            with self.assertRaises(AssertionError):
                logic.assert_first_frame_before_show(text)


if __name__ == "__main__":
    unittest.main()
