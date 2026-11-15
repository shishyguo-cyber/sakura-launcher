#!/usr/bin/env python3
"""P-008 isolated rendering integration check; no screen capture or target app launch."""
import argparse
import json
import importlib.util
import sys
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zlib

project = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=project / 'checks/p008/render')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
# Safe RED gate: an older app would ignore the switch and begin monitoring.
assert 'ReviewRenderOptions.parse' in (project / 'Sources/GardenBoot/main.swift').read_text(), 'render CLI not implemented; refusing to start normal app'
app = project / 'build/Sakura.app/Contents/MacOS/GardenBoot'
assert b'--render-settings' in app.read_bytes() and b'--render-menubar-icon' in app.read_bytes() and b'--page' in app.read_bytes(), 'rebuild the app before rendering'

def run(*arguments, ok=True):
    result = subprocess.run([str(app), *map(str, arguments)], capture_output=True, text=True, timeout=30)
    assert (result.returncode == 0) == ok, (arguments, result.returncode, result.stderr)
    if not ok: assert result.returncode > 0 and 'render:' in result.stderr, 'invalid arguments must fail cleanly before AppKit'
    return result

def png(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    chunks, pos = {}, 8
    compressed = b''
    while pos < len(data):
        size = struct.unpack('>I', data[pos:pos+4])[0]
        kind, chunk = data[pos+4:pos+8], data[pos+8:pos+8+size]
        chunks[kind] = chunk
        if kind == b'IDAT': compressed += chunk
        pos += 12 + size
    width, height, depth, color, *_ = struct.unpack('>IIBBBBB', chunks[b'IHDR'])
    assert depth == 8 and color in (2, 6), (depth, color)
    channels = 4 if color == 6 else 3
    stride = width * channels
    raw = zlib.decompress(compressed)
    rows, previous, offset = [], bytearray(stride), 0
    for _ in range(height):
        kind = raw[offset]; offset += 1
        row = bytearray(raw[offset:offset+stride]); offset += stride
        for i in range(stride):
            a = row[i-channels] if i >= channels else 0
            b = previous[i]
            c = previous[i-channels] if i >= channels else 0
            if kind == 1: row[i] = (row[i] + a) & 255
            if kind == 2: row[i] = (row[i] + b) & 255
            if kind == 3: row[i] = (row[i] + (a+b)//2) & 255
            if kind == 4:
                p = a+b-c
                nearest = a if abs(p-a) <= abs(p-b) and abs(p-a) <= abs(p-c) else b if abs(p-b) <= abs(p-c) else c
                row[i] = (row[i] + nearest) & 255
        rows.append(row); previous = row
    def pixel(x, y): return tuple(rows[y][x*channels:(x+1)*channels])
    return width, height, pixel

with tempfile.TemporaryDirectory(prefix='GardenBoot-P008-', dir='/private/tmp') as temp:
    root = Path(temp)
    pack = root / 'Packs/demo-garden'
    shutil.copytree(project / 'demo-pack', pack)
    before = {p.relative_to(pack): p.read_bytes() for p in pack.rglob('*') if p.is_file()}
    for bad in [('--render-settings',), ('--render-settings', output / 'bad.png', '--appearance', 'sepia'),
                ('--render-menubar-icon',), ('--render-settings', output / 'bad.png', '--render-menubar-icon', output / 'bad.png'),
                ('--render-settings', output / 'bad.png', '--register-login'),
                ('--render-settings', output / 'bad.png', '--appearance'), ('--appearance', 'light'), ('--page', 'animation'),
                ('--render-settings', output / 'bad.png', '--page'),
                ('--render-settings', output / 'bad.png', '--page', 'unknown'),
                ('--render-settings', output / 'bad.png', '--page', 'sound', '--page', 'display'),
                ('--render-menubar-icon', output / 'bad.png', '--page', 'animation'),
                ('--size', '820x560'),
                ('--render-settings', output / 'bad.png', '--size', '819x560'),
                ('--render-menubar-icon', output / 'bad.png', '--size', '820x560')]:
        run(*bad, '--test-root', root, ok=False)
    run('--render-menubar-icon', output / 'menubar-icon.png')
    w, h, pixel = png(output / 'menubar-icon.png')
    assert (w, h) == (36, 36)
    assert pixel(18, 18)[3] == 0, 'flower center must be transparent'
    assert pixel(18, 4)[3] > 200, 'top petal must be filled'
    assert pixel(0, 0)[3] == 0
    # Reuse the existing explicit bootstrap permission probe; unknown crashes remain failures.
    spec = importlib.util.spec_from_file_location('garden_gui_probe', project / 'scripts/check-logic.py')
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    services = probe.diagnose_gui_access(root, output)
    if probe.gui_access_denied(services):
        report = {'passed': False, 'status': 'known-gui-gap', 'iconPassed': True,
                  'argumentChecksPassed': True, 'settingsRendered': False, 'output': str(output),
                  'reason': 'GUI bootstrap lookups denied (1100); run settings render from a normal macOS session.'}
        (output / 'render-check.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report, ensure_ascii=False))
        sys.exit(77)
    renders = [(page, 'light') for page in ['overview', 'animation', 'targets', 'playback', 'sound', 'display', 'presets']]
    renders.extend([('overview', 'dark'), ('animation', 'dark'), ('targets', 'dark')])
    page_images = []
    for page, appearance in renders:
        destination = output / f'settings-{page}-{appearance}.png'
        run('--render-settings', destination, '--appearance', appearance, '--page', page, '--test-root', root)
        w, h, pixel = png(destination)
        assert (w, h) == (1920, 1280), (w, h)
        bg, sidebar, hero = ((251, 250, 247), (243, 240, 234), (233, 241, 234)) if appearance == 'light' else ((24, 23, 28), (18, 17, 22), (30, 43, 35))
        panel_point = (500, 210) if page == 'overview' else (500, 60)
        for point, expected in [((400, 8), bg), ((8, 8), sidebar), (panel_point, hero)]:
            actual = pixel(*point)[:3]
            assert all(abs(a-b) <= 2 for a, b in zip(actual, expected)), (point, actual, expected)
        if appearance == 'light': page_images.append(destination.read_bytes())
    assert len(set(page_images)) == 7, '--page must produce seven distinct pages'
    run('--render-settings', output / 'settings-overview-compact.png', '--page', 'overview',
        '--appearance', 'light', '--size', '820x560', '--test-root', root)
    assert png(output / 'settings-overview-compact.png')[:2] == (1640, 1120)
    after = {p.relative_to(pack): p.read_bytes() for p in pack.rglob('*') if p.is_file()}
    assert not (root / 'experience.json').exists() and not (root / 'events.log').exists()
    assert not (root / 'Cache').exists() and not (root / 'playback-state.json').exists()
    assert before == after, 'render must not mutate the isolated library/settings'
    # The empty library must render too; no implicit demo installation.
    empty = root / 'empty'
    empty.mkdir()
    run('--render-settings', output / 'settings-empty.png', '--test-root', empty)
    assert not list(empty.iterdir())
report = {'passed': True, 'output': str(output), 'settingsPixels': [1920, 1280], 'compactPixels': [1640, 1120], 'pages': ['overview', 'animation', 'targets', 'playback', 'sound', 'display', 'presets'], 'appearanceRenders': 11, 'iconPixels': [36, 36]}
(output / 'render-check.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False))
