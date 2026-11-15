#!/usr/bin/env python3
"""Check the production segment aspect loader with local wide and rotated media. No GUI."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
work = Path(os.environ.get('GARDENBOOT_WORK_ROOT', '/private/tmp/GardenBoot-P004-mac')).resolve()
build = work / 'swift-build/release'
with tempfile.TemporaryDirectory(prefix='video-fit-media-', dir=work) as temp:
    root = Path(temp)
    main = root / 'main.swift'
    shutil.copyfile(project / 'Tests/VideoFitMediaFixture.swift', main)
    executable = root / 'video-fit-media'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'swift-modules'),
                    '-I', str(build / 'Modules'), str(project / 'Sources/GardenBoot/PackMedia.swift'), str(main),
                    *map(str, (build / 'GardenBootCore.build').glob('*.swift.o')), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(project / 'demo-pack'), str(root / 'rotated.mov')], check=True, timeout=30)
