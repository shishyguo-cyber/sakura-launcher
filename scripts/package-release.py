#!/usr/bin/env python3
"""Assemble a Sakura release folder from already prepared, debug-free app builds.

  python3 scripts/package-release.py --version 0.2.0-preview.4 \
      --mac-app <Sakura.app from launcher-macos/scripts/package.sh> \
      --windows-dir <folder from launcher-windows/scripts/publish-release.ps1> \
      --out <new folder>

Writes three ZIPs (macOS, Windows x64, source), SHA256SUMS.txt and inventory.json, then scans every file inside
every ZIP for personal paths, keys and tokens. Any finding aborts and leaves no release folder behind.
It never uploads, tags or publishes anything.
"""
import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_tools import checksums_text, scan_archive, sha256, tree_entries, windows_text, write_zip  # noqa: E402
from release_tools import export_tree  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "docs/release"


def mac_checks(app):
    """Signature and architectures, when running on a Mac (skipped elsewhere)."""
    if shutil.which("codesign") is None:
        return {"skipped": "not on macOS"}
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    archs = subprocess.run(["lipo", "-archs", str(app / "Contents/MacOS/GardenBoot")],
                           check=True, capture_output=True, text=True).stdout.split()
    return {"signature": "ad-hoc, verified", "architectures": sorted(archs)}


def declared_versions(mac_app):
    """The release version each artifact declares; all must equal --version or update checks would misjudge."""
    found = {}
    plist = mac_app / "Contents/Info.plist"
    found["mac app SakuraReleaseVersion"] = plistlib.loads(plist.read_bytes()).get("SakuraReleaseVersion")
    found["Info.plist SakuraReleaseVersion"] = plistlib.loads(
        (ROOT / "launcher-macos/Resources/Info.plist").read_bytes()).get("SakuraReleaseVersion")
    match = re.search(r"<Version>([^<]+)</Version>", (ROOT / "launcher-windows/GardenBoot.App/GardenBoot.App.csproj").read_text())
    found["GardenBoot.App.csproj Version"] = match.group(1) if match else None
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", required=True)
    parser.add_argument("--mac-app", type=Path, required=True)
    parser.add_argument("--windows-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    version, out = args.version, args.out.absolute()
    if out.exists():
        parser.error(f"{out} already exists; choose a new folder")
    if not (args.mac_app / "Contents/MacOS/GardenBoot").is_file():
        parser.error("--mac-app must be a built Sakura.app")
    if not (args.windows_dir / "Sakura.exe").is_file():
        parser.error("--windows-dir must contain Sakura.exe")
    mismatched = {k: v for k, v in declared_versions(args.mac_app).items() if v != version}
    if mismatched:
        parser.error("version mismatch with --version " + version + ": " + json.dumps(mismatched, ensure_ascii=False))
    if any(args.windows_dir.rglob("*.pdb")):
        parser.error("--windows-dir contains .pdb files; publish with launcher-windows/scripts/publish-release.ps1")

    mac_text = (TEMPLATES / "README-macOS.txt").read_text(encoding="utf-8").replace("{version}", version)
    windows_readme = (TEMPLATES / "README-windows.txt").read_text(encoding="utf-8").replace("{version}", version)

    with tempfile.TemporaryDirectory(prefix=".sakura-release-", dir=out.parent) as temporary:
        stage = Path(temporary) / "release"
        stage.mkdir()
        source_dir = Path(temporary) / f"Sakura-{version}"
        export_tree(ROOT, source_dir)

        packages = {
            f"Sakura-{version}-macOS.zip": (
                tree_entries(args.mac_app, f"Sakura-{version}-macOS/Sakura.app"),
                [(f"Sakura-{version}-macOS/使用说明.txt", mac_text.encode("utf-8"))]),
            f"Sakura-{version}-windows-x64.zip": (
                tree_entries(args.windows_dir, "Sakura"),
                [("Sakura/README.txt", windows_text(windows_readme))]),
            f"Sakura-{version}-source.zip": (tree_entries(source_dir, f"Sakura-{version}"), []),
        }
        findings = {}
        for name, (entries, extra) in packages.items():
            write_zip(stage / name, entries, extra)
            problems = scan_archive(stage / name)
            if problems:
                findings[name] = problems
        if findings:
            print(json.dumps(findings, ensure_ascii=False, indent=2), file=sys.stderr)
            print("ABORTED: the packages above contain things that must not be shipped. Nothing was written.", file=sys.stderr)
            return 1

        zips = sorted(stage.glob("*.zip"))
        (stage / "SHA256SUMS.txt").write_text(checksums_text(zips), encoding="utf-8")
        inventory = {
            "version": version,
            "packages": {z.name: {"bytes": z.stat().st_size, "sha256": sha256(z)} for z in zips},
            "macOS": mac_checks(args.mac_app),
            "source": [{"path": p.relative_to(source_dir).as_posix(), "bytes": p.stat().st_size, "sha256": sha256(p)}
                       for p, _ in tree_entries(source_dir, "")],
            "scan": "every file in every ZIP: personal paths (ASCII and UTF-16), private keys, tokens; none found",
        }
        (stage / "inventory.json").write_text(json.dumps(inventory, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        stage.rename(out)
    print(f"Release folder: {out}")
    for z in zips:
        print(f"  {z.name}  {(out / z.name).stat().st_size:,} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
