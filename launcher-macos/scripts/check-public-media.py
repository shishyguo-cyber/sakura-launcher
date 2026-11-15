#!/usr/bin/env python3
"""Fail if private media could leak into the public repository or the built app.

Rules: video files may only live under the bundled pack folders (demo-pack/, featured-pack/) in the repository
or the app. Any path containing a blocked word fails everywhere; the featured pack keeps a neutral folder name,
and its rights were confirmed by the project owner (docs/MEDIA.md).
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


ALLOWED_VIDEO_DIRS = ("demo-pack", "featured-pack")


def problems(files, base, allowed_video_dirs=ALLOWED_VIDEO_DIRS):
    found = []
    for path in files:
        rel = path.relative_to(base)
        lowered = str(rel).lower()
        hit = next((w for w in BLOCKED if w in lowered), None)
        if hit:
            found.append(f"{rel}: 路径含受限词 “{hit}”")
        if path.suffix.lower() in VIDEO and not set(allowed_video_dirs) & set(rel.parts):
            found.append(f"{rel}: 视频不在 {'/、'.join(allowed_video_dirs)}/ 内")
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, help="also check a built .app bundle")
    args = parser.parse_args()
    found = problems(repo_files(), PROJECT)
    if args.app:
        app = args.app.resolve()
        files = [p for p in app.rglob("*") if p.is_file()]
        found += [f"[app] {line}" for line in problems(files, app)]
    if found:
        print("公开素材检查未通过：", file=sys.stderr)
        for line in found:
            print(f"  - {line}", file=sys.stderr)
        sys.exit(1)
    print("public-media-check passed")


if __name__ == "__main__":
    main()
