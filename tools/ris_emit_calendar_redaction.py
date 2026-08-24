#!/usr/bin/env python3
"""Name the terms that only a private calendar ever attested, and redact them.

**The RIS lane sent every calendar row to the model.** The AWS path does not —
`written_ontology.calendar_semantics` excludes an event unless positively
recognised, and promotes 5 of 101. Bypassing the privacy *projection* for
internal testing was authorised; bypassing the *allowlist* was not, and it put
915 terms from private diary entries into `semantic_private.presumed_terms`,
a table with **no `user_id`** — shared across every account.

123 of them are typed `person` and are other people's names. Fifteen are email
addresses. Those people are not users of this app and agreed to nothing, which
is the same argument that keeps the contacts upload out of the product.

**Scoped by lane, never by pattern.** A regex over names would be guessing
which strings look like people; which source attested a term is a fact. This
emits the terms whose *only* evidence is a calendar, and leaves anything a
music or video lane also saw alone — `Hyatt Place Princeton` stays if Spotify
named it too.

    python3 tools/ris_emit_calendar_redaction.py out/ris/verdicts_v15.json 0323
"""
from __future__ import annotations

import collections
import json
import pathlib
import re
import sys
import unicodedata

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
CALENDAR = {"apple_calendar", "google_calendar", "outlook_calendar"}

#: Mirrors `normalise` in ris_emit_dictionary.py — the dictionary's key.
RELEASE_SUFFIXES = (" - single", " - ep", " (single)", " (ep)",
                    " live version", " remastered", " single", " ep")

#: Families that name a natural person. A calendar-only term in one of these is
#: somebody's colleague, doctor or classmate, and is the case this exists for.
PERSONAL = {"person", "group", "organization"}


def normalise(text: str) -> str:
    value = unicodedata.normalize("NFKC", (text or "").strip()).casefold()
    value = re.sub(r"\s+", " ", value)
    changed = True
    while changed:
        changed = False
        for suffix in RELEASE_SUFFIXES:
            if value.endswith(suffix) and len(value) > len(suffix):
                value = value[: -len(suffix)].strip()
                changed = True
    return value


def quote(text) -> str:
    return "'" + str(text).replace("'", "''") + "'"


def main() -> int:
    verdicts = json.loads(pathlib.Path(sys.argv[1]).read_text())
    number = sys.argv[2]

    lanes: dict = collections.defaultdict(set)
    families: dict = collections.defaultdict(set)
    for verdict in verdicts["verdicts"]:
        source = verdict.get("source_code")
        for mention in verdict["mentions"]:
            key = normalise(mention.get("canonical_label_hypothesis")
                            or mention.get("surface") or "")
            family = mention.get("family_hypothesis")
            if not key or not family:
                continue
            lanes[key].add(source)
            families[key].add(family)

    calendar_only = {k for k, s in lanes.items() if s and s <= CALENDAR}
    personal = sorted(
        (k, f) for k in calendar_only for f in families[k] if f in PERSONAL)
    other = sorted(
        (k, f) for k in calendar_only for f in families[k] if f not in PERSONAL)

    out = [f"""-- {number} — a private diary is not vocabulary.
--
-- **The RIS lane sent every calendar row to the model.** The AWS path runs
-- `written_ontology.calendar_semantics` and excludes an event unless
-- positively recognised — the allowlist is the design, and it promotes 5 of
-- 101. The testing lane was licensed to bypass the privacy *projection* on the
-- owner's own data; it bypassed the *allowlist* too, which was never the
-- intent.
--
-- The result: {len(calendar_only)} terms whose only evidence is a private
-- calendar entered `presumed_terms`, a table with **no `user_id`** and
-- therefore shared across every account. {len(personal)} of them are typed as a
-- person, a group or an organization — colleagues, doctors, classmates — and
-- fifteen are email addresses. Those people are not users of this app.
--
-- **Redacted, not hidden, and not deleted.** Leaving the label and refusing the
-- card keeps the copy nobody can see while removing the one they could, which
-- this project already names as the worse of the two arrangements. And
-- `presumed_terms_no_delete` stays: the vault's own erasure redacts, and a row
-- that vanished would take with it the record that it was ever here.
--
-- **Scoped by lane, never by pattern.** Which source attested a term is a fact;
-- a regex over names would be guessing which strings look like people. A term a
-- music or video lane also saw is untouched — this is about evidence, not
-- spelling.

alter table semantic_private.presumed_terms
  add column if not exists excluded_reason text
    check (excluded_reason is null or excluded_reason in (
      -- A closed vocabulary from the start. A reason nobody can name is a
      -- reason nobody can lift, and this column decides what is never shown.
      'private_calendar'));

comment on column semantic_private.presumed_terms.excluded_reason is
  'Why this term may never become a card. Null is the normal case. Set by '
  '0323 for terms attested only by a private calendar; a term that later '
  'earns evidence from another lane may have it lifted, per term, by hand.';

do $$
declare
  redacted integer := 0;
  hidden integer := 0;
  n integer;
begin
"""]

    def block(rows: list, reason: str, redact: bool) -> None:
        if not rows:
            return
        values = ",\n    ".join(f"({quote(k)}, {quote(f)})" for k, f in rows)
        # **The name is in the key, so the key must go too.** `normalized_label`
        # holds `becky von trapp` and is what `review_item_is_coarse` and
        # `begin_calibration` join on; nulling only the display labels would
        # leave the person's name readable in the column every reader uses.
        # It is replaced with an opaque token rather than emptied: the row
        # survives, so foreign keys hold and the fact that something was
        # redacted here is still on the record, but nothing readable remains.
        # `canonical_label` cannot be blank — `presumed_terms_canonical_label_check`
        # requires it non-empty, which is how the first attempt at this failed.
        setters = ("normalized_label = 'redacted:' || pt.id::text, "
                   "canonical_label = 'redacted', english_label = null, "
                   "original_label = null, " if redact else "")
        out.append(f"""  update semantic_private.presumed_terms pt
     set {setters}excluded_reason = {quote(reason)}
    from (values
    {values}
  ) as excluded_term(normalized_label, family)
   where pt.normalized_label = excluded_term.normalized_label
     and pt.family = excluded_term.family
     and pt.excluded_reason is distinct from {quote(reason)};
  get diagnostics n = row_count;""")
        out.append(f"  {'redacted' if redact else 'hidden'} := "
                   f"{'redacted' if redact else 'hidden'} + n;")

    block(personal, "private_calendar", redact=True)
    block(other, "private_calendar", redact=False)

    out.append(f"""
  -- Anything email- or URL-shaped, in any family and from any lane. These are
  -- contact details rather than terms whatever attested them, and the shape is
  -- not a guess about meaning — it is the thing itself.
  update semantic_private.presumed_terms
     set normalized_label = 'redacted:' || id::text,
         canonical_label = 'redacted', english_label = null,
         original_label = null, excluded_reason = 'private_calendar'
   -- **No `excluded_reason` guard here, and that is the point.** The
   -- lane-scoped blocks above mark some rows without redacting them — an
   -- event title is not personal data — so a contact-shaped label that fell
   -- in that set would already carry a reason and be skipped. Five did. This
   -- sweep is about the shape of the string, never about what has already
   -- been decided for the row.
   where normalized_label ~ '@' or normalized_label ~ '^https?://';
  get diagnostics n = row_count;
  redacted := redacted + n;

  raise notice '{number}: % terms redacted, % more hidden', redacted, hidden;

  -- **Assert the state, not the count.** A replay has no dictionary, so zero is
  -- right there; what must never be true afterwards is a readable label on a
  -- term this migration excluded.
  select count(*) into n
    from semantic_private.presumed_terms
   where normalized_label ~ '@' or normalized_label ~ '^https?://';
  if n > 0 then
    raise exception
      '{number}: % contact-shaped labels are still readable in the key', n;
  end if;
end;
$$;
""")

    path = (REPOSITORY / "supabase" / "migrations"
            / f"{number}_a_private_diary_is_not_vocabulary.sql")
    path.write_text("\n".join(out) + "\n")
    print(json.dumps({"calendar_only_terms": len(calendar_only),
                      "redacted_personal": len(personal),
                      "hidden_other": len(other),
                      "migration": str(path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
