#!/usr/bin/env python3
"""Where the plant sits, measured rather than remembered.

**This replaces a number nobody could use.** CLAUDE.md carried
*"`(858, 1626)` at stage 2 is the check that has caught every layout regression
here"* from 2026-07-29 to 2026-08-12, and in that time nobody ran it — first
because CoreSimulator was broken, then because nothing recorded **what those
coordinates measure**. Not the commit that introduced them, not the constants in
`SeedlingArt.swift`, not any tool. A pair of numbers with no method is folklore:
it cannot fail, so it cannot catch anything.

So this measures the illustration and prints the numbers, and `--baseline`
compares them against what was recorded. The first run's figures are below; the
value is not any single one of them but that the next run produces the same ones
or says which moved.

    xcrun simctl launch <device> com.written.datingapp -route home -stage 2
    xcrun simctl io <device> screenshot stage2.png
    python3 tools/plant_position_check.py stage2.png

## How it reads the screenshot

The garden is parchment `(243,239,233)` with near-black line art on it, so the
illustration is the only dark mass above the connected rows. Everything below
the illustration band is excluded by fraction of screen height rather than by
pixel, because that is the one thing that survives a change of device.

**It reports the base, not the centroid, as the primary figure.** The centroid
moves when a leaf is redrawn; the base is where the soil meets the parchment,
which is what `promptsReserve` and the header budget actually control — and
those are what every regression here has been about. `CLAUDE.md` records four
occasions when something consuming height at the bottom of the screen moved the
plant.

**Centre offset is reported signed and in pixels.** The plant is drawn slightly
left of centre by design; the number to watch is whether that offset *changes*,
not whether it is zero.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

# Measured 2026-08-12, iPhone 17 simulator, 1206x2622, `-route home -stage 2`,
# from the build at commit 9267bef. Every figure in device pixels.
#
# **Not a specification — a record of what was true once.** A difference against
# these is a question, not a failure: the plant is meant to move when the art
# changes. What it must not do is move when something *else* changes, which is
# the only way to notice.
BASELINE = {
    "screen": [1206, 2622],
    "dark_bbox": [297, 954, 841, 1519],
    "centroid": [589, 1358],
    "base_y": 1519,
    "centre_offset_x": -14,
}
# The first draft of these came from a different measurement than the one this
# tool performs — a row-density pass used while working out how to separate the
# mound from the line art — and the check failed on the very screenshot it was
# taken from. Left recorded because it is the failure mode a baseline has: a
# number copied from anywhere other than the tool's own output is a number that
# will be wrong exactly once and then be edited until it agrees.

PARCHMENT = (243, 239, 233)


def measure(path: pathlib.Path) -> dict:
    from PIL import Image

    image = Image.open(path).convert("RGB")
    width, height = image.size
    pixels = image.load()

    # The illustration band: below the header, above the connected rows. As
    # fractions, so the same numbers hold on a 375-point phone.
    top, bottom = int(height * 0.30), int(height * 0.62)

    xs: list[int] = []
    ys: list[int] = []
    for y in range(top, bottom):
        for x in range(width):
            if all(channel < 90 for channel in pixels[x, y]):
                xs.append(x)
                ys.append(y)

    if not xs:
        raise SystemExit(
            "no dark pixels in the illustration band — is this the garden at a "
            "stage with a plant, and did the launch use `-route home`?"
        )

    centre = width // 2
    centroid_x = sum(xs) // len(xs)
    return {
        "screen": [width, height],
        "dark_bbox": [min(xs), min(ys), max(xs), max(ys)],
        "centroid": [centroid_x, sum(ys) // len(ys)],
        "base_y": max(ys),
        "centre_offset_x": centroid_x - centre,
        "dark_pixels": len(xs),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("screenshot", type=pathlib.Path)
    parser.add_argument("--baseline", action="store_true",
                        help="compare against the recorded figures and exit non-zero on drift")
    args = parser.parse_args()

    found = measure(args.screenshot)
    print(json.dumps(found, indent=2))

    if not args.baseline:
        return

    if found["screen"] != BASELINE["screen"]:
        raise SystemExit(
            f"screen is {found['screen']} and the baseline is {BASELINE['screen']} — "
            "these figures are per-device and cannot be compared across them"
        )

    drift = {
        key: (BASELINE[key], found[key])
        for key in ("base_y", "centre_offset_x", "centroid", "dark_bbox")
        if BASELINE[key] != found[key]
    }
    if drift:
        for key, (was, now) in drift.items():
            print(f"  {key}: was {was}, now {now}", file=sys.stderr)
        raise SystemExit("the plant moved — decide whether that was intended")
    print("matches the baseline")


if __name__ == "__main__":
    main()
