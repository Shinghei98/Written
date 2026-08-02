#!/usr/bin/env python3
"""Turn accessibility-tree dumps into a list of layout defects.

Run `WrittenUITests` on a simulator, then point this at the build log (or an
extracted `.xcresult` attachment directory). It reports three things:

  overlap    two leaf elements intersecting that are not on the allowlist
  offscreen  an element whose frame is not inside the app's own frame
  clamped    a label whose width stops growing as the text size does

Why leaves only, and why an allowlist. This app overlaps *on purpose* and says
so: `MainTabBar` "overlays. It never takes layout height", and `ChatView` and
`DashboardView` deliberately slide their content under a pinned header. A naive
pairwise check reports every one of those and drowns the real findings. So
containers are skipped (a parent always contains its children), and intentional
leaf overlaps are recorded once in `layout_allowlist.json` — which then doubles
as the written record of every place this app stacks things on purpose.

Usage:
    python3 tools/layout_audit.py <run.log> [<run.log> ...]
    python3 tools/layout_audit.py --update-allowlist <run.log> ...
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOWLIST = os.path.join(HERE, "layout_allowlist.json")

BEGIN, END = "LAYOUT_AUDIT_BEGIN", "LAYOUT_AUDIT_END"

# XCUIElement.ElementType raw values that carry their own pixels. Anything else
# is scaffolding whose frame is the union of its children, and two of those
# intersecting means nothing.
LEAF_TYPES = {
    9: "image",
    10: "text",       # StaticText
    12: "button",
    13: "textField",
    14: "secureTextField",
    22: "switch",
    35: "slider",
    48: "textView",
    49: "icon",
}

# Smaller than this in either direction and it is a hairline or a spacer, not a
# widget somebody can see overlapping something.
MIN_SIDE = 4.0
# Ignore grazing intersections: a 1pt kiss between neighbouring rows is how
# SwiftUI rounds, not a defect.
MIN_OVERLAP_AREA = 12.0


def parse_runs(paths):
    """Yield (source, payload) for every dump in the given logs or directories.

    Two input shapes, because the test emits on two channels. A `.log` is
    scanned for the stdout markers; a directory is treated as `xcresulttool
    export attachments` output, one JSON payload per file. The attachments are
    the channel that actually works — a UI test *runner's* stdout does not reach
    `xcodebuild`, measured rather than assumed: a full 14-screen run produced
    `** TEST EXECUTE SUCCEEDED **` and zero markers.

    The source name is what tells the analyzer which content size a run was at,
    so keep "accessibility" in the path for those runs.
    """
    for path in paths:
        if os.path.isdir(path):
            for entry in sorted(os.listdir(path)):
                if not entry.endswith(".json") or entry == "manifest.json":
                    continue
                try:
                    with open(os.path.join(path, entry)) as handle:
                        yield os.path.basename(path.rstrip("/")), json.load(handle)
                except (json.JSONDecodeError, OSError):
                    print(f"  ! unreadable dump {entry}", file=sys.stderr)
            continue

        with open(path, "r", errors="replace") as handle:
            text = handle.read()
        for chunk in re.findall(
            re.escape(BEGIN) + r"\s*(.*?)\s*" + re.escape(END), text, re.S
        ):
            try:
                yield os.path.basename(path), json.loads(chunk)
            except json.JSONDecodeError:
                print(f"  ! unparseable dump in {path}", file=sys.stderr)


def leaves(node, out=None):
    out = [] if out is None else out
    children = node.get("children") or []
    if not children and node.get("type") in LEAF_TYPES:
        out.append(node)
    for child in children:
        leaves(child, out)
    return out


def box(node):
    f = node["frame"]
    return f["x"], f["y"], f["x"] + f["w"], f["y"] + f["h"]


def name(node):
    """A stable identity for a widget, independent of where it ended up.

    Coordinates are exactly what changes between devices, so keying on them
    would make an allowlist that only works on the phone it was generated from.
    """
    label = node.get("id") or node.get("label") or ""
    kind = node.get("kind") or LEAF_TYPES.get(node.get("type"), node.get("type"))
    return f"{kind}:{label[:60]}"


def overlap_area(a, b):
    ax0, ay0, ax1, ay1 = box(a)
    bx0, by0, bx1, by1 = box(b)
    w = min(ax1, bx1) - max(ax0, bx0)
    h = min(ay1, by1) - max(ay0, by0)
    return w * h if w > 0 and h > 0 else 0.0


def visible(node):
    f = node["frame"]
    return f["w"] >= MIN_SIDE and f["h"] >= MIN_SIDE


def nested(a, b):
    """Is one of these wholly inside the other, or are they the same widget?

    A button contains its own label and often an icon too, so `button:Continue`
    and `staticText:Continue` overlap completely and always will — that is what
    a button *is*. Containment is the honest test for it: a thing inside its own
    container is not colliding with anything.

    Same-label pairs are dropped as well, because the accessibility tree
    routinely exposes one widget twice (`button:7 admirers` alongside the
    `staticText` it wraps) and a widget cannot overlap itself.
    """
    if (a.get("label") or "\x00") == (b.get("label") or "\x01"):
        return True
    ax0, ay0, ax1, ay1 = box(a)
    bx0, by0, bx1, by1 = box(b)
    # A point of slack: a label is often laid out a hair outside the button's
    # rounded frame without meaning anything by it.
    a_in_b = ax0 >= bx0 - 1 and ay0 >= by0 - 1 and ax1 <= bx1 + 1 and ay1 <= by1 + 1
    b_in_a = bx0 >= ax0 - 1 and by0 >= ay0 - 1 and bx1 <= ax1 + 1 and by1 <= ay1 + 1
    return a_in_b or b_in_a


def onscreen(node, bounds):
    """Is any of this actually within the frame the user is looking at?

    Scrolled-away content is reported at large negative or off-bottom
    coordinates — a `ScrollView` keeps its children positioned wherever they
    are, so `profilePreview` legitimately has rows at y = -839. Those are not
    defects and must not be compared for overlap either, or every scroll view in
    the app reports its own contents colliding.
    """
    x0, y0, x1, y1 = box(node)
    sx0, sy0 = bounds["x"], bounds["y"]
    sx1, sy1 = sx0 + bounds["w"], sy0 + bounds["h"]
    return x1 > sx0 and x0 < sx1 and y1 > sy0 and y0 < sy1


def candidates(payload):
    """The elements to judge, preferring the accessibility-resolved list.

    `elements` comes from `descendants(...).allElementsBoundByAccessibilityElement`
    and therefore honours `.accessibilityHidden`, which is what keeps the four
    mounted-but-inactive tabs out of the comparison. `tree` is the raw snapshot
    and is kept only as a fallback for dumps taken before that existed.
    """
    if payload.get("elements") is not None:
        # Already narrowed to pixel-owning types by the queries that produced
        # it, so nothing to filter here.
        return payload["elements"]
    return leaves(payload.get("tree") or {})


def audit(payload):
    """Overlaps and off-screen frames for one screen."""
    if not payload.get("elements") and not payload.get("tree"):
        return [("missing", payload.get("screen", "?"), payload.get("error", "no tree"))]

    found = []
    bounds = payload["screenBounds"]
    items = [n for n in candidates(payload) if visible(n) and onscreen(n, bounds)]

    # The system keyboard is Apple's layout, not this app's. Its keys overlap
    # each other by design and were the only thing the name screen ever
    # reported. Drop anything inside it from the pairwise comparison — but keep
    # the frame, because a control of *ours* hidden under the keyboard is a real
    # defect on a short phone and is checked separately below.
    kb = payload.get("keyboard")
    if kb:
        kx0, ky0 = kb["x"], kb["y"]
        kx1, ky1 = kx0 + kb["w"], ky0 + kb["h"]

        def inside_keyboard(n):
            """Does it *begin* inside the keyboard? Then it belongs to it.

            Two stricter rules failed first, and the measurement says why. The
            keyboard's bottom row sits at y=620 with a height of 54 — running to
            674 against a keyboard frame that ends at 667, and a screen that also
            ends at 667. So `emoji`, `Dictate` and the return key each hang seven
            points below the keyboard they are part of: total containment misses
            them, and so does "90% of the area", because 47/54 is 87%.

            Starting inside is the honest test. Our own controls sit above the
            keyboard and get pushed further up by it; nothing of ours begins in
            the middle of it.
            """
            f = n["frame"]
            return (
                f["y"] >= ky0 - 1
                and f["x"] >= kx0 - 1
                and f["x"] + f["w"] <= kx1 + 1
            )

        buried = [
            n for n in items
            if not inside_keyboard(n)
            and overlap_area(n, {"frame": kb}) >= MIN_OVERLAP_AREA
        ]
        for node in buried:
            found.append(("under-keyboard", name(node), round(overlap_area(node, {"frame": kb}), 1)))

        items = [n for n in items if not inside_keyboard(n)]
    sx0, sy0 = bounds["x"], bounds["y"]
    sx1, sy1 = sx0 + bounds["w"], sy0 + bounds["h"]

    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            a, b = items[i], items[j]
            if nested(a, b):
                continue
            area = overlap_area(a, b)
            if area >= MIN_OVERLAP_AREA:
                pair = tuple(sorted((name(a), name(b))))
                found.append(("overlap", pair, round(area, 1)))

    for node in items:
        x0, y0, x1, y1 = box(node)
        # Horizontal only, and that is the point. A row running off the *side*
        # is a layout failure on a narrow phone — the thing this audit exists to
        # find. Running off the top or bottom is just a scroll view doing its
        # job, and `items` has already been filtered to things at least partly
        # on screen. The 1pt tolerance absorbs stroke and shadow bleed.
        if x0 < sx0 - 1 or x1 > sx1 + 1:
            found.append(("offscreen-x", name(node), [round(x0, 1), round(x1, 1)]))

    return found


def clamped(runs):
    """How the app answers Dynamic Type, and which labels grow *taller only*.

    **The obvious version of this check does not work, and the reason is the
    finding.** It flagged every label whose width did not grow at the larger
    content size — 126 of them on one device — because it cannot tell "this was
    clamped by its container" from "this never scaled in the first place". And
    almost nothing here scales: measured across an SE at default against the
    largest accessibility size, **14 of 222 element frames changed at all**. The
    app is built from `.system(size:)`, which is a fixed size; only the handful
    of `BrandFont` calls use `relativeTo:` and respond.

    So this reports two honest things instead of one dishonest one: the coverage
    number, and the labels that did react — of which the interesting ones are
    those that grew *taller but not wider*, since that is a line that has begun
    to wrap inside a fixed width and is the shape truncation takes here.
    """
    by_size = {}
    for source, payload in runs:
        size = "accessibility" if "access" in source.lower() else "default"
        for node in candidates(payload):
            kind = node.get("kind") or LEAF_TYPES.get(node.get("type"))
            if kind not in ("staticText", "text"):
                continue
            key = (payload.get("screen"), node.get("label", "")[:60])
            if not key[1]:
                continue
            f = node["frame"]
            prev = by_size.setdefault(key, {})
            # Widest instance wins, so a label repeated down a list is judged on
            # the roomiest place it appears rather than the tightest.
            best = prev.get(size, (0.0, 0.0))
            prev[size] = (max(best[0], f["w"]), max(best[1], f["h"]))

    grew, unchanged, wrapped = 0, 0, []
    for (screen, label), sizes in sorted(by_size.items()):
        if "default" not in sizes or "accessibility" not in sizes:
            continue
        (dw, dh), (aw, ah) = sizes["default"], sizes["accessibility"]
        if aw <= dw + 0.5 and ah <= dh + 0.5:
            unchanged += 1
            continue
        grew += 1
        # Taller but no wider: the text got bigger and the box did not, so the
        # line has started wrapping inside a width something else is holding.
        if aw <= dw + 0.5 and ah > dh + 0.5:
            wrapped.append((screen, label, dh, ah))
    return grew, unchanged, wrapped


def load_allowlist():
    if not os.path.exists(ALLOWLIST):
        return set()
    with open(ALLOWLIST) as handle:
        return {tuple(pair) for pair in json.load(handle).get("intentional_overlaps", [])}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    updating = "--update-allowlist" in sys.argv
    if not args:
        print(__doc__)
        return 1

    runs = list(parse_runs(args))
    if not runs:
        print("No dumps found. Did the test actually run?", file=sys.stderr)
        return 2

    allowed = load_allowlist()
    seen_pairs, defects = set(), []

    for source, payload in runs:
        screen = payload.get("screen", "?")
        for finding in audit(payload):
            kind = finding[0]
            if kind == "overlap":
                pair = finding[1]
                seen_pairs.add(pair)
                if pair in allowed:
                    continue
            defects.append((source, screen) + finding)

    print(f"Parsed {len(runs)} screen dumps from {len(args)} run(s).")
    print(f"Allowlisted intentional overlaps: {len(allowed)}\n")

    if updating:
        with open(ALLOWLIST, "w") as handle:
            json.dump(
                {
                    "_comment": "Overlaps this app makes on purpose. Reviewed by "
                                "hand — regenerating blindly hides real bugs.",
                    "intentional_overlaps": sorted(list(p) for p in seen_pairs),
                },
                handle,
                indent=2,
            )
        print(f"Wrote {len(seen_pairs)} pairs to {ALLOWLIST} — review them by hand.")
        return 0

    by_kind = {}
    for d in defects:
        by_kind.setdefault(d[2], []).append(d)

    for kind, items in sorted(by_kind.items()):
        print(f"=== {kind}  ({len(items)}) ===")
        for item in items[:40]:
            print("   ", item[0], "|", item[1], "|", *item[3:])
        if len(items) > 40:
            print(f"    … and {len(items) - 40} more")
        print()

    grew, unchanged, wrapped = clamped(runs)
    if grew or unchanged:
        share = 100.0 * grew / max(1, grew + unchanged)
        print("=== Dynamic Type ===")
        print(f"    {grew} of {grew + unchanged} labels respond to the largest "
              f"accessibility size ({share:.0f}%).")
        print("    The rest are `.system(size:)`, which is a fixed size and "
              "ignores it. Accessibility gap, not a layout one.")
        if wrapped:
            print(f"    {len(wrapped)} grew taller without growing wider "
                  f"(wrapping inside a held width):")
            for screen, label, dh, ah in wrapped[:20]:
                print(f"      {screen:<16} {label[:40]:<42} h {dh:5.1f} → {ah:5.1f}")
        print()

    print(f"{len(defects)} layout defect(s).")
    return 1 if defects else 0


if __name__ == "__main__":
    sys.exit(main())
