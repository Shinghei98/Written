#!/usr/bin/env python3
"""Where a branch's stalks and leaf tips land, without building the app.

Adjusting a branch was costing a build, an install, a 26-second settle and a
screenshot — five minutes to move one number, almost none of it spent deciding
what the number should be.

Everything being adjusted is *placement*: where the rachis points and how far it
runs, where each leaflet leaves it, where its tip ends up. That is thirty lines
of geometry, so it is reproduced here and drawn over the template directly.
Converge here, then build once to confirm.

    python3 tools/branch_preview.py            # every canopy branch
    python3 tools/branch_preview.py R2         # one of them

**This is a tuning aid, not a second renderer.** It draws stalks as lines and
blades as ellipses; the real thing is ink with weight and a curved midrib. It is
only trusted about *positions*, which is all it is used for, and every constant
is read out of SeedlingArt.swift rather than copied, so the two cannot drift.
"""

from __future__ import annotations

import math
import pathlib
import re
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
ART = ROOT / "Written" / "Views" / "Tree" / "SeedlingArt.swift"
TEMPLATE = ROOT / "tools" / "reference" / "canopy.png"
OUT = ROOT / "tools" / "out"

ASPECT = 358 / 330
BASE = (0.515, 0.705)
STAGE = 4.0
NAMES = {0: "R1", 1: "L1", 2: "L2", 3: "R2"}


# ---------------------------------------------------------------- read the art

def swift_text() -> str:
    return ART.read_text()


def const_list(name: str) -> list[float]:
    m = re.search(rf"static let {name}: \[CGFloat\] = \[(.*?)\]", swift_text(), re.S)
    return [float(v) for v in re.findall(r"-?\d*\.?\d+", m.group(1))]


def parse_shoots(marker: str, end: str) -> list[dict]:
    text = swift_text()
    start = text.index(marker)
    block = text[start:text.index(end, start)]

    shoots = []
    for chunk in re.split(r"\n        Shoot\(", block)[1:]:
        ident = int(re.search(r"id:\s*(\d+)", chunk).group(1))
        attach = float(re.search(r"attachment:\s*([\d.]+)", chunk).group(1))
        reach = re.search(r"reach:\s*CGSize\(width:\s*(-?[\d.]+),\s*height:\s*(-?[\d.]+)\)", chunk)
        turn = float(re.search(r"turn:\s*(-?[\d.]+)", chunk).group(1))
        bow = re.search(r"bow:\s*(-?[\d.]+)", chunk)

        leaflets = []
        for lm in re.finditer(
            r"Leaflet\(mirrored:\s*(true|false),\s*axis:\s*(-?[\d.]+),\s*scale:\s*([\d.]+),"
            r"\s*along:\s*([\d.]+),\s*stalkRun:\s*(?:\.zero|CGSize\(width:\s*(-?[\d.]+),"
            r"\s*height:\s*(-?[\d.]+)\))(.*?)\)", chunk, re.S
        ):
            mirrored, axis, scale, along, sx, sy, tail = lm.groups()
            # A leaflet that only opens later, or gives way, is not on the plant
            # at this stage; skipping it here matches SeedlingArt.isOpen.
            if "closesAt: .canopy" in tail:
                continue
            lbow = re.search(r"bow:\s*(-?[\d.]+)", tail)
            leaflets.append(dict(
                mirrored=mirrored == "true", axis=float(axis), scale=float(scale),
                along=float(along), bow=float(lbow.group(1)) if lbow else 0.0,
                stalk=(float(sx) if sx else 0.0, float(sy) if sy else 0.0),
            ))
        if reach is None:
            continue
        shoots.append(dict(
            id=ident, attachment=attach, turn=turn,
            bow=float(bow.group(1)) if bow else 0.0,
            reach=(float(reach.group(1)), float(reach.group(2))),
            leaflets=leaflets,
        ))
    return shoots


def canopy_shoots() -> list[dict]:
    """The four branches as the canopy draws them.

    A canopy branch that has not been adjusted is written `shoots[N]`, and one
    that has kept its leaflets is written `leaflets: shoots[N].leaflets`. Both
    are resolved against the frozen set here — without that, the two branches
    still untouched are simply absent from the preview, which is exactly when
    seeing them matters most.
    """
    shared = {s["id"]: s for s in parse_shoots(
        "static let shoots: [Shoot] = [", "\n    /// The same four branches")}
    canopy = {s["id"]: s for s in parse_shoots(
        "static let canopyShoots: [Shoot] = [", "\n    /// The shoots grown by")}

    text = swift_text()
    block = text[text.index("static let canopyShoots: [Shoot] = ["):
                 text.index("\n    /// The shoots grown by")]

    out = []
    for ident in sorted(shared):
        shoot = dict(canopy.get(ident, shared[ident]))
        # `leaflets: shoots[N].leaflets` — kept from the frozen set.
        if not shoot["leaflets"]:
            shoot["leaflets"] = shared[ident]["leaflets"]
        out.append(shoot)
    # Whole branches written as a bare `shoots[N]` never appear as a Shoot(
    # literal in the canopy block, so they arrive here from `shared` untouched,
    # which is correct: that is what the drawing does with them.
    return out


# ------------------------------------------------------------------- geometry

def fork_x(extended: float) -> float:
    canopy = min(max(extended - 3, 0), 1)
    return 0.500 + (0.528 - 0.500) * canopy


def turned_about_foot(p, degrees):
    r = math.radians(degrees)
    c, s = math.cos(r), math.sin(r)
    dx = (p[0] - BASE[0]) * ASPECT
    dy = p[1] - BASE[1]
    return (BASE[0] + (dx * c + dy * s) / ASPECT, BASE[1] + (-dx * s + dy * c))


def junction(extended: float):
    forks = const_list("forkHeights")
    along = min(max(extended, 0), len(forks) - 1)
    i = int(along)
    into = along - i
    y = forks[i] + (forks[min(i + 1, len(forks) - 1)] - forks[i]) * into
    p = (fork_x(extended), y)
    canopy = min(max(extended - 3, 0), 1)
    return turned_about_foot(p, 2.0 * canopy) if canopy > 0 else p


def stem_length(extended: float) -> float:
    return (BASE[1] - junction(extended)[1]) / ASPECT


def stem_point(t: float, extended: float):
    head = junction(extended)
    lean = const_list("canopyLean")
    a = min(max(t, 0), 1) * (len(lean) - 1)
    i = min(int(a), len(lean) - 2)
    off = (lean[i] + (lean[i + 1] - lean[i]) * (a - i)) * stem_length(extended)
    return (BASE[0] + (head[0] - BASE[0]) * t + off, BASE[1] + (head[1] - BASE[1]) * t)


def turned(v, degrees):
    if degrees == 0:
        return v
    tall = 1 / ASPECT
    x, y = v[0], v[1] * tall
    a = math.radians(degrees)
    return (x * math.cos(a) - y * math.sin(a), (x * math.sin(a) + y * math.cos(a)) / tall)


def attachment_t(shoot, extended: float) -> float:
    """A shoot keeps its height and loses share as the stem grows past it."""
    stage = {0: 1, 1: 2, 2: 3, 3: 4}[shoot["id"]]
    return shoot["attachment"] * stem_length(stage) / stem_length(extended)


def geometry(shoot, extended: float = STAGE):
    """Rachis root and tip, each leaflet's branch point and tip."""
    origin = stem_point(attachment_t(shoot, extended), extended)
    root = (origin[0], origin[1] + 0.012)
    stage = {0: 1, 1: 2, 2: 3, 3: 4}[shoot["id"]]
    grown = 1 + 0.38 * min(max(extended - stage, 0), 1)
    grown *= 1 - 0.20 * min(max(extended - 3, 0), 1)

    run = turned((shoot["reach"][0], -shoot["reach"][1]), shoot["turn"])
    tip = (origin[0] + run[0] * grown, origin[1] + run[1] * grown)

    out = dict(root=root, tip=tip, leaflets=[])
    for leaf in shoot["leaflets"]:
        a = leaf["along"]
        branch = (root[0] + (tip[0] - root[0]) * a, root[1] + (tip[1] - root[1]) * a)
        srun = turned(leaf["stalk"], shoot["turn"])
        lbase = (branch[0] + srun[0] * grown, branch[1] + srun[1] * grown)
        # Where the petiole's curve bulges, so a bowed stalk is visibly bowed
        # here too. Without this the preview draws every petiole straight and
        # cannot show the one thing being changed.
        bmid = midpoint_bowed(branch, lbase, leaf.get("bow", 0.0))
        # Blade reach along its own axis, the same figures leafletTip uses.
        box = (0.230, 0.312)
        side = 1 if leaf["mirrored"] else -1
        scale = leaf["scale"] * grown
        rx, ry = 0.50 * box[0] * scale * side, -0.94 * box[1] * scale
        ang = math.radians(leaf["axis"])
        tall = 1 / ASPECT
        x, y = rx, ry * tall
        ltip = (lbase[0] + x * math.cos(ang) - y * math.sin(ang),
                lbase[1] + (x * math.sin(ang) + y * math.cos(ang)) / tall)
        out["leaflets"].append(dict(branch=branch, base=lbase, tip=ltip,
                                    scale=scale, bend=bmid))
    return out


def midpoint_bowed(root, tip, bow):
    """Halfway along a bowed stalk — the same push `bowed` applies in Swift."""
    if bow == 0:
        return ((root[0] + tip[0]) / 2, (root[1] + tip[1]) / 2)
    dx = (tip[0] - root[0]) * ASPECT
    dy = tip[1] - root[1]
    length = math.hypot(dx, dy)
    if length == 0:
        return root
    push = bow * length
    cx = (root[0] + tip[0]) / 2 + (dy / length) * push / ASPECT
    cy = (root[1] + tip[1]) / 2 + (-dx / length) * push
    # A quadratic at t=0.5 sits halfway between its chord's midpoint and control.
    return ((root[0] + tip[0]) / 4 + cx / 2, (root[1] + tip[1]) / 4 + cy / 2)


# ---------------------------------------------------------------------- draw

def main() -> None:
    want = sys.argv[1].upper() if len(sys.argv) > 1 else None
    shoots = canopy_shoots()

    size = 900
    img = Image.open(TEMPLATE).convert("RGB").resize((size, size), Image.LANCZOS)
    img = Image.blend(img, Image.new("RGB", img.size, (255, 255, 255)), 0.55)
    d = ImageDraw.Draw(img)

    # The template's own plant, foot to fork, so ours can be laid over it: its
    # stem runs 0.965 to 0.363 of the viewBox against ours at 0.705 to 0.155.
    def to_px(p):
        # our canvas -> template frame, matched on the stem's foot and fork
        tx = (p[0] - BASE[0]) / stem_length(STAGE) * 0.602 * (1 / ASPECT)
        ty = (p[1] - BASE[1]) / (BASE[1] - junction(STAGE)[1]) * 0.602
        return ((0.4825 + tx) * size, (0.965 + ty) * size)

    print(f"{'branch':6s} {'attach t':>9s}  rachis tip (template frame)   leaf tips")
    for shoot in shoots:
        name = NAMES[shoot["id"]]
        if want and name != want:
            continue
        g = geometry(shoot)
        d.line([to_px(g["root"]), to_px(g["tip"])], fill=(220, 40, 40), width=4)
        for leaf in g["leaflets"]:
            d.line([to_px(leaf["branch"]), to_px(leaf["bend"]), to_px(leaf["base"])],
                   fill=(220, 40, 40), width=3, joint="curve")
            d.line([to_px(leaf["base"]), to_px(leaf["tip"])], fill=(30, 90, 220), width=3)
            x, y = to_px(leaf["tip"])
            d.ellipse([x - 6, y - 6, x + 6, y + 6], outline=(30, 90, 220), width=3)
        tips = "  ".join(f"({to_px(l['tip'])[0]/size:.3f},{to_px(l['tip'])[1]/size:.3f})"
                         for l in g["leaflets"])
        print(f"{name:6s} {attachment_t(shoot, STAGE):9.3f}  "
              f"({to_px(g['tip'])[0]/size:.3f},{to_px(g['tip'])[1]/size:.3f})            {tips}")

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "branch_preview.png"
    img.save(path)
    print(f"\n  {path}")
    print("  red = stalks, blue = blade axis, circle = leaf tip, over the template")


if __name__ == "__main__":
    main()
