"""Release packaging helpers: clean ZIPs, payload scanning, checksums and public-repository sync.

Everything here works on local files only. Nothing creates repositories, commits, pushes or uploads.
"""
from pathlib import Path, PurePosixPath
import hashlib
import os
import re
import shutil
import stat
import zipfile

# Fixed timestamp so the same input files always produce byte-identical archives (reproducible checksums).
ZIP_TIME = (2026, 1, 1, 0, 0, 0)
SKIPPED_NAMES = {".DS_Store", "Thumbs.db", "desktop.ini"}
SKIPPED_SUFFIXES = {".pdb"}
FORBIDDEN_PARTS = {"__MACOSX", ".git", ".collab", ".DS_Store"}

# Patterns that must never appear in anything we ship. ASCII and UTF-16 (Windows binaries store strings as UTF-16).
_PATH_PATTERNS = [
    ("macos-user-path", rb"/Users/[A-Za-z0-9_.-]+/"),
    ("linux-home-path", rb"/home/[A-Za-z0-9_.-]+/"),
    ("windows-user-path", rb"[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\"),
]
PAYLOAD_PATTERNS = [(label, re.compile(expression)) for label, expression in _PATH_PATTERNS] + [
    (label + "-utf16", re.compile(re.escape(prefix.encode("utf-16-le"))))
    for label, prefix in [("macos-user-path", "/Users/"), ("linux-home-path", "/home/"), ("windows-user-path", ":\\Users\\")]
] + [
    ("private-key", re.compile(rb"-----BEGIN (?:RSA |OPENSSH |EC |DSA |ENCRYPTED )?PRIVATE KEY-----")),
    ("private-key-utf16", re.compile(rb"-\x00-\x00-\x00-\x00-\x00B\x00E\x00G\x00I\x00N\x00 .*?P\x00R\x00I\x00V\x00A\x00T\x00E\x00 \x00K\x00E\x00Y\x00")),
    ("token", re.compile(rb"(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,})")),
]


# .NET 10.0.15 win-x64: an ASCII culture-name table in Microsoft's unmodified CoreLib
# contains a token-shaped substring. Verified against Microsoft.NETCore.App.Runtime.win-x64
# 10.0.15 from NuGet. Exempt only that match in that exact file; all other scans still run.
# A service update, rename, added credential, or any byte change requires fresh verification.
REVIEWED_VENDOR_TOKEN_MATCHES = {
    ("System.Private.CoreLib.dll", "983f5c8957437aa38fcd239606e60dc2a4a6f551605311591a72e5b285eae957"):
        {"2c824f99075a502f2a79a83bc9142a77d094f6cd3c797d6d30490ee5392f89d6"},
}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _skip(relative):
    parts = PurePosixPath(relative).parts
    return (any(p in SKIPPED_NAMES or p.startswith("._") for p in parts)
            or PurePosixPath(relative).suffix.lower() in SKIPPED_SUFFIXES)


def tree_entries(root, prefix):
    """(source file, archive name) for every shippable file under root, sorted; refuses symlinks."""
    root = Path(root)
    if not root.is_dir():
        raise ValueError(f"not a folder: {root}")
    entries = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        for name in dirs:
            if (Path(directory) / name).is_symlink():
                raise ValueError(f"symlink not allowed in a release: {Path(directory) / name}")
        for name in sorted(files):
            p = Path(directory) / name
            relative = p.relative_to(root).as_posix()
            if p.is_symlink():
                raise ValueError(f"symlink not allowed in a release: {p}")
            if _skip(relative):
                continue
            entries.append((p, f"{prefix}/{relative}" if prefix else relative))
    return entries


def write_zip(destination, entries, extra=()):
    """Write a clean, reproducible ZIP.

    entries: (source path, archive name) pairs; executable bits are kept.
    extra: (archive name, bytes) pairs for generated files such as instructions.
    Names use "/" and are flagged UTF-8 when not ASCII (Python does this); no AppleDouble or Finder metadata.
    """
    destination = Path(destination)
    if destination.exists():
        raise ValueError(f"refusing to overwrite {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    seen = set()
    temporary = destination.with_name(destination.name + ".partial")
    try:
        with zipfile.ZipFile(temporary, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            items = [(name, source, None) for source, name in entries] + [(name, None, data) for name, data in extra]
            for name, source, data in sorted(items, key=lambda item: item[0]):
                if name in seen:
                    raise ValueError(f"duplicate archive entry: {name}")
                seen.add(name)
                info = zipfile.ZipInfo(name, ZIP_TIME)
                info.compress_type = zipfile.ZIP_DEFLATED
                if source is not None:
                    mode = 0o755 if Path(source).stat().st_mode & stat.S_IXUSR else 0o644
                    data = Path(source).read_bytes()
                else:
                    mode = 0o644
                info.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(info, data)
        temporary.replace(destination)
    finally:
        if temporary.exists():
            temporary.unlink()
    return destination


def scan_archive(path):
    """Problems in a finished ZIP: unsafe or metadata entries, non-UTF-8 names, personal paths, keys, tokens."""
    findings = []
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad:
            findings.append({"entry": bad, "problem": "crc"})
        names = archive.namelist()
        if len(names) != len(set(names)):
            findings.append({"entry": "", "problem": "duplicate entries"})
        for info in archive.infolist():
            name = info.filename
            # On Windows, zipfile rewrites "\\" to "/" when reading; the stored name keeps what other tools will see.
            stored = info.orig_filename
            parts = PurePosixPath(name).parts
            if stored.startswith("/") or "\\" in stored or ".." in parts:
                findings.append({"entry": name, "problem": "unsafe path"})
            if any(p in FORBIDDEN_PARTS or p.startswith("._") for p in parts):
                findings.append({"entry": name, "problem": "metadata or private entry"})
            if any(ord(c) > 127 for c in name) and not info.flag_bits & 0x800:
                findings.append({"entry": name, "problem": "non-UTF-8 file name"})
            if name.endswith("/"):
                continue
            data = archive.read(name)
            for label, expression in PAYLOAD_PATTERNS:
                count = len(expression.findall(data))
                if count and label == "token":
                    reviewed = REVIEWED_VENDOR_TOKEN_MATCHES.get((PurePosixPath(name).name, hashlib.sha256(data).hexdigest()), set())
                    if reviewed:
                        count = sum(hashlib.sha256(m.group()).hexdigest() not in reviewed for m in expression.finditer(data))
                if count:
                    findings.append({"entry": name, "problem": label, "count": count})
    return findings


def checksums_text(paths):
    return "".join(f"{sha256(p)}  {Path(p).name}\n" for p in sorted(paths, key=lambda p: Path(p).name))


def windows_text(text):
    """UTF-8 with BOM and CRLF, so every Notepad version shows Chinese instructions correctly."""
    return b"\xef\xbb\xbf" + text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8")


# ---------- Public repository sync ----------

def sync_plan(exported, repository):
    """Compare an exported public tree with a public repository working tree (its .git is ignored)."""
    exported, repository = Path(exported), Path(repository)
    wanted = {p.relative_to(exported).as_posix(): p for p in exported.rglob("*") if p.is_file()}
    present = {}
    for directory, dirs, files in os.walk(repository, followlinks=False):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            p = Path(directory) / name
            present[p.relative_to(repository).as_posix()] = p
    added = sorted(set(wanted) - set(present))
    removed = sorted(set(present) - set(wanted))
    changed = sorted(n for n in set(wanted) & set(present)
                     if wanted[n].read_bytes() != present[n].read_bytes()
                     or bool(wanted[n].stat().st_mode & stat.S_IXUSR) != bool(present[n].stat().st_mode & stat.S_IXUSR))
    return {"added": added, "changed": changed, "removed": removed}


def apply_sync(exported, repository, plan):
    """Make the repository tree mirror the export exactly. Never touches .git; never runs git."""
    exported, repository = Path(exported), Path(repository)
    if not (repository / ".git").exists():
        raise ValueError(f"not a Git working tree: {repository}")
    for name in plan["removed"]:
        target = repository / name
        if ".git" in PurePosixPath(name).parts:
            raise ValueError(f"refusing to touch {name}")
        target.unlink()
        parent = target.parent
        while parent != repository and not any(parent.iterdir()):
            parent.rmdir()
            parent = parent.parent
    for name in plan["added"] + plan["changed"]:
        source, target = exported / name, repository / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o755 if source.stat().st_mode & stat.S_IXUSR else 0o644)
