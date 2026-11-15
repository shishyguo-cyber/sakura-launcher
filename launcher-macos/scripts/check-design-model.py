#!/usr/bin/env python3
"""Verify dynamic palette and template geometry without initializing NSApplication."""
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
work = Path(os.environ.get('GARDENBOOT_WORK_ROOT', '/private/tmp/GardenBoot-P008-mac'))
work.mkdir(parents=True, exist_ok=True)
output = project / 'checks/p008'
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='design-model-', dir=work) as temp:
    root = Path(temp)
    shutil.copyfile(project / 'Tests/DesignFixture.swift', root / 'main.swift')
    source = project / 'Sources/GardenBoot'
    executable = root / 'design-model'
    # Match SwiftPM's existing --disable-sandbox: avoids nested compiler-plugin sandboxing,
    # while the caller's filesystem / GUI-service sandbox remains in force.
    subprocess.run(['xcrun', 'swiftc', '-disable-sandbox', '-swift-version', '5', '-target', platform.machine() + '-apple-macosx13.0',
                    '-module-cache-path', str(work / 'swift-modules'),
                    str(source / 'ReviewRenderOptions.swift'), str(source / 'SettingsPage.swift'), str(source / 'Theme.swift'), str(source / 'FlowerIcon.swift'), str(root / 'main.swift'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(output / 'icon-review.png')], check=True, timeout=20)
