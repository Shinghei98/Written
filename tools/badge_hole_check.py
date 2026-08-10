#!/usr/bin/env python3
"""Does the coach mark's hole sit exactly on the badge it is lighting?

The tutorial cuts its hole from `anchorPreference`, which reports *layout*
geometry, while the badge is drawn with whatever render transforms sit on it.
Those two agreeing is an invariant nothing in Swift enforces: an `.offset`, a
`.scaleEffect` or a `.rotationEffect` added anywhere between the anchor and the
pixels moves the badge and leaves the hole behind, silently. It has already
happened twice — the bob, worth 16.8 device pixels against 9 of clearance, and
the arrival spring.

So it is measured rather than looked at, which is this project's rule for
anything with a number in it.

    xcrun simctl launch <device> com.written.datingapp \
        -route home -stage 1 -tutorial badge
    xcrun simctl io <device> screenshot shot.png
    python3 tools/badge_hole_check.py shot.png

## How it reads the screenshot

Everything except the lit areas is under a 0.55 black dim, so undimmed parchment
(243) reads about 109 — the lit regions are the only bright pixels on screen.
Group them into connected components and the picture falls out on its own:

  * The badge's **gold ring** is bright in red and dark in blue, so it fails a
    brightness test and *splits the badge's hole into two components* — a ring
    of parchment outside the badge, and the badge's own interior inside it.
    That is a gift rather than a nuisance: the outer component is the hole and
    the inner one is the badge, measured independently, in one pass.
  * `updateConnection` also lights the "Connected to …" bar, which is a wide
    rectangle. It is discarded by aspect ratio.

**Nothing here assumes where on screen the badge is**, which is the point: a
check that knew the expected position would agree with itself.
"""

import sys

try:
    from PIL import Image
except ImportError:                                            # pragma: no cover
    sys.exit("needs Pillow: python3 -m pip install --user Pillow")


# Undimmed parchment is 243; under the dim it is about 109.
LIT_MIN = 190

# The mark fades in over 0.22s, and a screenshot inside that window has a
# *partial* dim — bright enough that the threshold above finds regions that are
# not holes at all. One run in five did exactly that and reported 12.2px against
# deformed boxes at a different x entirely, which is a check crying wolf. So the
# dim is verified before anything is measured: a pixel at the screen's edge,
# half way down, is somewhere no target is ever lit, and it must be at least as
# dark as a fully dimmed parchment.
DIMMED_MAX = 140

# Components below this are antialiasing, not areas. Counted on the sampled
# grid below, not on full-resolution pixels.
MIN_AREA = 200

# Sampling stride. The badge is ~150px across at @3x, so every second pixel is
# ample and it keeps a pure-Python flood fill quick.
STRIDE = 2

# How square a component must be to be one of the badge's two. The bar is about
# 6:1, so this is nowhere near it.
SQUARENESS = 0.25

# Device pixels. The whole point is that this is small — but it **must exceed
# `STRIDE`**, since every edge is measured on that grid and a true offset of
# zero reads as 0 or 2 depending on where the badge falls between samples. At
# 2.0 the check sat exactly on its own resolution and alternated pass and fail
# on an unchanged build. Four is still about 1.3 points, far under the 16.8 the
# bob was worth when this was actually broken.
MAX_OFFSET = 4.0


def components(image):
    """Connected regions of lit pixels, as (area, x0, y0, x1, y1)."""
    width, height = image.size
    pixels = image.load()
    cols, rows = width // STRIDE, height // STRIDE

    def lit(x, y):
        r, g, b = pixels[x * STRIDE, y * STRIDE][:3]
        return r >= LIT_MIN and g >= LIT_MIN and b >= LIT_MIN

    seen = [[False] * rows for _ in range(cols)]
    found = []
    for sx in range(cols):
        for sy in range(rows):
            if seen[sx][sy] or not lit(sx, sy):
                continue
            # Iterative, because a recursive fill overflows the stack on a
            # region this size.
            stack = [(sx, sy)]
            seen[sx][sy] = True
            min_x = max_x = sx
            min_y = max_y = sy
            area = 0
            while stack:
                x, y = stack.pop()
                area += 1
                if x < min_x: min_x = x
                if x > max_x: max_x = x
                if y < min_y: min_y = y
                if y > max_y: max_y = y
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < cols and 0 <= ny < rows and not seen[nx][ny] and lit(nx, ny):
                        seen[nx][ny] = True
                        stack.append((nx, ny))
            if area >= MIN_AREA:
                found.append((area, min_x * STRIDE, min_y * STRIDE,
                              max_x * STRIDE, max_y * STRIDE))
    return found


def is_squarish(box):
    width = box[3] - box[1]
    height = box[4] - box[2]
    if width == 0 or height == 0:
        return False
    return abs(width - height) / float(max(width, height)) <= SQUARENESS


def centre(box):
    return ((box[1] + box[3]) / 2.0, (box[2] + box[4]) / 2.0)


def main(path):
    image = Image.open(path).convert("RGB")

    # **Before anything is measured** — see `DIMMED_MAX`. A half-faded mark is
    # not a failure and must not be reported as one; it is a screenshot taken
    # too early, and the answer is to take another.
    width, height = image.size
    edge_pixel = image.load()[4, height // 2]
    if edge_pixel[0] > DIMMED_MAX:
        sys.exit("SKIP  the dim is not fully applied (edge red %d > %d) — "
                 "the mark is still fading in, screenshot a moment later"
                 % (edge_pixel[0], DIMMED_MAX))

    found = components(image)
    if not found:
        sys.exit("FAIL  nothing is lit — is a coach mark showing at all?")

    round_ones = sorted((c for c in found if is_squarish(c)),
                        key=lambda c: c[3] - c[1], reverse=True)
    if len(round_ones) < 2:
        sys.exit("FAIL  expected the badge's hole to split into two lit regions "
                 "either side of its gold ring, found %d — if the ring is a "
                 "partial arc the two merge, which means this badge is not the "
                 "connected one." % len(round_ones))

    hole, badge = round_ones[0], round_ones[1]
    hole_centre, badge_centre = centre(hole), centre(badge)
    dx = badge_centre[0] - hole_centre[0]
    dy = badge_centre[1] - hole_centre[1]
    offset = (dx * dx + dy * dy) ** 0.5

    print("hole   %4d x %4d at (%.1f, %.1f)"
          % (hole[3] - hole[1], hole[4] - hole[2], *hole_centre))
    print("badge  %4d x %4d at (%.1f, %.1f)"
          % (badge[3] - badge[1], badge[4] - badge[2], *badge_centre))
    print("offset  dx %+.1f  dy %+.1f  distance %.1f px" % (dx, dy, offset))

    if offset > MAX_OFFSET:
        # Vertical-only almost always means the bob has gone back to being a
        # render transform, since that is the only thing here that moves the
        # badge up and down.
        hint = "  (vertical only — has the bob left `.position`?)" if abs(dx) < 1 else ""
        sys.exit("FAIL  %.1f px > %.1f%s" % (offset, MAX_OFFSET, hint))
    print("PASS")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: badge_hole_check.py <screenshot.png>")
    main(sys.argv[1])
