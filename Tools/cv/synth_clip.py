#!/usr/bin/env python3
"""Draws a cartoon shooting clip for smoke-testing cv-replay's plumbing.

    python3 -I Tools/cv/synth_clip.py out.mp4 [--rotate 90] [--size 1920x1080]

Two shots from the left of the frame at a hoop on the right: a make (the
ball drops through the rim and the net swings) then a miss (short, off
the front of the rim, to the floor). A corner marker ("TOP LEFT", red
square) makes orientation mistakes obvious in cv-replay's strips.
labels.csv for it is written next to the clip (seconds at the rim).

It's a drawing, not footage: the shipped detector may or may not see the
ball or the hoop in it. Use it to check frames, timestamps, orientation and
outputs end to end; use real footage to judge detection.

--rotate N stores the frames turned by N degrees and tags the file so a
player shows them upright again (as a phone does), to exercise
preferredTransform handling. Needs numpy, Pillow and ffmpeg.
"""

import argparse
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

FPS = 30


def ball_path(t, start, apex_y, end, t0, t1):
    """Parabola from start to end (pixels, y down) with its top at apex_y."""
    u = (t - t0) / (t1 - t0)
    x = start[0] + (end[0] - start[0]) * u
    # y(u) = a u^2 + b u + c through start (u=0), end (u=1), min apex_y.
    c = start[1]
    # Choose b so that the vertex height is apex_y: solve numerically.
    lo, hi = -10000.0, 0.0
    for _ in range(80):
        b = (lo + hi) / 2
        a = end[1] - c - b
        vertex = c - b * b / (4 * a) if a > 0 else c
        if vertex > apex_y:
            hi = b
        else:
            lo = b
    a = end[1] - c - b
    return x, a * u * u + b * u + c


def draw_frame(t, size, shots):
    W, H = size
    s = W / 1920
    img = Image.new("RGB", (W, H), (150, 140, 125))
    d = ImageDraw.Draw(img)
    # Floor.
    d.rectangle([0, int(H * 0.72), W, H], fill=(176, 120, 70))
    for i in range(0, W, int(90 * s)):
        d.line([i, int(H * 0.72), i - int(200 * s), H], fill=(160, 105, 60), width=2)
    # Orientation marker.
    d.rectangle([int(20 * s), int(20 * s), int(120 * s), int(120 * s)], fill=(220, 30, 30))
    try:
        font = ImageFont.truetype("DejaVuSans-Bold.ttf", int(48 * s))
    except OSError:
        font = ImageFont.load_default()
    d.text((int(140 * s), int(40 * s)), "TOP LEFT", fill=(255, 255, 255), font=font)

    # Backboard, rim, net (rim centre at rim_c).
    rim_c = (1475 * s, 520 * s)
    rim_w, rim_h = 150 * s, 26 * s
    d.rectangle([rim_c[0] - 170 * s, rim_c[1] - 250 * s, rim_c[0] + 170 * s, rim_c[1] + 20 * s],
                fill=(245, 245, 245), outline=(40, 40, 40), width=int(4 * s))
    d.rectangle([rim_c[0] - 55 * s, rim_c[1] - 120 * s, rim_c[0] + 55 * s, rim_c[1] - 10 * s],
                outline=(200, 40, 30), width=int(6 * s))
    d.rectangle([rim_c[0] - 8 * s, rim_c[1] + 20 * s, rim_c[0] + 8 * s, H * 0.72], fill=(60, 60, 70))

    # Net swings for a second after a make.
    swing = 0.0
    for shot in shots:
        if shot["make"] and shot["rim"] <= t <= shot["rim"] + 1.0:
            k = t - shot["rim"]
            swing = 14 * s * math.exp(-3 * k) * math.sin(2 * math.pi * 4 * k)
    top_l, top_r = rim_c[0] - rim_w / 2, rim_c[0] + rim_w / 2
    bot_y = rim_c[1] + 120 * s
    bot_l, bot_r = rim_c[0] - rim_w * 0.3 + swing, rim_c[0] + rim_w * 0.3 + swing
    for i in range(9):
        u = i / 8
        d.line([top_l + (top_r - top_l) * u, rim_c[1], bot_l + (bot_r - bot_l) * u, bot_y],
               fill=(250, 250, 250), width=max(1, int(3 * s)))
    for j in range(1, 5):
        v = j / 5
        y = rim_c[1] + (bot_y - rim_c[1]) * v
        xl = top_l + (bot_l - top_l) * v
        xr = top_r + (bot_r - top_r) * v
        d.line([xl, y, xr, y], fill=(250, 250, 250), width=max(1, int(2 * s)))

    # Ball(s).
    r = 24 * s
    for shot in shots:
        t0, t_rim, t_end = shot["t0"], shot["rim"], shot["rim"] + 1.2
        if not (t0 <= t <= t_end):
            continue
        start = (shot.get("x", 260) * s, 640 * s)
        if shot["make"]:
            target = (rim_c[0], rim_c[1])
        else:
            target = (rim_c[0] - rim_w / 2 - r * 1.2, rim_c[1] - r * 0.3)
        if t <= t_rim:
            x, y = ball_path(t, start, shot.get("apex", 160) * s, target, t0, t_rim)
        else:
            k = t - t_rim
            if shot["make"]:
                x, y = target[0], target[1] + 300 * s * k + 600 * s * k * k
            else:
                x, y = target[0] - 120 * s * k, target[1] + 120 * s * k + 900 * s * k * k
            y = min(y, H * 0.72 + 40 * s)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(222, 110, 30), outline=(40, 20, 10), width=max(1, int(2 * s)))
        d.line([x - r, y, x + r, y], fill=(40, 20, 10), width=max(1, int(2 * s)))
        d.arc([x - r * 0.6, y - r, x + r * 0.6, y + r], 0, 360, fill=(40, 20, 10), width=max(1, int(2 * s)))
        # Rim drawn over a ball that's going through it (front of the rim).
    d.ellipse([rim_c[0] - rim_w / 2, rim_c[1] - rim_h / 2, rim_c[0] + rim_w / 2, rim_c[1] + rim_h / 2],
              outline=(235, 80, 20), width=int(7 * s))
    return img


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270])
    p.add_argument("--size", default="1920x1080")
    p.add_argument("--seconds", type=float, default=None,
                   help="length (default: 8 s, or long enough for --shots)")
    p.add_argument("--shots", type=int, default=2,
                   help="number of shots, alternating make / miss, 3.5 s apart, from varied spots")
    args = p.parse_args()
    W, H = (int(v) for v in args.size.split("x"))
    shots = [dict(t0=1.0, rim=2.2, make=True), dict(t0=4.5, rim=5.7, make=False)]
    if args.shots != 2:
        shots = []
        for i in range(args.shots):
            t0 = 1.0 + 3.5 * i
            flight = 1.0 + 0.1 * (i % 5)
            shots.append(dict(t0=t0, rim=round(t0 + flight, 2), make=i % 2 == 0,
                              x=200 + 110 * (i % 6), apex=120 + 35 * (i % 4)))
    if args.seconds is None:
        args.seconds = max(8.0, shots[-1]["rim"] + 2.5) if shots else 8.0

    # Stored frames are turned so that a player applying the tag shows them upright.
    stored = {0: None, 90: Image.Transpose.ROTATE_90, 180: Image.Transpose.ROTATE_180,
              270: Image.Transpose.ROTATE_270}[args.rotate]
    w, h = (H, W) if args.rotate in (90, 270) else (W, H)
    encoded = args.out + ".stored.mp4" if args.rotate else args.out
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
           "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
           "-movflags", "+faststart", encoded]
    enc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for i in range(int(args.seconds * FPS)):
        img = draw_frame(i / FPS, (W, H), shots)
        if stored is not None:
            img = img.transpose(stored)
        enc.stdin.write(np.asarray(img, dtype=np.uint8).tobytes())
    enc.stdin.close()
    if enc.wait() != 0:
        sys.exit("ffmpeg failed")
    if args.rotate:
        # Tag the stored (counter-clockwise turned) frames to be shown
        # turned back clockwise. A stream copy keeps ffmpeg from applying
        # the tag itself; its angle is counter-clockwise.
        tag = ["ffmpeg", "-y", "-loglevel", "error", "-display_rotation", str(-args.rotate), "-i", encoded,
               "-c", "copy", "-movflags", "+faststart", args.out]
        if subprocess.call(tag) != 0:
            sys.exit("ffmpeg (rotation tag) failed")
        os.remove(encoded)
    labels = args.out.rsplit(".", 1)[0] + ".labels.csv"
    with open(labels, "w") as f:
        f.write("# seconds,result — when the ball reaches the rim\n")
        for s_ in shots:
            f.write(f"{s_['rim']:.2f},{'make' if s_['make'] else 'miss'}\n")
    print(f"wrote {args.out} and {labels}")


if __name__ == "__main__":
    main()
