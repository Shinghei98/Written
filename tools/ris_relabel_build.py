#!/usr/bin/env python3
"""Select the terms whose native label merely echoes their surface.

Most CJK terms need no repair: `日曆` is Chinese, so `Calendar (日曆)` is
right. The affected set is the narrow one where the entity's own language
differs from the script it was written in — a Japanese character reached
through a Chinese title, a Korean name written in Han characters. This picks
exactly those and leaves everything else alone.
"""
from __future__ import annotations

import json, pathlib, re, sys, unicodedata

NON_LATIN = re.compile(r"[぀-ヿ㐀-䶵一-鿿가-힯]")
SUFFIX = (" - single"," - ep"," (single)"," (ep)"," live version",
          " remastered"," single"," ep")

def key(text: str) -> str:
    value = re.sub(r"\s+", " ",
                   unicodedata.normalize("NFKC", (text or "").strip()).casefold())
    changed = True
    while changed:
        changed = False
        for suffix in SUFFIX:
            if value.endswith(suffix) and len(value) > len(suffix):
                value = value[: -len(suffix)].strip(); changed = True
    return value

def main() -> int:
    verdicts = json.loads(pathlib.Path(sys.argv[1]).read_text())
    out = pathlib.Path(sys.argv[2])
    # **The title the term was seen in, not the source code.** Context is what
    # separates Sakura the idol from sakura the blossom, and it is the one
    # thing a name-only question cannot supply for itself.
    titles = {}
    items_path = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
    if items_path and items_path.is_file():
        for line in items_path.read_text().splitlines():
            if line.strip():
                item = json.loads(line)
                titles[item["row_id"]] = item["fields"].get("title", "")
    picked, seen = [], set()
    for verdict in verdicts["verdicts"]:
        for mention in verdict["mentions"]:
            surface = mention.get("surface") or ""
            native = mention.get("original_label") or ""
            english = mention.get("english_label") or ""
            label = mention.get("canonical_label_hypothesis") or surface
            k = key(label)
            if not k or k in seen:
                continue
            # Only where the surface is non-Latin AND the native just repeats
            # it. A native that already differs was answered correctly.
            if not NON_LATIN.search(surface):
                continue
            if native.strip() and native.strip() != surface.strip():
                continue
            seen.add(k)
            picked.append({"key": k, "label": label, "surface": surface,
                           "family": mention.get("family_hypothesis"),
                           "context_title": titles.get(verdict.get("row_id"), ""),
                           "had_english": english, "had_native": native})
    out.write_text("\n".join(json.dumps(p, ensure_ascii=False)
                             for p in picked) + "\n")
    print(json.dumps({"selected": len(picked), "out": str(out)}, indent=1))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
