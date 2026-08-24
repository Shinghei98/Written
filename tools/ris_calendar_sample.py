#!/usr/bin/env python3
"""Draw calendar events at random and show what the gate decided about each.

**This check has been a throwaway script twice, and both times it found
something.** The first draw found that the RIS lane was sending every calendar
row to the model — private diary entries, other people's names, fifteen email
addresses — into a table with no `user_id`. The second, after that was fixed,
found the opposite: of 39 structured bookings in the whole corpus the gate was
admitting two, and the ones it refused were restaurants, hotels and a second
flight format nothing parsed. A filter is only checkable if its refusals are
visible, so the third time it should be a tool.

    python3 tools/ris_calendar_sample.py                 # 20 random events
    python3 tools/ris_calendar_sample.py --count 40
    python3 tools/ris_calendar_sample.py --verdict booked_activity
    python3 tools/ris_calendar_sample.py --user Timi --seed 20260823

**The seed is printed and re-usable**, so a draw can be repeated after a change
and the difference attributed to the change rather than to a new sample.

`--verdict` inspects one bucket whole rather than sampling it, which is how the
booking gate's two-of-thirty-nine was found: the modal outcome hides the
interesting one.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import random
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "tools"))
sys.path.insert(0, str(REPOSITORY / "semantic" / "src"))

from ris_build_items import (  # noqa: E402
    CALENDAR,
    airport_cities,
    calendar_gate,
    fields_for,
    query,
)

#: Names for the accounts, so a draw is readable. **Not a lookup that decides
#: anything** — the cross-account defect this tool exists to catch was found by
#: seeing three names beside events one person could not have attended.
KNOWN = {
    "7046df73": "Timi",
    "eb769605": "David",
    "076f08f9": "Demo",
}


def label_for(user_id: str) -> str:
    return KNOWN.get((user_id or "")[:8], (user_id or "?")[:8])


def calendar_rows() -> list[dict]:
    """One row per distinct event, since the table is append-only.

    `distilled_records` holds every distillation, so an event re-distilled
    three times is three rows and a naive sample over-represents whoever
    re-distilled most. Distinct on owner, title and start is the event.
    """
    return query(
        """
        select distinct on (d.user_id, d.name, d.extra->>'start')
               d.user_id, d.source, d.name, d.detail, d.extra,
               d.item_id, d.data_type
          from public.distilled_records d
         where d.source in ('apple_calendar', 'google_calendar', 'outlook_calendar')
         order by d.user_id, d.name, d.extra->>'start'
        """
    )


def verdict_of(decision) -> tuple[str, str | None]:
    value = getattr(getattr(decision, "disposition", None), "value", None)
    return value or "classifier_unavailable", getattr(decision, "reason", None)


def render(index: int, row: dict, decision, admitted: set[str]) -> None:
    verdict, reason = verdict_of(decision)
    extra = row.get("extra") or {}
    mark = "ADMITTED" if verdict in admitted else "excluded"
    print(f"\n{index:>3}. [{label_for(row['user_id'])}] "
          f"{str(extra.get('start'))[:16]}  ({row['source']})  {mark}")
    print(f"     title : {row['name']!r}")
    if row.get("detail"):
        print(f"     detail: {str(row['detail'])[:110]!r}")
    print(f"     cal   : {extra.get('calendar')!r}  type={extra.get('cal_type')!r}"
          f"  booked={extra.get('booked')}  cancelled={extra.get('cancelled')}")
    print(f"     -> {verdict}" + (f"  ({reason})" if reason and reason != verdict else ""))
    if verdict in admitted:
        # **What would actually travel**, not what the row holds. The gap
        # between the two is where a street address or an organiser's name
        # would show up, and it is the thing worth reading in an admitted row.
        print(f"     sends : {json.dumps(fields_for(row), ensure_ascii=False)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--seed", type=int, default=None,
                        help="reuse a printed seed to repeat a draw exactly")
    parser.add_argument("--verdict", default=None,
                        help="show every event with this disposition, unsampled")
    parser.add_argument("--user", default=None,
                        help="one account, by name (Timi) or id prefix")
    arguments = parser.parse_args()

    classifier = calendar_gate()
    if classifier is None:
        print("classifier unavailable; nothing can be judged", file=sys.stderr)
        return 1

    rows = calendar_rows()
    classifier.ris_airport_cities = airport_cities(rows)
    if arguments.user:
        wanted = arguments.user.casefold()
        rows = [row for row in rows
                if label_for(row["user_id"]).casefold() == wanted
                or row["user_id"].startswith(arguments.user)]

    admitted = {"flight_segment", "booked_activity"}
    judged = [(row, classifier.classify(row)) for row in rows]

    if arguments.verdict:
        chosen = [(row, decision) for row, decision in judged
                  if verdict_of(decision)[0] == arguments.verdict]
        print(f"{len(chosen)} of {len(judged)} events answer "
              f"{arguments.verdict!r} — all shown")
    else:
        seed = arguments.seed if arguments.seed is not None \
            else random.randrange(1, 10**9)
        random.seed(seed)
        chosen = random.sample(judged, min(arguments.count, len(judged)))
        print(f"{len(chosen)} of {len(judged)} distinct calendar events, "
              f"seed {seed} (pass --seed {seed} to repeat this draw)")

    for index, (row, decision) in enumerate(chosen, 1):
        render(index, row, decision, admitted)

    tally: dict[str, int] = {}
    for _, decision in judged:
        key = verdict_of(decision)[0]
        tally[key] = tally.get(key, 0) + 1
    print("\n" + json.dumps({
        "events": len(judged),
        "admitted": sum(count for key, count in tally.items() if key in admitted),
        "verdicts": dict(sorted(tally.items(), key=lambda item: -item[1])),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
