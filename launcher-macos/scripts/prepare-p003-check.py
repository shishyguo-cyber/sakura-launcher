#!/usr/bin/env python3
"""Prepare a persistent, isolated P-003 GUI fixture. Does not start any application."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=Path, help='new disposable directory, e.g. /private/tmp/GardenBoot-P003-ui')
args = parser.parse_args()
project = Path(__file__).resolve().parents[1]
work = Path(os.environ.get('GARDENBOOT_WORK_ROOT', '/private/tmp/GardenBoot-P003-mac')).resolve()
build = work / 'swift-build/release'
root = args.root.resolve()
root.mkdir(parents=True, exist_ok=False)
identifier = 'local.gardenboot.P003Fixture.x' + uuid.uuid4().hex
fixture = root / 'P003Fixture.app'
binary = fixture / 'Contents/MacOS/P003Fixture'
binary.parent.mkdir(parents=True)
with (fixture / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': identifier, 'CFBundleExecutable': binary.name,
                  'CFBundleName': 'P003 受控测试窗口', 'CFBundlePackageType': 'APPL'}, f)
main = root / 'main.swift'
shutil.copyfile(project / 'Tests/LogicFixture.swift', main)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'swift-modules'),
                '-I', str(build / 'Modules'), str(project / 'Sources/GardenBoot/PackMedia.swift'), str(main),
                *map(str, (build / 'GardenBootCore.build').glob('*.swift.o')), '-o', str(binary)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(fixture)], check=True)
for pack_id, name in [('p003-cover', '花园 · 封面测试'), ('p003-frame', '花园 · 首帧测试'), ('p003-broken', '花园 · 无效封面测试')]:
    source = root / 'sources' / pack_id
    shutil.copytree(project / 'demo-pack', source)
    manifest = json.loads((source / 'manifest.json').read_text())
    manifest.update(id=pack_id, name=name)
    if pack_id == 'p003-frame':
        manifest.pop('cover')
        (source / 'cover.png').unlink()
    if pack_id == 'p003-broken':
        (source / 'cover.png').write_bytes(b'not a decodable image')
    (source / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
report = {'root': str(root), 'identifier': identifier, 'testRoot': str(root / 'data'),
          'launcherCommand': shlex.join([str(project / 'build/Sakura.app/Contents/MacOS/GardenBoot'),
              '--test-root', str(root / 'data'), '--test-target', identifier, '--settings']),
          'fixtureCommand': shlex.join([str(binary), '--window-delay', '3.3']),
          'sources': str(root / 'sources'), 'applicationsStarted': False}
(root / 'fixture.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
