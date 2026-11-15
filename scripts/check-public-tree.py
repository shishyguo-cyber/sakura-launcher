#!/usr/bin/env python3
"""Check reviewed file scope, local links and common disclosure indicators."""
import argparse
from pathlib import Path
import sys
from release_tools import public_paths, validate_tree

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--strict", action="store_true", help="also reject files outside the public list")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
findings = validate_tree(root, strict=args.strict)
if findings:
    print("\n".join(findings), file=sys.stderr)
    sys.exit(1)
print(f"Public scope and links checked: {len(public_paths(root))} files. Pattern checks are not a full security/legal audit.")
