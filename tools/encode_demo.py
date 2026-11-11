#!/usr/bin/env python3
"""Encodes demo clips recorded by frontend/integration_test/demo_capture_test.dart.

    tools/encode_demo.py <raw dir> <out dir> <scene> [--gif] [--size WxH]
                         [--crf N] [--suffix -dark]

Reads <scene>.rgba (raw RGBA frames) and <scene>.json (width, height and
per-frame timestamps in ms), resamples to a constant frame rate, and writes
<out>/demo-<scene><suffix>.avif (1280x800 unless --size, 15 fps, SVT-AV1 at
--crf, default 38) and, with --gif, a 960x600 GIF fallback. Record at
DEMO_SCALE=2 for --size 2560x1600.
"""
import json
import os
import subprocess
import sys

AVIF_FPS = 15
GIF_FPS = 50 / 3  # 60 ms per frame


def frames(raw, meta, fps):
    """Yields the raw frame shown at each tick of a constant-rate clip."""
    w, h, times = meta["width"], meta["height"], meta["times"]
    size = w * h * 4
    t0, end = times[0], times[-1]
    i = 0
    with open(raw, "rb") as f:
        tick = 0
        while True:
            t = t0 + tick * 1000 / fps
            if t > end:
                break
            while i + 1 < len(times) and times[i + 1] <= t:
                i += 1
            f.seek(i * size)
            yield f.read(size)
            tick += 1


def encode(raw, meta, fps, args):
    w, h = meta["width"], meta["height"]
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba",
           "-s", f"{w}x{h}", "-r", str(fps), "-i", "-"] + args
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for fr in frames(raw, meta, fps):
        p.stdin.write(fr)
    p.stdin.close()
    if p.wait() != 0:
        sys.exit(f"ffmpeg failed: {' '.join(cmd)}")


def main():
    raw_dir, out_dir, scene = sys.argv[1:4]
    opts = sys.argv[4:]
    gif = "--gif" in opts

    def opt(name, default):
        return opts[opts.index(name) + 1] if name in opts else default

    w, h = opt("--size", "1280x800").split("x")
    crf = opt("--crf", "38")
    suffix = opt("--suffix", "")
    raw = os.path.join(raw_dir, f"{scene}.rgba")
    with open(os.path.join(raw_dir, f"{scene}.json")) as f:
        meta = json.load(f)
    avif = os.path.join(out_dir, f"demo-{scene}{suffix}.avif")
    encode(raw, meta, AVIF_FPS, [
        "-vf", f"scale={w}:{h}:flags=lanczos,format=yuv420p",
        "-c:v", "libsvtav1", "-crf", crf, "-preset", "6", avif])
    print(f"{avif} {os.path.getsize(avif) // 1024} KB")
    if gif:
        out = os.path.join(out_dir, f"demo-{scene}{suffix}.gif")
        encode(raw, meta, GIF_FPS, [
            "-vf", "scale=960:600:flags=lanczos,split[a][b];"
                   "[a]palettegen=max_colors=128:stats_mode=diff[p];"
                   "[b][p]paletteuse=dither=none:diff_mode=rectangle",
            "-loop", "0", out])
        print(f"{out} {os.path.getsize(out) // 1024} KB")


if __name__ == "__main__":
    main()
