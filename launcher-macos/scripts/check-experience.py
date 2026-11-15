#!/usr/bin/env python3
"""Exercise saved settings in the real player, using only a private target and demo pack."""
import json
import math
from pathlib import Path
import subprocess
import tempfile
import time

project = Path(__file__).resolve().parents[1]
app = (project / 'build/Sakura.app').resolve() / 'Contents/MacOS/GardenBoot'
cache = Path.home() / 'Library/Caches/GardenBoot'
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='experience-check-', dir=cache) as folder:
    root = Path(folder)
    settings = {'schemaVersion': 1, 'masterVolume': .35, 'muted': False, 'packs': {
        'demo-garden': {'overrides': {'fadeDuration': 1.2, 'maxWaitSeconds': 1, 'launchCoverage': .55}, 'presets': []}}}
    original = json.dumps(settings).encode()
    (root / 'experience.json').write_bytes(original)
    process = subprocess.Popen([str(app), '--test-root', str(root), '--test-target', 'local.gardenboot.experience-check', '--preview'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 12
        log = ''
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise AssertionError(f'Test launcher exited: {process.returncode}')
            path = root / 'events.log'
            log = path.read_text() if path.exists() else ''
            if 'player-finished reason=' in log:
                break
            time.sleep(.05)
        assert 'player-finished reason=window-timeout' in log, log
        line = next(line for line in log.splitlines() if 'experience-applied ' in line)
        values = dict(item.split('=', 1) for item in line.split() if '=' in item)
        assert math.isclose(float(values['volume']), .28), line
        assert math.isclose(float(values['fade']), 1.2), line
        assert math.isclose(float(values['coverage']), .55), line
        assert (root / 'experience.json').read_bytes() == original
        print(json.dumps({'passed': True, 'savedProfileUsedByRealPlayer': True, 'waitOverrideReached': True,
                          'settingsUnchanged': True, 'realTargetRestarted': False}))
    finally:
        process.terminate()
        process.communicate(timeout=5)
