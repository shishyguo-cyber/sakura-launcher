#!/usr/bin/env python3
"""Isolated NSWorkspace + AVFoundation tests; only generated demo media and owned processes."""
import json
import os
import sys
import plistlib
import re
import select
import shutil
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
GUI_SERVICES = ("com.apple.coreservices.launchservicesd", "com.apple.lsd.mapdb",
                "com.apple.hiservices-xpcservice", "com.apple.windowserver.active")
GUI_LOGS = ("native-logic", "delayed-window", "window-timeout", "preview", "unconfigured", "two-targets", "two-targets-disabled",
            "quiet", "reappear", "reappear-ignored", "compat-good", "compat-running", "video-pack", "video-pack-bad")
GUI_CASES = ["existing-process baseline", "cold-launch deduplication", "exit/relaunch",
             "no player in logic-only mode", "delayed window intro/loop/outro",
             "no-window timeout", "manual preview", "warm/cold first-frame and invisible-before-show", "unconfigured pack", "two targets: independent packs/daily records, busy and disabled",
             "quiet skip", "reappear plays", "minimize/hide ignored", "compat good / alreadyRunning",
             "create pack from video (good and corrupt)"]


class KnownGUIGap(Exception):
    """Only the explicit bootstrap permission-denied preflight may raise this."""


def gui_access_denied(services):
    # Unknown/missing services and unexpected crashes are failures, never a skip.
    return set(services) == set(GUI_SERVICES) and all(services[name]["code"] == 1100 for name in GUI_SERVICES)


def diagnose_gui_access(root, checks):
    source = root / "gui-services.c"
    executable = root / "gui-services"
    source.write_text(r'''#include <stdio.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
int main(void) {
    const char *names[] = {"com.apple.coreservices.launchservicesd", "com.apple.lsd.mapdb",
                          "com.apple.hiservices-xpcservice", "com.apple.windowserver.active"};
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t result = bootstrap_look_up(bootstrap_port, names[i], &port);
        printf("%s\t%d\t%s\n", names[i], result, bootstrap_strerror(result));
        if (result == KERN_SUCCESS) mach_port_deallocate(mach_task_self(), port);
    }
    return 0;
}
''')
    built = subprocess.run(["xcrun", "clang", str(source), "-o", str(executable)], capture_output=True, text=True)
    (checks / "gui-probe-build.log").write_text(built.stdout + built.stderr)
    built.check_returncode()
    probe = subprocess.run([str(executable)], check=True, capture_output=True, text=True, timeout=5)
    services = {}
    for line in probe.stdout.splitlines():
        name, code, message = line.split("\t", 2)
        services[name] = {"code": int(code), "message": message}
    (checks / "gui-access.json").write_text(json.dumps(services, indent=2) + "\n")
    return services


def wait_for(predicate, description, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {description}")


def assert_moves_as_soon_as_window_ready(text):
    def event_time(token):
        line = next((line for line in text.splitlines() if token in line), None)
        assert line is not None, f"Missing event: {token}\n{text}"
        return datetime.fromisoformat(line.split()[0].replace("Z", "+00:00"))

    delay = (event_time("player-move animated=true") - event_time("window-ready")).total_seconds()
    assert 0 <= delay <= 0.6, f"window-ready to player-move took {delay:.3f}s (limit 0.6s)\n{text}"
    return delay


def assert_first_frame_before_show(text, expected_warm=None):
    """Prove visibility ordering from alpha diagnostics, including the logged launch origin."""
    lines = text.splitlines()
    frames = [(i, re.search(r"first-frame age=(\d+\.\d{3}) warm=(true|false) segment=(intro|loop|outro|video)(?:$| )", line))
              for i, line in enumerate(lines) if " first-frame " in line]
    shows = [i for i, line in enumerate(lines) if " player-show " in line]
    assert len(frames) == len(shows) == 1, f"Expected one first-frame and one player-show\n{text}"
    frame_index, match = frames[0]
    assert match, f"Malformed first-frame event\n{text}"
    show_index = shows[0]
    assert frame_index <= show_index, f"player-show preceded first-frame\n{text}"

    def stamp(line):
        return datetime.fromisoformat(line.split()[0].replace("Z", "+00:00"))

    assert stamp(lines[frame_index]) <= stamp(lines[show_index]), f"first-frame timestamp after show\n{text}"
    assert "location=" in lines[show_index] and "frame=" in lines[show_index], "Lost show geometry"
    alpha = [float(m.group(1)) for line in lines[:show_index]
             if (m := re.search(r"overlay-alpha=([0-9.]+)", line))]
    assert len(alpha) >= 2 and all(a == 0 for a in alpha), f"Visible window before show or missing alpha evidence\n{text}"
    age, warm = float(match.group(1)), match.group(2) == "true"
    origin = next((line for line in lines if " launch-detected " in line or " preview-requested" in line), None)
    assert origin, "Missing launch / preview origin"
    measured = (stamp(lines[frame_index]) - stamp(origin)).total_seconds()
    assert abs(age - measured) <= 0.025, f"First-frame age excludes launch work: age={age}, measured={measured}"
    if expected_warm is not None:
        assert warm == expected_warm, f"Expected warm={expected_warm}, got {warm}\n{text}"
    return {"seconds": age, "warm": warm, "segment": match.group(3), "alphaBeforeShow": alpha}


def main():
    children, logs, fixture_processes = [], {}, []
    cache = Path(os.environ.get("GARDENBOOT_WORK_ROOT", Path.home() / "Library/Caches/GardenBoot")).resolve()
    report = {"date": datetime.now(timezone.utc).isoformat(), "videoUsed": "bundled demo-garden only",
              "chatGPTRestarted": False, "loginItemsChanged": False, "passed": False, "status": "running", "nativeGUIExecuted": False,
              "firstFrameSeconds": {"warm": None, "cold": None},
              "firstFrameTargetsSeconds": {"warm": 0.35, "cold": 1.5},
              "firstFrameTargetExceeded": {"warm": None, "cold": None}}
    checks = PROJECT / "checks"
    checks.mkdir(exist_ok=True)
    (checks / "native-logic.json").write_text(json.dumps(report, indent=2) + "\n")
    for name in GUI_LOGS:
        (checks / f"{name}.log").write_text(f"NOT RUN in verification {report['date']}; see native-logic.json\n")
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="logic-", dir=cache) as temporary:
        root = Path(temporary)
        fixture = root / "LogicFixture.app"
        executable = fixture / "Contents/MacOS/LogicFixture"
        executable.parent.mkdir(parents=True)
        identifier = "local.gardenboot.LogicFixture.x" + uuid.uuid4().hex
        with (fixture / "Contents/Info.plist").open("wb") as f:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "LogicFixture",
                          "CFBundleName": "启动事件测试", "CFBundlePackageType": "APPL"}, f)
        # Compile the actual production probe into the fixture (no duplicate probe implementation).
        # Swift requires the top-level file to be named main.swift with multiple source files.
        fixture_main = root / "main.swift"
        shutil.copy2(PROJECT / "Tests/LogicFixture.swift", fixture_main)
        build = cache / "swift-build/release"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(cache / "swift-modules"),
                        "-I", str(build / "Modules"), str(PROJECT / "Sources/GardenBoot/PackMedia.swift"),
                        str(fixture_main), *map(str, (build / "GardenBootCore.build").glob("*.swift.o")),
                        "-o", str(executable)], check=True)
        pack_check = subprocess.run([str(executable), "--pack-check", str(PROJECT / "demo-pack"), str(root / "pack-check")],
                                    capture_output=True, text=True, timeout=25)
        (checks / "pack-media.log").write_text(pack_check.stdout + pack_check.stderr)
        assert pack_check.returncode == 0, f"Production media probe: {pack_check.stdout} {pack_check.stderr}"
        report["productionMediaProbeInstallImportMigration"] = True
        subprocess.run(["codesign", "--force", "--sign", "-", str(fixture)], check=True, capture_output=True)
        binary = PROJECT / "build/Sakura.app/Contents/MacOS/GardenBoot"

        def events(name):
            p = logs[name]
            return p.read_text() if p.exists() else ""

        def start_fixture(*args, executable_path=executable):
            p = subprocess.Popen([str(executable_path), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            children.append(p)
            fixture_processes.append((p, list(args)))
            ready, _, _ = select.select([p.stdout], [], [], 8)
            assert ready and p.stdout.readline().strip() == "fixture-ready", f"Fixture failed to launch: status={p.poll()} stderr={p.stderr.read() if p.poll() is not None else str(p.pid)}"
            if "--window-delay" in args:
                # A shell-spawned app may not activate in the user's current Space.
                # Ask LaunchServices to activate only this already-running, owned fixture.
                subprocess.run(["open", "-a", str(executable_path.parents[2])], check=True, capture_output=True, timeout=5)
            return p

        def stop(p):
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=5)

        def start_watcher(name, *args, executable_path=binary, settings_targets=False):
            state = root / name
            logs[name] = state / "events.log"
            target_args = [] if settings_targets else ["--test-target", identifier]
            p = subprocess.Popen([str(executable_path), *target_args, "--test-root", str(state),
                                  *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            children.append(p)
            wait_for(lambda: "monitor-started" in events(name), f"{name} watcher ready")
            return p

        def assert_order(name, *tokens):
            text, cursor = events(name), 0
            for token in tokens:
                position = text.find(token, cursor)
                assert position >= 0, f"{name}: missing or out-of-order {token}\n{text}"
                cursor = position + len(token)

        try:
            services = diagnose_gui_access(root, checks)
            if gui_access_denied(services):
                raise KnownGUIGap("GUI service bootstrap lookups denied (1100) by the execution sandbox; "
                                  "NSApplication cannot register with LaunchServices / HI Services / WindowServer")
            first = start_fixture()
            report["nativeGUIExecuted"] = True
            watcher = start_watcher("native-logic", "--logic-only", "-paused", "YES")
            assert "baseline=1" in events("native-logic")
            time.sleep(0.5)
            assert "logic-trigger" not in events("native-logic"), "Existing application incorrectly triggered"
            report["existingApplicationSkipped"] = True
            for index in range(1, 4):
                stop(first)
                wait_for(lambda: events("native-logic").count("target-exited") == index, "termination")
                if index < 3:
                    first = start_fixture()
                    wait_for(lambda: events("native-logic").count("logic-trigger") == index, "cold launch")
                    time.sleep(0.5)
                    assert events("native-logic").count("logic-trigger") == index, "Duplicate trigger"
            report.update(coldLaunchTriggeredOnce=True, diagnosticIgnoresPersonalPausePreference=True,
                          subsequentColdLaunchTriggered=True)
            assert "player-" not in events("native-logic"), "Logic test unexpectedly started a player"
            report["noPlayerCreated"] = True
            stop(watcher)

            # Removing immediate-start behavior or loop-cycle reporting breaks this test.
            watcher = start_watcher("delayed-window", "-paused", "NO", "-playDespiteReduceMotion", "YES")
            wait_for(lambda: "warm-ready pack=demo-garden" in events("delayed-window"), "idle first-segment warm-up")
            fixture_process = start_fixture("--window-delay", "3.3")
            wait_for(lambda: "player-finished reason=completed" in events("delayed-window"), "delayed playback completion")
            assert_order("delayed-window", "launch-detected", "player-play segment=intro", "player-play segment=loop",
                         "window-ready", "player-move animated=true", "loop-cycle-ended", "player-play segment=outro",
                         "player-fade", "fade-completed", "player-finished reason=completed")
            report["windowReadyToMoveSeconds"] = assert_moves_as_soon_as_window_ready(events("delayed-window"))
            report["movesAsSoonAsWindowReady"] = True
            assert events("delayed-window").count("launch-detected") == 1
            assert "reason=failed" not in events("delayed-window")
            report["delayedWindowIntroLoopOutro"] = True
            report["firstFrameWarm"] = assert_first_frame_before_show(events("delayed-window"), expected_warm=True)
            stop(fixture_process)
            stop(watcher)

            watcher = start_watcher("window-timeout", "-paused", "NO", "-playDespiteReduceMotion", "YES")
            fixture_process = start_fixture()
            wait_for(lambda: "player-finished reason=window-timeout" in events("window-timeout"), "no-window timeout", 15)
            assert_order("window-timeout", "player-play segment=intro", "player-play segment=loop", "wait-timed-out",
                         "player-fade", "fade-completed", "player-finished reason=window-timeout")
            assert "segment=outro" not in events("window-timeout")
            report["noWindowTimesOutWithoutCover"] = True
            report["timeoutFirstFrame"] = assert_first_frame_before_show(events("window-timeout"))
            stop(fixture_process)
            stop(watcher)

            # Manual preview must bypass automatic pause / reduced-motion policy.
            watcher = start_watcher("preview", "--preview", "--test-cold-start", "-paused", "YES")
            wait_for(lambda: "player-finished reason=completed" in events("preview"), "preview completion")
            assert_order("preview", "player-play segment=intro", "player-play segment=loop", "player-play segment=outro",
                         "player-fade", "player-finished reason=completed")
            assert (root / "preview/Packs/demo-garden/manifest.json").is_file()
            report["previewBypassesPauseAndInstallsDemo"] = True
            report["firstFrameCold"] = assert_first_frame_before_show(events("preview"), expected_warm=False)
            report["firstFrameSeconds"] = {"warm": report["firstFrameWarm"]["seconds"], "cold": report["firstFrameCold"]["seconds"]}
            # Targets are measurements, never a reason to relax playback deadlines or existing assertions.
            report["firstFrameTargetExceeded"] = {key: value > report["firstFrameTargetsSeconds"][key]
                                                  for key, value in report["firstFrameSeconds"].items()}
            report["coldMethod"] = "fresh watcher and isolated test root; --test-cold-start disables idle warm-up until first playback ends (OS file cache is not flushed)"
            stop(watcher)

            # Two owned fixtures, unique bundle identities and separately bound demo-derived packs.
            second_fixture = root / "SecondFixture.app"
            shutil.copytree(fixture, second_fixture)
            second_identifier = identifier + ".second"
            second_plist = second_fixture / "Contents/Info.plist"
            info = plistlib.loads(second_plist.read_bytes())
            info["CFBundleIdentifier"] = second_identifier
            second_plist.write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--sign", "-", str(second_fixture)], check=True, capture_output=True)
            second_executable = second_fixture / "Contents/MacOS/LogicFixture"

            def prepare_targets(name, second_enabled=True):
                state = root / name
                state.mkdir()
                for pack_id in ["demo-garden", "second-garden"]:
                    destination = state / "Packs" / pack_id
                    shutil.copytree(PROJECT / "demo-pack", destination)
                    manifest = json.loads((destination / "manifest.json").read_text())
                    manifest.update(id=pack_id, name=pack_id, maxWaitSeconds=8)
                    if pack_id == "second-garden":
                        # A distinct single-segment animation, using only bundled original media.
                        manifest["segments"] = {"video": "outro.mp4"}
                    (destination / "manifest.json").write_text(json.dumps(manifest))
                settings = {"schemaVersion": 3, "masterVolume": 0, "muted": True, "packs": {},
                            "playback": {"frequency": "firstOfDay", "dayStartHour": 4},
                            "library": {"rotation": "fixed", "favorites": []}, "targets": [
                                {"id": "fixture-one", "name": "测试一", "enabled": True,
                                 "animation": "demo-garden", "mac": {"bundleId": identifier}},
                                {"id": "fixture-two", "name": "测试二", "enabled": second_enabled,
                                 "animation": "second-garden", "mac": {"bundleId": second_identifier}}]}
                (state / "experience.json").write_text(json.dumps(settings))
                return state

            pair_state = prepare_targets("two-targets")
            watcher = start_watcher("two-targets", "-paused", "NO", "-playDespiteReduceMotion", "YES", settings_targets=True)
            wait_for(lambda: "target=fixture-two" in events("two-targets"), "both target monitors configured")
            first = start_fixture()
            wait_for(lambda: "player-show" in events("two-targets"), "first target shown")
            second = start_fixture(executable_path=second_executable)
            wait_for(lambda: "playback-skipped reason=busy target=fixture-two" in events("two-targets"), "second target busy skip")
            assert "pack-chosen id=demo-garden rotation=target target=fixture-one" in events("two-targets")
            wait_for(lambda: "player-finished" in events("two-targets"), "first target finishes", 15)
            first_finish = next(line for line in events("two-targets").splitlines() if "player-finished" in line)
            assert "reason=window-timeout" in first_finish and "target=fixture-one" in first_finish, first_finish
            assert events("two-targets").count("player-show") == 1, "Busy target interrupted or started another overlay"
            before = json.loads((pair_state / "playback-state.json").read_text())
            assert set(before["targets"]) == {"fixture-one"}, "Busy skip must not consume daily allowance"
            stop(first)
            stop(second)
            wait_for(lambda: events("two-targets").count("target-exited") == 2, "pair exit observed")
            second = start_fixture("--window-delay", "3.3", executable_path=second_executable)
            wait_for(lambda: "pack-chosen id=second-garden rotation=target target=fixture-two" in events("two-targets"), "second target uses its pack")
            wait_for(lambda: events("two-targets").count("player-finished") == 2, "second target finishes", 15)
            second_finish = [line for line in events("two-targets").splitlines() if "player-finished" in line][-1]
            assert "reason=completed" in second_finish and "target=fixture-two" in second_finish, second_finish
            records = json.loads((pair_state / "playback-state.json").read_text())
            assert records["schemaVersion"] == 2
            assert records["targets"]["fixture-one"]["lastPackId"] == "demo-garden"
            assert records["targets"]["fixture-two"]["lastPackId"] == "second-garden"
            first = start_fixture()
            wait_for(lambda: "playback-skipped reason=played-today target=fixture-one" in events("two-targets"), "first target daily allowance")
            assert events("two-targets").count("player-show") == 2, events("two-targets")
            stop(first); stop(second); stop(watcher)
            prepare_targets("two-targets-disabled", second_enabled=False)
            watcher = start_watcher("two-targets-disabled", "-paused", "NO", "-playDespiteReduceMotion", "YES", settings_targets=True)
            second = start_fixture(executable_path=second_executable)
            time.sleep(0.8)
            assert "target=fixture-two" not in events("two-targets-disabled"), events("two-targets-disabled")
            assert "player-show" not in events("two-targets-disabled")
            stop(second); stop(watcher)
            report["twoTargets"] = {"distinctPacks": True, "busyDoesNotInterrupt": True,
                                    "busyDoesNotConsumeDailyAllowance": True, "independentDailyRecords": True, "disabledDoesNotPlay": True}

            # P-011 (COMPATIBILITY.md): quiet skip, reappear, minimize/hide ignored, "测试" verdicts.
            watcher = start_watcher("quiet", "-paused", "NO", "-playDespiteReduceMotion", "YES", "--test-quiet", "fullscreen")
            fixture_process = start_fixture("--window-delay", "0.5")
            wait_for(lambda: "playback-skipped reason=quiet target=default-codex detail=fullscreen" in events("quiet"), "quiet skip")
            time.sleep(0.5)
            assert "player-show" not in events("quiet"), events("quiet")
            stop(fixture_process); stop(watcher)

            watcher = start_watcher("reappear", "-paused", "NO", "-playDespiteReduceMotion", "YES", "--test-reappear")
            fixture_process = start_fixture("--window-delay", "0.5", "--close-after", "6", "--reopen-after", "10")
            wait_for(lambda: "player-finished" in events("reappear"), "cold playback finishes", 15)
            wait_for(lambda: "launch-detected target=default-codex kind=reappear" in events("reappear"), "reappear detected", 15)
            wait_for(lambda: events("reappear").count("player-finished") == 2, "reappear playback finishes", 15)
            assert events("reappear").count("launch-detected") == 2 and events("reappear").count("target-reappeared") == 1, events("reappear")
            assert_order("reappear", "kind=cold", "player-finished", "target-reappeared", "kind=reappear", "player-show", "player-finished")
            stop(fixture_process); stop(watcher)

            watcher = start_watcher("reappear-ignored", "--logic-only", "--test-reappear")
            fixture_process = start_fixture("--window-delay", "0.5", "--minimize-after", "2", "--restore-after", "5",
                                            "--hide-after", "6.5", "--unhide-after", "9.5")
            wait_for(lambda: "logic-trigger" in events("reappear-ignored"), "cold start seen")
            time.sleep(11.5)
            assert "target-reappeared" not in events("reappear-ignored"), events("reappear-ignored")
            stop(fixture_process); stop(watcher)

            watcher = start_watcher("compat-good", "-paused", "YES", "--test-compat", "default-codex", "--test-compat-seconds", "15")
            wait_for(lambda: "compat-start target=default-codex running=false" in events("compat-good"), "compat test started")
            fixture_process = start_fixture("--window-delay", "1")
            wait_for(lambda: "compat-result target=default-codex" in events("compat-good"), "compat result", 20)
            result = re.search(r"compat-result target=default-codex verdict=(\w+) window=([0-9.]+|none)", events("compat-good"))
            assert result and result.group(1) == "good" and 0.5 <= float(result.group(2)) <= 4, events("compat-good")
            assert "player-show" in events("compat-good"), "Test must play even while auto-play is paused"
            stored = json.loads((root / "compat-good/playback-state.json").read_text())["targets"]["default-codex"]
            assert stored["compat"]["verdict"] == "good" and "lastAutoPlayAt" not in stored, stored
            stop(watcher)  # the fixture keeps running for the next case

            watcher = start_watcher("compat-running", "--test-compat", "default-codex", "--test-compat-seconds", "2")
            wait_for(lambda: "compat-result target=default-codex verdict=alreadyRunning window=none" in events("compat-running"), "already running", 10)
            stop(fixture_process); stop(watcher)
            report["compatibility"] = {"quietSkips": True, "reappearPlays": True, "minimizeAndHideIgnored": True,
                                       "compatGood": float(result.group(2)), "compatAlreadyRunning": True}

            # P-013: a video becomes a single-video pack through the normal import checks, and becomes current.
            source = root / "我的 开场_片段.MOV"
            shutil.copy2(PROJECT / "demo-pack/outro.mp4", source)
            watcher = start_watcher("video-pack", "-paused", "YES", "--test-create-video", str(source))
            wait_for(lambda: "pack-created-from-video" in events("video-pack") or "pack-create-failed" in events("video-pack"), "video pack created", 20)
            created = re.search(r"pack-created-from-video id=(video-[0-9a-f]{8})", events("video-pack"))
            assert created, events("video-pack")
            folder = root / "video-pack/Packs" / created.group(1)
            manifest = json.loads((folder / "manifest.json").read_text())
            assert manifest["name"] == "我的 开场 片段" and manifest["segments"] == {"video": "video.mov"}, manifest
            notice = (folder / "NOTICE.md").read_text()
            assert "「我的 开场_片段.MOV」" in notice and str(root) not in notice, notice
            assert not list((root / "video-pack").glob(".video-*")), "staging folder left behind"
            stop(watcher)
            bad = root / "broken.mp4"
            bad.write_bytes(b"not a video")
            watcher = start_watcher("video-pack-bad", "-paused", "YES", "--test-create-video", str(bad))
            wait_for(lambda: "pack-create-failed" in events("video-pack-bad"), "corrupt video rejected", 20)
            assert not list((root / "video-pack-bad/Packs").glob("video-*")), "corrupt video must not enter the library"
            stop(watcher)
            report["videoPack"] = {"created": created.group(1), "corruptRejected": True}

            # Preserve v1's unconfigured-media case: genuinely resource-less app + empty test root.
            empty_app = root / "Empty.app"
            empty_binary = empty_app / "Contents/MacOS/GardenBoot"
            empty_binary.parent.mkdir(parents=True)
            shutil.copy2(binary, empty_binary)
            shutil.copy2(binary.parents[1] / "Info.plist", empty_app / "Contents/Info.plist")
            subprocess.run(["codesign", "--force", "--sign", "-", str(empty_app)], check=True, capture_output=True)
            watcher = start_watcher("unconfigured", "--preview", executable_path=empty_binary)
            wait_for(lambda: "playback-skipped reason=no-configured-pack" in events("unconfigured"), "unconfigured skip")
            assert "player-show" not in events("unconfigured")
            report["unconfiguredMediaSkippedWithoutWindow"] = True
            stop(watcher)
            report["passed"] = True
            report["status"] = "passed"
        except KnownGUIGap as error:
            report.update(status="known-gap", reason=str(error), nativeGUINotRun=GUI_CASES,
                          guiEvidence="checks/gui-access.json")
        except Exception as error:
            report["status"] = "failed"
            report["error"] = str(error)
            raise
        finally:
            for child in reversed(children):
                stop(child)
            fixture_diagnostics = []
            for child, arguments in fixture_processes:
                output, errors = child.communicate(timeout=5)
                fixture_diagnostics.append({"pid": child.pid, "arguments": arguments, "stdout": output, "stderr": errors})
            (checks / "fixture-processes.json").write_text(json.dumps(fixture_diagnostics, indent=2) + "\n")
            for name in GUI_LOGS:
                text = events(name) if name in logs else f"NOT RUN: {report['status']}; {report.get('reason', report.get('error', 'not reached'))}\n"
                (checks / f"{name}.log").write_text(text)
            (checks / "native-logic.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if report["status"] == "known-gap":
        print("KNOWN GAP: headless media checks passed; native GUI tests NOT RUN. See checks/gui-access.json", file=sys.stderr)
        return 77
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        report_path = PROJECT / "checks/native-logic.json"
        report = json.loads(report_path.read_text())
        report.update(status="failed", passed=False, error=str(error))
        report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        raise
