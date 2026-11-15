#!/usr/bin/env python3
"""Report token overlap and matching locations, never reference source snippets.

A local investigation aid, not a certificate of originality. Positional usage scans
macOS sources; --ours enables the same check for Windows C# sources.
"""
import argparse
import difflib
import json
import os
from pathlib import Path
import re

EXT = {'.swift', '.py', '.sh', '.cs'}
SKIP = {'.git', '.build', 'build', 'dist', 'bin', 'obj', 'checks', 'node_modules', '__pycache__', '.collab'}
K = 12


def files(root):
    for directory, directories, names in os.walk(root):
        directories[:] = sorted(d for d in directories if d not in SKIP)
        for name in sorted(names):
            path = Path(directory) / name
            if path.suffix in EXT:
                yield path


def norm(line):
    line = re.sub(r'//.*$|#.*$', '', line).strip()
    return re.sub(r'\s+', ' ', line)


def toks(text):
    text = re.sub(r'//[^\n]*|/\*.*?\*/', ' ', text, flags=re.S)
    return re.findall(r'[A-Za-z_][A-Za-z0-9_]*|\d+(?:\.\d+)?|\S', text)


def scan(ours_root, reference_root):
    reference_lines = []
    shingles = set()
    for path in files(reference_root):
        text = path.read_text(errors='ignore')
        lines = {}
        for number, line in enumerate(text.splitlines(), 1):
            normalized = norm(line)
            if len(normalized) >= 28:
                lines.setdefault(normalized, number)
        reference_lines.append((str(path.relative_to(reference_root)), lines))
        tokens = toks(text)
        shingles.update(tuple(tokens[i:i+K]) for i in range(len(tokens) - K + 1))
    result = []
    for path in files(ours_root):
        text = path.read_text(errors='ignore')
        tokens = toks(text)
        covered = set()
        for i in range(len(tokens) - K + 1):
            if tuple(tokens[i:i+K]) in shingles:
                covered.update(range(i, i + K))
        locations = []
        for number, line in enumerate(text.splitlines(), 1):
            normalized = norm(line)
            if len(normalized) < 28:
                continue
            for reference_file, lines in reference_lines:
                match = difflib.get_close_matches(normalized, lines, n=1, cutoff=0.82)
                if match:
                    locations.append({'line': number, 'referenceFile': reference_file,
                                      'referenceLine': lines[match[0]]})
                    break
        result.append({'file': str(path.relative_to(ours_root)), 'tokens': len(tokens),
                       'sharedCoveragePercent': round(100 * len(covered) / max(1, len(tokens)), 2),
                       'similarLocations': locations})
    return {'method': '12-token-overlap-and-normalized-line-locations', 'files': result,
            'referenceFiles': len(reference_lines), 'sourceSnippetsIncluded': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('--ours', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--summary-only', action='store_true', help='Hide matching line locations too')
    parser.add_argument('--report', type=Path, help='Write JSON statistics and locations (no source text)')
    args = parser.parse_args()
    for root in (args.reference, args.ours):
        if not root.is_dir():
            parser.error(f'Source directory does not exist: {root}')
    report = scan(args.ours, args.reference)
    if not report['referenceFiles']:
        parser.error('Reference directory has no supported source files')
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    for row in report['files']:
        print(f"## {row['file']} tokens={row['tokens']} shared-12gram-coverage={row['sharedCoveragePercent']:.2f}% similar-lines={len(row['similarLocations'])}")
        if not args.summary_only:
            for location in row['similarLocations'][:40]:
                print(f"  L{location['line']} ~ {location['referenceFile']}:L{location['referenceLine']}")


if __name__ == '__main__':
    main()
