#!/usr/bin/env python3
"""Export the reviewed public file list into a NEW directory; no Git/network writes."""
import argparse
from pathlib import Path
import sys
from release_tools import export_tree, public_paths

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
try:
    result = export_tree(root, args.destination)
except (ValueError, OSError) as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
print(f"Exported {len(public_paths(root))} reviewed files to {result}")
