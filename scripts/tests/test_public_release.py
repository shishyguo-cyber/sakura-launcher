import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1] / "release_tools.py"


class PublicReleaseTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.is_file(), "release_tools.py must implement safe public export")
        spec = importlib.util.spec_from_file_location("release_tools", MODULE)
        self.tools = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.tools)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "source"
        self.root.mkdir()
        self.paths = ["public-files.txt", "README.md", "LICENSE"]
        (self.root / "README.md").write_text("# Sakura\n")
        (self.root / "LICENSE").write_text("MIT License\n")
        self.manifest()

    def manifest(self):
        (self.root / "public-files.txt").write_text("\n".join(self.paths) + "\n")

    def add(self, name, text):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        self.paths.append(name)
        self.manifest()

    def test_export_copies_only_reviewed_files_and_preserves_executable_mode(self):
        self.add("scripts/run.sh", "#!/bin/sh\nexit 0\n")
        (self.root / "scripts/run.sh").chmod(0o755)
        (self.root / "private-notes.md").write_text("do not export")
        destination = self.base / "public"
        self.tools.export_tree(self.root, destination)
        self.assertEqual((destination / "scripts/run.sh").read_bytes(), (self.root / "scripts/run.sh").read_bytes())
        if os.name != "nt":
            self.assertTrue((destination / "scripts/run.sh").stat().st_mode & 0o100)
        self.assertFalse((destination / "private-notes.md").exists())
        self.assertEqual(self.tools.validate_tree(destination, strict=True), [])

    def test_existing_output_is_never_overwritten(self):
        destination = self.base / "public"
        destination.mkdir()
        (destination / "keep.txt").write_text("important")
        with self.assertRaises(ValueError):
            self.tools.export_tree(self.root, destination)
        self.assertEqual((destination / "keep.txt").read_text(), "important")

    def test_rejects_parent_traversal(self):
        self.paths.append("../outside.txt")
        self.manifest()
        with self.assertRaises(ValueError):
            self.tools.export_tree(self.root, self.base / "public")
        self.assertFalse((self.base / "public").exists())

    def test_rejects_absolute_and_windows_paths(self):
        for path in ["/etc/passwd", "C:\\private.txt", "C:/private.txt"]:
            with self.subTest(path=path):
                self.paths = ["public-files.txt", "README.md", "LICENSE", path]
                self.manifest()
                with self.assertRaises(ValueError):
                    self.tools.export_tree(self.root, self.base / "public")

    def test_rejects_private_files_even_if_in_manifest(self):
        for path in [".collab/notes.md", "assets/character.png", "launcher-windows/scripts/remote.local.env", "launcher-macos/checks/events.log"]:
            with self.subTest(path=path):
                self.paths = ["public-files.txt", "README.md", "LICENSE", path]
                self.manifest()
                with self.assertRaises(ValueError):
                    self.tools.export_tree(self.root, self.base / "public")

    def test_rejects_file_and_parent_directory_symlinks(self):
        external = self.base / "external"
        external.mkdir()
        (external / "document.md").write_text("private")
        for directory_link in [False, True]:
            with self.subTest(directory_link=directory_link):
                name = "linked/document.md" if directory_link else "linked.md"
                link = self.root / ("linked" if directory_link else "linked.md")
                try:
                    link.symlink_to(external if directory_link else external / "document.md", target_is_directory=directory_link)
                except OSError as error:
                    if getattr(error, "winerror", None) == 1314:
                        self.skipTest("Windows requires symbolic-link privilege for this case")
                    raise
                self.paths = ["public-files.txt", "README.md", "LICENSE", name]
                self.manifest()
                with self.assertRaises(ValueError):
                    self.tools.export_tree(self.root, self.base / "public")
                link.unlink()

    def test_missing_source_does_not_leave_partial_output(self):
        self.paths.append("missing.md")
        self.manifest()
        with self.assertRaises(ValueError):
            self.tools.export_tree(self.root, self.base / "public")
        self.assertFalse((self.base / "public").exists())
        self.assertFalse(list(self.base.glob(".sakura-export-*")))

    def test_duplicate_manifest_entry_is_rejected(self):
        self.paths.append("README.md")
        self.manifest()
        with self.assertRaises(ValueError):
            self.tools.export_tree(self.root, self.base / "public")

    def test_sensitive_findings_never_print_the_secret(self):
        token = "ghp_" + "A" * 40
        self.add("config.txt", token)
        findings = self.tools.validate_tree(self.root)
        self.assertTrue(any("credential" in x for x in findings))
        self.assertNotIn(token, "\n".join(findings))

    def test_personal_paths_are_flagged(self):
        self.add("config.txt", "/" + "Users/alice/private/file\n" + "C:" + "\\Users\\alice\\private")
        self.assertTrue(any("personal path" in x for x in self.tools.validate_tree(self.root)))

    def test_links_to_unpublished_documents_are_rejected(self):
        (self.root / "private.md").write_text("private")
        (self.root / "README.md").write_text("[internal](private.md)\n")
        self.assertTrue(any("link" in x for x in self.tools.validate_tree(self.root)))

    def test_public_local_links_with_spaces_and_external_links_work(self):
        self.add("docs/user guide.md", "# Guide\n")
        (self.root / "README.md").write_text("[guide](<docs/user guide.md>)\n[site](https://example.com)\n[section](#section)\n")
        self.assertEqual(self.tools.validate_tree(self.root), [])

    def test_strict_validation_rejects_unlisted_files(self):
        (self.root / "unexpected.txt").write_text("unreviewed")
        self.assertTrue(any("unlisted" in x for x in self.tools.validate_tree(self.root, strict=True)))

    def test_export_inside_source_is_rejected(self):
        with self.assertRaises(ValueError):
            self.tools.export_tree(self.root, self.root / "public")


if __name__ == "__main__":
    unittest.main()
