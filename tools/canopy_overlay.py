#!/usr/bin/env python3
"""Put the drawn canopy next to its template, at matched scale.

The whole reason this exists: four rounds of tuning the canopy's constants
produced no visible improvement, because every check was a crop or a summary
statistic rather than the two plants side by side. A fork height and a blade
aspect ratio can both match while the drawing still reads as another species.

Run it, look at the overlay, change one thing, run it again.

    python3 tools/canopy_overlay.py                 # build, launch, compare
    python3 tools/canopy_overlay.py --no-build      # reuse what is installed
    python3 tools/canopy_overlay.py --stage 3       # some other stage

Writes three panels side by side — template, ours, and the two superimposed in
contrasting colours — to tools/out/canopy_overlay.png.

Two traps, both already paid for once:

* **Location must be granted first.** Otherwise the permission sheet sits over
  the garden and gets measured instead of the plant, which produced a confident
  and entirely wrong "the plant moved 0.139" reading.
* **Let it settle.** The plant has an entrance animation and the sparkles never
  stop, so a screenshot taken too early compares two different moments. Ink is
  compared rather than pixels for the same reason.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import time

import numpy as np
from PIL import Image
from scipy.ndimage import binary_closing, binary_fill_holes, binary_dilation
from skimage.measure import label, regionprops
from skimage.morphology import remove_small_objects

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "tools" / "out"
# Kept in the repo, not read from Downloads. The first reference vanished from
# there mid-session and took the harness with it; a template that the comparison
# depends on belongs beside the code that is being compared to it.
TEMPLATE = ROOT / "tools" / "reference" / "canopy.png"

DEVICE = "D6B47BF8-65E2-4A9C-88FE-498A94F1C384"
BUNDLE = "com.written.datingapp"
SETTLE = 12.0

INK = 125          # below this is a drawn stroke rather than a pale vein
PANEL = 900        # height each panel is normalised to


def run(cmd: list[str], check: bool = True) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit(f"failed: {' '.join(cmd)}\n{result.stderr}")
    return result.stdout


def build_and_launch(stage: int, build: bool) -> pathlib.Path:
    if build:
        print("building…")
        run([
            "xcodebuild", "-project", str(ROOT / "Written.xcodeproj"),
            "-scheme", "Written", "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,name=iPhone 17 Pro", "build",
        ])
        settings = run([
            "xcodebuild", "-project", str(ROOT / "Written.xcodeproj"),
            "-scheme", "Written", "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,name=iPhone 17 Pro",
            "-showBuildSettings",
        ], check=False)
        products = next(
            line.split("= ", 1)[1].strip()
            for line in settings.splitlines() if "BUILT_PRODUCTS_DIR" in line
        )
        run(["xcrun", "simctl", "terminate", DEVICE, BUNDLE], check=False)
        run(["xcrun", "simctl", "install", DEVICE, f"{products}/Written.app"])

    # Before launching, never after: the sheet appears within a second of the
    # garden and there is no way to dismiss it from here.
    run(["xcrun", "simctl", "privacy", DEVICE, "grant", "location", BUNDLE], check=False)
    run(["xcrun", "simctl", "terminate", DEVICE, BUNDLE], check=False)
    run(["xcrun", "simctl", "launch", DEVICE, BUNDLE, "-route", "home", "-stage", str(stage)])

    print(f"settling {SETTLE:.0f}s…")
    time.sleep(SETTLE)
    OUT.mkdir(parents=True, exist_ok=True)
    shot = OUT / "shot.png"
    run(["xcrun", "simctl", "io", DEVICE, "screenshot", str(shot)])
    return shot


def gold_mask(rgb: np.ndarray) -> np.ndarray:
    """The badge rings, which are not part of the plant in either image."""
    r, g, b = rgb[..., 0].astype(int), rgb[..., 1].astype(int), rgb[..., 2].astype(int)
    gold = (r > 150) & (g > 110) & (b < 140) & (r - b > 55)
    if not gold.any():
        return np.zeros(gold.shape, bool)
    # Fill each ring to a disc so its contents go with it.
    filled = binary_fill_holes(binary_closing(gold, np.ones((9, 9))))
    return binary_dilation(filled, np.ones((11, 11)))


def isolate(path: pathlib.Path, box: tuple[float, float, float, float]) -> tuple[np.ndarray, dict]:
    """Plant ink, plus the landmarks the two images are aligned on.

    Landmarks are the soil crest and the crown's top — both unambiguous in each
    drawing, unlike the fork, which the skeleton finds in a slightly different
    place depending on how the cotyledons meet.
    """
    im = Image.open(path).convert("RGB")
    W, H = im.size
    im = im.crop((int(W * box[0]), int(H * box[1]), int(W * box[2]), int(H * box[3])))
    rgb = np.asarray(im)
    grey = np.asarray(im.convert("L"))

    ink = (grey < INK) & ~gold_mask(rgb)
    ink = remove_small_objects(ink, 40)
    if not ink.any():
        sys.exit(f"no ink found in {path}")

    # Find the plant rather than trusting a fixed crop. Our screenshot has a
    # title and a subtitle above the garden, each its own band of ink separated
    # by blank rows, and a hardcoded crop caught "profile" and measured *that*
    # as the plant. The garden is by far the tallest band, so take it.
    rows = ink.sum(axis=1) > 0
    bands, start = [], None
    for y, filled in enumerate(rows):
        if filled and start is None:
            start = y
        elif not filled and start is not None:
            bands.append((start, y))
            start = None
    if start is not None:
        bands.append((start, len(rows)))
    if bands:
        top, bottom = max(bands, key=lambda b: b[1] - b[0])
        keep = np.zeros_like(ink)
        keep[top:bottom, :] = True
        ink &= keep

    # The mound is the widest dark run; everything above its crest is plant.
    rows = ink.sum(axis=1)
    crest = int(np.argmax(rows > ink.shape[1] * 0.22))
    plant = ink.copy()
    plant[crest:, :] = False
    plant = remove_small_objects(plant, 60)
    ys, xs = np.where(plant)

    # Where the stem meets the soil, for horizontal alignment.
    band = plant[max(0, crest - 24):crest, :]
    stem_x = int(np.mean(np.where(band.any(axis=0))[0])) if band.any() else int(np.mean(xs))

    return plant, {"crest": crest, "top": int(ys.min()), "stem_x": stem_x}


def normalise(plant: np.ndarray, marks: dict) -> Image.Image:
    """Scale so every plant is the same height, foot on the same line."""
    height = marks["crest"] - marks["top"]
    scale = PANEL * 0.86 / max(height, 1)
    img = Image.fromarray((~plant * 255).astype(np.uint8))
    img = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)

    canvas = Image.new("L", (PANEL, PANEL), 255)
    # Foot on a fixed line, stem centred.
    dx = PANEL // 2 - int(marks["stem_x"] * scale)
    dy = int(PANEL * 0.92) - int(marks["crest"] * scale)
    canvas.paste(img, (dx, dy))
    return canvas


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", type=int, default=4)
    ap.add_argument("--no-build", action="store_true")
    args = ap.parse_args()

    if not TEMPLATE.exists():
        sys.exit(f"template not found: {TEMPLATE}")

    shot = build_and_launch(args.stage, build=not args.no_build)

    # The template is the plant alone; ours has a header above and bars below.
    tmpl, tmarks = isolate(TEMPLATE, (0.06, 0.02, 0.94, 0.90))
    ours, omarks = isolate(shot, (0.02, 0.08, 0.98, 0.68))

    a = normalise(tmpl, tmarks)
    b = normalise(ours, omarks)

    A = np.asarray(a) < 128
    B = np.asarray(b) < 128
    over = np.full(A.shape + (3,), 255, np.uint8)
    over[A] = [225, 70, 70]        # template only
    over[B] = [60, 95, 225]        # ours only
    over[A & B] = [35, 35, 35]     # both

    sheet = Image.new("RGB", (PANEL * 3 + 24, PANEL), (250, 249, 245))
    sheet.paste(a.convert("RGB"), (0, 0))
    sheet.paste(b.convert("RGB"), (PANEL + 12, 0))
    sheet.paste(Image.fromarray(over), (PANEL * 2 + 24, 0))
    path = OUT / "canopy_overlay.png"
    sheet.save(path)

    agree = (A & B).sum()
    print(f"\ntemplate ink {A.sum()}   ours {B.sum()}   overlapping {agree}")
    print(f"agreement: {200 * agree / (A.sum() + B.sum()):.1f}% of all ink")
    report(A, B)
    print(f"\n  {path}")
    print("  left = template,  middle = ours,  right = overlaid")
    print("  red = template only, blue = ours only, dark = both")


def blade_lengths(mask: np.ndarray) -> list[float]:
    """Every enclosed blade, longest first, as a fraction of plant height."""
    solid = binary_fill_holes(binary_closing(mask, np.ones((5, 5))))
    inside = remove_small_objects(solid & ~mask, 80)
    blades = [
        p.major_axis_length for p in regionprops(label(inside, connectivity=2))
        if 1.4 < p.major_axis_length / max(p.minor_axis_length, 1e-9) < 3.4
    ]
    ys, _ = np.where(mask)
    height = max(ys.max() - ys.min(), 1)
    return sorted((b / height for b in blades), reverse=True)


def report(A: np.ndarray, B: np.ndarray) -> None:
    """The handful of ratios that actually decide whether it reads right.

    Measured on both plants in the same normalised frame, because the whole
    failure this harness exists to stop was comparing a ratio taken against one
    drawing's own cotyledon with a ratio taken against another's.

    Targets, from the vector trace of the reference (tools/reference/canopy.svg):
    the stem runs 0.361 to 0.969 of the viewBox against a plant spanning 0.030
    to 0.969, so it is 0.647 of the plant's height; the largest side leaf is
    0.209 of the viewBox, 0.222 of the plant; and every blade is a lens of
    L/W 2.25 to 2.42.
    """
    print()
    ta, tb = blade_lengths(A), blade_lengths(B)
    ya, xa = np.where(A)
    yb, xb = np.where(B)
    wa = (xa.max() - xa.min()) / max(ya.max() - ya.min(), 1)
    wb = (xb.max() - xb.min()) / max(yb.max() - yb.min(), 1)
    print(f"  width / height        {wa:.3f}       {wb:.3f}")
    print(f"  largest blade         {ta[0]:.3f}       {tb[0]:.3f}")
    print(f"  largest side blade    {ta[2] if len(ta) > 2 else 0:.3f}       "
          f"{tb[2] if len(tb) > 2 else 0:.3f}      0.222")
    print(f"  blade count           {len(ta):3d}         {len(tb):3d}")
    print("  blades, longest first:")
    print("     template  " + " ".join(f"{v:.3f}" for v in ta[:8]))
    print("     ours      " + " ".join(f"{v:.3f}" for v in tb[:8]))


if __name__ == "__main__":
    main()
