#!/usr/bin/env python3
"""Draw the CC0 greeting background as two consecutive 30 fps PNG sequences."""
from argparse import ArgumentParser
from math import exp, sin, tau
from pathlib import Path
import struct
import zlib

WIDTH, HEIGHT = 768, 432
INTRO_FRAMES, OUTRO_FRAMES = 27, 36

# Fixed ordered dithering breaks up 8-bit gradient bands without flickering.
DITHER = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def gaussian(count, center, spread):
    return [exp(-0.5 * ((index / (count - 1) - center) / spread) ** 2) for index in range(count)]


def frame(time):
    drift = sin(time * tau / 9)
    soft_left = gaussian(WIDTH, 0.17 + 0.10 * drift, 0.33)
    soft_top = gaussian(HEIGHT, 0.17 + 0.11 * drift, 0.35)
    soft_right = gaussian(WIDTH, 0.90 - 0.07 * drift, 0.29 + 0.04 * drift)
    soft_bottom = gaussian(HEIGHT, 0.82 - 0.13 * drift, 0.30)
    rows = bytearray()
    for y in range(HEIGHT):
        glow_top = 94 * soft_top[y]
        glow_bottom = 104 * soft_bottom[y]
        dither = DITHER[y % 4]
        rows.append(0)
        rows.extend(int(79 + glow_top * left + glow_bottom * right + dither[x % 4] / 16)
                    for x, (left, right) in enumerate(zip(soft_left, soft_right)))
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 0, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
            + png_chunk(b"IDAT", zlib.compress(rows)) + png_chunk(b"IEND", b""))


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    root = parser.parse_args().directory
    for segment, offset, count in (("intro", 0, INTRO_FRAMES), ("outro", INTRO_FRAMES, OUTRO_FRAMES)):
        directory = root / segment
        directory.mkdir(parents=True, exist_ok=False)
        for index in range(count):
            (directory / f"frame_{index:03d}.png").write_bytes(frame((offset + index) / 30))


if __name__ == "__main__":
    main()
