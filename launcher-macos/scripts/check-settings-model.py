#!/usr/bin/env python3
"""Headless checks of the production settings draft and immediate-action interface."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
work = Path(os.environ.get('GARDENBOOT_WORK_ROOT', '/private/tmp/GardenBoot-P003-mac')).resolve()
build = work / 'swift-build/release'
with tempfile.TemporaryDirectory(prefix='settings-model-', dir=work) as temp:
    root = Path(temp)
    main = root / 'main.swift'
    shutil.copyfile(project / 'Tests/SettingsFixture.swift', main)
    executable = root / 'settings-model'
    source = project / 'Sources/GardenBoot'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'swift-modules'),
                    '-I', str(build / 'Modules'),
                    *[str(source / name) for name in ['Support.swift', 'PackMedia.swift', 'ExperienceEditor.swift', 'OverviewRuntime.swift', 'InstalledApplications.swift']],
                    str(main), *map(str, (build / 'GardenBootCore.build').glob('*.swift.o')), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(root / 'fixtures'), '--test-root', str(root / 'isolated-root')], check=True, timeout=20)
