import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-originality.py"


class OriginalityCommandTests(unittest.TestCase):
    def test_csharp_scan_reports_coverage_without_reference_snippets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ours, reference = root / "ours", root / "reference"
            ours.mkdir()
            reference.mkdir()
            text = "public sealed class SensitiveFixtureMarker { public int Calculate(int a, int b) { return a * 23 + b / 7; } }\n"
            (ours / "Fixture.cs").write_text(text)
            (reference / "Other.cs").write_text(text)
            ignored = ours / "obj"
            ignored.mkdir()
            (ignored / "Generated.cs").write_text(text)
            report = root / "report.json"
            run = subprocess.run([sys.executable, str(SCRIPT), str(reference), "--ours", str(ours),
                                  "--summary-only", "--report", str(report)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0)
            self.assertTrue(report.exists(), "machine-readable scan report was not produced")
            data = json.loads(report.read_text())
            self.assertEqual([row["file"] for row in data["files"]], ["Fixture.cs"])
            self.assertEqual(data["files"][0]["sharedCoveragePercent"], 100)
            self.assertNotIn("SensitiveFixtureMarker", run.stdout)
            self.assertNotIn("SensitiveFixtureMarker", report.read_text())

    def test_missing_reference_is_an_error_instead_of_a_clean_scan(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = subprocess.run([sys.executable, str(SCRIPT), str(Path(temporary) / "missing")],
                                 capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0, "missing reference must not report a successful scan")


if __name__ == "__main__":
    unittest.main()
