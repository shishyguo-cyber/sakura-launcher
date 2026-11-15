#!/usr/bin/env python3
"""Fail if private media could leak into the public repository or the built app.

Rules: video files may only live under demo-pack/ (repository) or the bundled
demo pack (app). Any path containing a blocked word fails everywhere.
Usage: check-public-media.py [--app PATH_TO.app]
"""
import argparse
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
VIDEO = {".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi", ".gif"}
BLOCKED = ("raiden", "雷电", "shogun", "genshin", "原神")
SKIP_DIRS = {".build", "build", ".git", "__pycache__", "checks"}


def repo_files():
    """Tracked plus untracked-but-not-ignored files, as git would publish them."""
    try:
        out = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "-z", "--", "."],
                             cwd=PROJECT, check=True, capture_output=True).stdout
        return [PROJECT / p for p in out.decode().split("\0") if p]
    except (OSError, subprocess.CalledProcessError):
        return [p for p in PROJECT.rglob("*")
                if p.is_file() and not SKIP_DIRS.intersection(p.relative_to(PROJECT).parts)]


def problems(files, base, allowed_video_dir):
    found = []
    for path in files:
        rel = path.relative_to(base)
        lowered = str(rel).lower()
        hit = next((w for w in BLOCKED if w in lowered), None)
        if hit:
            found.append(f"{rel}: 路径含受限词 “{hit}”")
        if path.suffix.lower() in VIDEO and allowed_video_dir not in rel.parts:
            found.append(f"{rel}: 视频不在 {allowed_video_dir}/ 内")
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, help="also check a built .app bundle")
    args = parser.parse_args()
    found = problems(repo_files(), PROJECT, "demo-pack")
    if args.app:
        app = args.app.resolve()
        files = [p for p in app.rglob("*") if p.is_file()]
        found += [f"[app] {line}" for line in problems(files, app, "demo-pack")]
    if found:
        print("公开素材检查未通过：", file=sys.stderr)
        for line in found:
            print(f"  - {line}", file=sys.stderr)
        sys.exit(1)
    print("public-media-check passed")


if __name__ == "__main__":
    main()
