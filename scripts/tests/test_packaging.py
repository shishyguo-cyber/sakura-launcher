import hashlib
import importlib.util
import os
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "package_tools.py"
# Built by concatenation so this test file itself never contains a real-looking personal path.
HOME_MAC = "/Us" + "ers/someone/project/a.swift"
HOME_WIN = "C:" + "\\Us" + "ers\\someone\\obj\\a.pdb"
# Windows file systems have no executable bit; those assertions only apply where packages are built (macOS/Linux).
POSIX = os.name != "nt"


class PackagingTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("package_tools", MODULE)
        self.tools = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.tools)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def tree(self, name, files):
        root = self.base / name
        for relative, content in files.items():
            p = root / relative
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(content if isinstance(content, bytes) else content.encode())
        return root

    def test_zip_skips_metadata_keeps_exec_bit_and_utf8_names(self):
        root = self.tree("app", {"Contents/MacOS/Tool": "binary", "Contents/._Tool": "x", ".DS_Store": "x",
                                 "Contents/Resources/a.pdb": "x", "Contents/Resources/说明.txt": "hi"})
        (root / "Contents/MacOS/Tool").chmod(0o755)
        out = self.tools.write_zip(self.base / "a.zip", self.tools.tree_entries(root, "Pkg/App.app"),
                                   [("Pkg/使用说明.txt", "说明".encode())])
        with zipfile.ZipFile(out) as z:
            names = z.namelist()
            self.assertEqual(sorted(names), ["Pkg/App.app/Contents/MacOS/Tool", "Pkg/App.app/Contents/Resources/说明.txt",
                                             "Pkg/使用说明.txt"])
            tool = z.getinfo("Pkg/App.app/Contents/MacOS/Tool")
            if POSIX:
                self.assertTrue((tool.external_attr >> 16) & stat.S_IXUSR)
            self.assertTrue(z.getinfo("Pkg/使用说明.txt").flag_bits & 0x800)
        self.assertEqual(self.tools.scan_archive(out), [])

    def test_zip_is_reproducible_and_refuses_overwrite(self):
        root = self.tree("src", {"a.txt": "a", "b/c.txt": "c"})
        first = self.tools.write_zip(self.base / "1.zip", self.tools.tree_entries(root, "S"))
        os.utime(root / "a.txt", (0, 0))
        second = self.tools.write_zip(self.base / "2.zip", self.tools.tree_entries(root, "S"))
        self.assertEqual(self.tools.sha256(first), self.tools.sha256(second))
        with self.assertRaises(ValueError):
            self.tools.write_zip(first, self.tools.tree_entries(root, "S"))

    def test_symlink_is_refused(self):
        root = self.tree("src", {"a.txt": "a"})
        (root / "link").symlink_to(root / "a.txt")
        with self.assertRaises(ValueError):
            self.tools.tree_entries(root, "S")

    def test_scan_finds_personal_paths_in_ascii_and_utf16_and_keys(self):
        root = self.tree("bin", {"a.dll": b"\0" + HOME_WIN.encode("utf-16-le") + b"\0",
                                 "b": HOME_MAC.encode(),
                                 "c": ("-----BEGIN OPENSSH " + "PRIVATE KEY-----").encode()})
        out = self.tools.write_zip(self.base / "p.zip", self.tools.tree_entries(root, "P"))
        problems = {(f["entry"], f["problem"]) for f in self.tools.scan_archive(out)}
        self.assertIn(("P/a.dll", "windows-user-path-utf16"), problems)
        self.assertIn(("P/b", "macos-user-path"), problems)
        self.assertIn(("P/c", "private-key"), problems)

    def test_scan_flags_finder_metadata_and_backslashes(self):
        bad = self.base / "bad.zip"
        with zipfile.ZipFile(bad, "w") as z:
            z.writestr("__MACOSX/._x", "x")
            # ZipInfo turns os.sep into "/" on Windows; set the raw name afterwards so the bad sample stays bad.
            info = zipfile.ZipInfo("placeholder")
            info.filename = "Sakura\\README.txt"
            z.writestr(info, "x")
        problems = {f["problem"] for f in self.tools.scan_archive(bad)}
        self.assertEqual(problems, {"metadata or private entry", "unsafe path"})

    def test_token_looking_culture_data_is_not_generically_exempted(self):
        data = b"culture-table-" + b"sk" + b"-" + b"language" * 8
        out = self.tools.write_zip(self.base / "unreviewed.zip", [], [("Sakura/System.Private.CoreLib.dll", data)])
        self.assertEqual([f["problem"] for f in self.tools.scan_archive(out)], ["token"])

    def test_reviewed_vendor_exception_requires_file_name_file_hash_and_match_hash(self):
        data = b"culture-table-" + b"sk" + b"-" + b"language" * 8
        match = next(p for label, p in self.tools.PAYLOAD_PATTERNS if label == "token").search(data).group()
        key = ("System.Private.CoreLib.dll", hashlib.sha256(data).hexdigest())
        reviewed = {key: {hashlib.sha256(match).hexdigest()}}
        secret = b"sk" + b"-" + b"secret" * 8
        cases = [("known", "System.Private.CoreLib.dll", data, False),
                 ("renamed", "App.dll", data, True),
                 ("modified", "System.Private.CoreLib.dll", data + b"\0" + secret, True)]
        with patch.object(self.tools, "REVIEWED_VENDOR_TOKEN_MATCHES", reviewed, create=True):
            for name, file_name, content, flagged in cases:
                out = self.tools.write_zip(self.base / (name + ".zip"), [], [("Sakura/" + file_name, content)])
                self.assertEqual(any(f["problem"] == "token" for f in self.tools.scan_archive(out)), flagged, name)
        with patch.object(self.tools, "REVIEWED_VENDOR_TOKEN_MATCHES", {key: {"wrong-match-hash"}}, create=True):
            out = self.tools.write_zip(self.base / "wrong-match.zip", [], [("Sakura/System.Private.CoreLib.dll", data)])
            self.assertTrue(any(f["problem"] == "token" for f in self.tools.scan_archive(out)))

    def test_vendor_token_exception_keeps_path_and_private_key_scans(self):
        data = b"sk" + b"-" + b"language" * 8 + b"\0" + HOME_WIN.encode() + b"\0" + ("-----BEGIN OPENSSH " + "PRIVATE KEY-----").encode()
        match = next(p for label, p in self.tools.PAYLOAD_PATTERNS if label == "token").search(data).group()
        reviewed = {("System.Private.CoreLib.dll", hashlib.sha256(data).hexdigest()): {hashlib.sha256(match).hexdigest()}}
        with patch.object(self.tools, "REVIEWED_VENDOR_TOKEN_MATCHES", reviewed, create=True):
            out = self.tools.write_zip(self.base / "other-findings.zip", [], [("Sakura/System.Private.CoreLib.dll", data)])
            self.assertEqual({f["problem"] for f in self.tools.scan_archive(out)}, {"windows-user-path", "private-key"})

    def test_checksums_and_windows_text(self):
        a = self.base / "a.zip"; a.write_bytes(b"a")
        self.assertEqual(self.tools.checksums_text([a]),
                         "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb  a.zip\n")
        self.assertEqual(self.tools.windows_text("一\n二\n"), b"\xef\xbb\xbf" + "一\r\n二\r\n".encode())

    def test_sync_plan_and_apply_mirror_exactly_without_touching_git(self):
        exported = self.tree("export", {"README.md": "new", "docs/a.md": "a", "run.sh": "#!/bin/sh\n"})
        (exported / "run.sh").chmod(0o755)
        repo = self.tree("repo", {"README.md": "old", "old/gone.md": "x", ".git/HEAD": "ref", "run.sh": "#!/bin/sh\n"})
        plan = self.tools.sync_plan(exported, repo)
        changed = ["README.md", "run.sh"] if POSIX else ["README.md"]
        self.assertEqual(plan, {"added": ["docs/a.md"], "changed": changed, "removed": ["old/gone.md"]})
        self.tools.apply_sync(exported, repo, plan)
        self.assertEqual(self.tools.sync_plan(exported, repo), {"added": [], "changed": [], "removed": []})
        self.assertFalse((repo / "old").exists())
        self.assertEqual((repo / ".git/HEAD").read_text(), "ref")
        if POSIX:
            self.assertTrue((repo / "run.sh").stat().st_mode & stat.S_IXUSR)

    def test_apply_refuses_a_folder_that_is_not_a_repository(self):
        exported = self.tree("export", {"a": "a"})
        plain = self.tree("plain", {"b": "b"})
        with self.assertRaises(ValueError):
            self.tools.apply_sync(exported, plain, self.tools.sync_plan(exported, plain))


if __name__ == "__main__":
    unittest.main()
