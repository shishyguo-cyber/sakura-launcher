#!/usr/bin/env python3
"""Bring a separate public repository's working tree up to date with this project's reviewed public files.

  python3 scripts/sync-public.py <public repository folder>           # show what would change
  python3 scripts/sync-public.py <public repository folder> --apply   # make it mirror the export

The public repository keeps its own clean history; this project's history, logs and private material never go
there. The script exports public-files.txt into a temporary folder, runs the strict scope check, then compares
or mirrors (added, changed, removed; executable bits included). It never runs git: review `git status` and
`git diff` in the public repository, then commit and push yourself.
"""
import argparse
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_tools import apply_sync, sync_plan  # noqa: E402
from release_tools import export_tree, validate_tree  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--apply", action="store_true", help="write the changes (default: only list them)")
    args = parser.parse_args()
    repository = args.repository.resolve()
    if not (repository / ".git").exists():
        parser.error(f"{repository} is not a Git working tree")
    if repository.is_relative_to(ROOT) or ROOT.is_relative_to(repository):
        parser.error("the public repository must be a separate folder")
    with tempfile.TemporaryDirectory(prefix=".sakura-sync-") as temporary:
        exported = export_tree(ROOT, Path(temporary) / "public")
        plan = sync_plan(exported, repository)
        total = sum(len(v) for v in plan.values())
        for kind, label in [("added", "+"), ("changed", "~"), ("removed", "-")]:
            for name in plan[kind]:
                print(f"{label} {name}")
        print(f"{len(plan['added'])} added, {len(plan['changed'])} changed, {len(plan['removed'])} removed")
        if not args.apply or total == 0:
            if total and not args.apply:
                print("Nothing written. Re-run with --apply to update the public working tree.")
            return 0
        apply_sync(exported, repository, plan)
    problems = validate_tree(repository, strict=True)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        print("The public working tree now fails the strict check; inspect it before committing.", file=sys.stderr)
        return 1
    print("Public working tree updated and strict check passed. Review `git status` / `git diff` there, then commit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
