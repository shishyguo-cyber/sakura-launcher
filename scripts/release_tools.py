"""Review an explicit public file list and export it without private workspace data."""
from pathlib import Path, PurePosixPath
import os
import re
import shutil
import tempfile
from urllib.parse import unquote, urlsplit


GENERATED = {".git", ".build", "build", "bin", "obj", "__pycache__"}
PRIVATE = {".agents", ".collab", ".superpowers", "assets", "handoff", "node_modules", "checks"}
TEXT = {".md", ".txt", ".py", ".sh", ".command", ".json", ".yml", ".yaml", ".swift", ".cs", ".csproj", ".slnx", ".ps1", ".xaml", ".plist", ".manifest"}
CREDENTIAL = re.compile(r"(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN (?:OPENSSH|RSA|EC|DSA) PRIVATE KEY-----)")
PERSONAL = re.compile(r"/Users/[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\")
LINK = re.compile(r"!?\[[^\]\n]*\]\((<[^>]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\)")


def public_paths(root):
    root = Path(root)
    manifest = root / "public-files.txt"
    if manifest.is_symlink() or not manifest.is_file():
        raise ValueError("missing or linked public-files.txt")
    paths = []
    for line in manifest.read_text(encoding="utf-8").splitlines():
        name = line.strip()
        if not name or name.startswith("#"):
            continue
        p = PurePosixPath(name)
        if p.is_absolute() or ".." in p.parts or "\\" in name or ":" in name or str(p) != name:
            raise ValueError("unsafe manifest path")
        if set(p.parts) & (PRIVATE | GENERATED) or "remote.local.env" in name or name.endswith("/remote.sh") or "superpowers" in p.parts or re.search(r"P-\d+-plan\.md$", name):
            raise ValueError("private/generated path in public list: " + name)
        if p.suffix.lower() in {".mp4", ".mov", ".wav", ".mp3", ".blend", ".zip"} and name not in {"launcher-macos/demo-pack/intro.mp4", "launcher-macos/demo-pack/loop.mp4", "launcher-macos/demo-pack/outro.mp4"}:
            raise ValueError("unapproved media path: " + name)
        if name in paths:
            raise ValueError("duplicate manifest path: " + name)
        paths.append(name)
    if not {"README.md", "LICENSE", "public-files.txt"}.issubset(paths):
        raise ValueError("public list must include README.md, LICENSE and itself")
    return paths


def checked_file(root, name):
    p = root
    for part in PurePosixPath(name).parts:
        p = p / part
        if p.is_symlink():
            raise ValueError("symlink in public path: " + name)
    if not p.is_file():
        raise ValueError("missing public file: " + name)
    if getattr(p.stat(), "st_flags", 0) & 0x40000000:
        raise ValueError("public source is a cloud placeholder: " + name)
    return p


def validate_tree(root, strict=False):
    root = Path(root).resolve()
    try:
        paths = public_paths(root)
    except (ValueError, OSError) as e:
        return [str(e)]
    findings = []
    published = set(paths)
    for name in paths:
        try:
            p = checked_file(root, name)
        except ValueError as e:
            findings.append(str(e))
            continue
        if p.suffix.lower() not in TEXT and p.name not in {"LICENSE", ".gitignore"}:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeError, OSError):
            findings.append(name + ": unreadable public text")
            continue
        if CREDENTIAL.search(text):
            findings.append(name + ": possible credential; value withheld")
        if PERSONAL.search(text.replace("\\\\", "\\")):
            findings.append(name + ": personal path")
        if p.suffix.lower() == ".md":
            for match in LINK.finditer(text):
                value = match.group(1).strip("<>")
                url = urlsplit(value)
                if value.startswith("#") or url.scheme in {"https", "http", "mailto"}:
                    continue
                target = (p.parent / unquote(url.path)).resolve()
                if url.scheme or not target.is_relative_to(root) or str(target.relative_to(root)).replace(os.sep, "/") not in published:
                    findings.append(name + ": local link outside public list")
    if strict:
        for directory, dirs, names in os.walk(root, followlinks=False):
            dirs[:] = [x for x in dirs if x not in GENERATED]
            for n in names:
                p = Path(directory) / n
                rel = p.relative_to(root).as_posix()
                if n in {".DS_Store", ".git"}:
                    continue
                if rel not in published:
                    findings.append(rel + ": unlisted file")
            for n in dirs:
                if (Path(directory) / n).is_symlink():
                    findings.append((Path(directory) / n).relative_to(root).as_posix() + ": unlisted symlink")
    return findings


def export_tree(root, destination):
    root = Path(root).resolve()
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("output already exists; choose a new directory")
    if destination.resolve().is_relative_to(root):
        raise ValueError("output must be outside source tree")
    findings = validate_tree(root)
    if findings:
        raise ValueError("\n".join(findings))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sakura-export-", dir=destination.parent) as temporary:
        stage = Path(temporary) / "public"
        stage.mkdir()
        for name in public_paths(root):
            src = checked_file(root, name)
            dst = stage / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
            dst.chmod(0o755 if src.stat().st_mode & 0o111 else 0o644)
        problems = validate_tree(stage, strict=True)
        if problems:
            raise ValueError("\n".join(problems))
        if destination.exists() or destination.is_symlink():
            raise ValueError("output appeared during export; left untouched")
        stage.rename(destination)
    return destination
