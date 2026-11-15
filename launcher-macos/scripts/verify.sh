#!/bin/bash
# Full macOS verification of an already built app (run scripts/build.sh first):
# unit tests -> bundle checks -> settings model -> native GUI scenes (check-logic.py).
# Always writes checks/verification.json. Exit code 77 from the GUI step means the sandbox denied GUI services:
# that is reported as a known gap, never as a pass.
set -euo pipefail

package_dir="$(cd "$(dirname "$0")/.." && pwd)"
reports="$package_dir/checks"
mkdir -p "$reports"
export GARDENBOOT_WORK_ROOT="${GARDENBOOT_WORK_ROOT:-$HOME/Library/Caches/GardenBoot}"
export CLANG_MODULE_CACHE_PATH="$GARDENBOOT_WORK_ROOT/swift-modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
bundle="$package_dir/build/Sakura.app"

outcome=failed
current_stage=unit-tests
finished_stages=""

write_report() {
  local code=$?
  trap - EXIT
  python3 - "$reports" "$outcome" "$current_stage" "$code" "$finished_stages" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

folder, outcome, stage, code, finished = Path(sys.argv[1]), *sys.argv[2:]
report = {
    "date": datetime.now(timezone.utc).isoformat(),
    "status": outcome,
    "passed": outcome == "passed",
    "exitCode": int(code),
    "completedChecks": finished.split(),
    "lastStage": stage,
}
gui_report = folder / "native-logic.json"
if stage == "native-logic" and gui_report.exists():
    report["nativeLogic"] = json.loads(gui_report.read_text())
target = folder / "verification.json"
target.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print(f"VERIFY {outcome.upper()}: exit={code}; completed: {finished.strip()}; report: {target}")
messages = {
    "known-gap": "已知缺口：执行沙箱拒绝 GUI 服务访问，原生窗口/预览实跑未执行；不代表全套验证通过。",
    "failed": f"验证失败：{stage}；未将异常降级为已知缺口。",
}
if outcome in messages:
    print(messages[outcome])
PY
  exit "$code"
}
trap write_report EXIT

begin() { current_stage="$1"; }
done_with() { finished_stages="$finished_stages $*"; }

begin unit-tests
swift test --disable-sandbox --build-system native \
  --cache-path "$GARDENBOOT_WORK_ROOT/swiftpm/cache" --config-path "$GARDENBOOT_WORK_ROOT/swiftpm/config" \
  --security-path "$GARDENBOOT_WORK_ROOT/swiftpm/security" \
  --package-path "$package_dir" --scratch-path "$GARDENBOOT_WORK_ROOT/swift-build" 2>&1 | tee "$reports/unit-tests.log"
done_with unit-tests

begin plist;        plutil -lint "$bundle/Contents/Info.plist";                         done_with plist
begin signature;    codesign --verify --deep --strict "$bundle";                         done_with signature
begin bundled-demo; test -s "$bundle/Contents/Resources/demo-pack/manifest.json";        done_with bundled-demo
begin featured;     test -s "$bundle/Contents/Resources/featured-pack/manifest.json";    done_with featured
begin public-media; python3 "$package_dir/scripts/check-public-media.py" --app "$bundle"; done_with public-media

begin settings-model
python3 "$package_dir/scripts/check-settings-model.py" 2>&1 | tee "$reports/p003-settings-model.log"
done_with settings-model

begin native-logic
if python3 "$package_dir/scripts/check-logic.py" 2>&1 | tee "$reports/native-check.log"; then
  done_with media-probe-and-library native-logic
  outcome=passed
else
  gui_code=$?
  if [ "$gui_code" -eq 77 ]; then
    done_with media-probe-and-library
    outcome=known-gap
  fi
  exit "$gui_code"
fi
