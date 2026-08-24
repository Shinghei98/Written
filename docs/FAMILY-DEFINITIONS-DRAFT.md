# Family definitions — draft, revision 2

**Status: draft. Nothing is wired to anything.** Proposed
`prompt.family_definitions` for the extraction prompt, which today carries **no
definition of any family or root**.

Each family has a **`definition`** — the line sent to the model, kept short
because it costs prompt budget — and a **`why`** note, which is not sent.

**Revision 2 applies the owner's decisions of 2026-08-24:** `conversation_worthy`
forced true; `idea` removed; `culture` redefined as country-scoped; `art` added;
`cardinal:concept` restricted to exactly those two.

---

## 0. The governing rule

> **A term is coined only when it satisfies one of these definitions. A title
> that satisfies none yields no terms, and that is a correct answer, not a
> failure.**

**Why it comes first.** On the v16 run, **33 of 3,603 items produced zero
mentions — 0.9%**. 66% produced three or more; **15% hit the ceiling of five**. A
cap struck that often means the model would have gone further. It is not
choosing badly among families; it is not choosing *whether*.

---

## 1. The eight cardinal roots

Verbatim from `0291:29-45`, already yours and immutable. **Proposal: send these
too** (~430 chars) so the families can lean on them rather than repeat them.

| root | definition |
|---|---|
| `person` | A natural individual. |
| `group` | A named collective whose collective identity or membership matters. |
| `organization` | A durable institutional, legal, commercial, educational, or governing body. |
| `work` | A bounded authored, recorded, published, designed, or released creation. |
| `franchise` | A persistent intellectual-property, continuity, or branded universe spanning one or more works. |
| `activity` | A repeatable human practice, skill, hobby, sport, or mode of doing. |
| `concept` | An abstract subject, discipline, method, theory, style, movement, or idea. |
| `event` | A time-bounded public occurrence or eligible public occurrence identity. |

---

## 2. The families

### person → `cardinal:person`
**definition:** A specific named human being. **Not** a nickname, honorific or
term of endearment used *about* someone; **not** a character unless the character
is the durable subject. A word of address opening a title is not a person — use
`incidental_context`.

*why:* Already 35.5% of mentions, the largest family. `fx_104` failed on a
nickname read as a person, so this boundary must push outward.

### group → `cardinal:group`
**definition:** A named collective whose members perform, compete or create
together and whose collective identity is what people refer to — a band, an idol
group, an ensemble, a team. **A music act is always `group`, never `franchise`**,
however large its branded output.

*why:* The failure with the most evidence — `fx_104` and `fx_107` both turn on
it, and v16's rule for it did not work. State the boundary in *both* this and
`franchise`.

### organization → `cardinal:organization`
**definition:** A durable institution — company, label, league, broadcaster,
school or governing body — **named as a subject in its own right**. **Not** an
institution somebody merely belongs to, attended or works at: a named school or
employer identifies a *person* and is never vocabulary about them.

*why:* `fx_110` wants **zero** mentions from a title naming a school; v14 emitted
four and v16 three. At 0.2% of mentions the over-inviting risk is negligible.

### franchise → `cardinal:franchise`
**definition:** A persistent fictional or branded universe whose continuity spans
multiple works — a series, a shared world, an IP. **Not** a performing act, a
record label or a studio; **not** a single work however famous. If the surface
names people who perform, it is `group` or `person`.

### work → `cardinal:work`
**definition:** A specific released or published creation with a title of its own
— a film, album, game, book, song or episode. **Not** a description of what a
video shows, and **not** a phrase that only describes content. If the title
describes rather than names, there is no work: name the durable subject it is
*about*, or emit nothing. **Prefer the narrower families below wherever they
fit.**

*why:* 34.6% of mentions, and it is absorbing `anime`, `book`, `game`,
`music_work`. This definition has to do the most refusing of any here.

### anime → `cardinal:work`
**definition:** A specific Japanese animated series or film, named as a title.

### book → `cardinal:work`
**definition:** A specific published written work — novel, manga volume, or
non-fiction title.

### game → `cardinal:work`
**definition:** A specific published video game or release, named as a title.
**Not** the franchise it belongs to — **emit both** when both are named.

### music_work → `cardinal:work`
**definition:** The abstract musical composition — the song as written, distinct
from any one recording. Use when the composition itself is the subject.

### album → `cardinal:work`
**definition:** A specific named release collecting recordings. **An album name
nominates its group or artist as the primary term** — emit the act as well.

### sport → `cardinal:activity`
**definition:** A named sport as a practice — football, tennis, swimming.
**Not** a league, team or match, which are `organization` and `event`.

### activity → `cardinal:activity`
**definition:** A repeatable human practice, hobby or skill somebody does —
cooking, running, drawing. **Not** a genre of video about that practice:
watching cooking videos is not cooking.

### culture → `cardinal:concept` — **redefined**
**definition:** A country or cultural sphere as a subject of interest — its
travel, food, history and media taken together. Keyed by place:
`culture:japan`, `culture:usa`, `culture:uk`, `culture:taiwan`. **Not** a
nationality applied to a person, **not** a language, and **not** the place itself
as a location — that is `place`.

*why:* Redefined per the owner, 2026-08-24. **No `culture:*` concept exists yet
(0 in the database)**, so this vocabulary is entirely new and the convention can
be set cleanly. 14 `presumed_terms` carry `family = 'culture'` under the old
reading and should be reviewed before minting.

### art → `cardinal:concept` — **new family**
**definition:** An art form or an artistic style, as a durable subject.
Forms: `art:oil_painting`, `art:watercolor`, `art:pottery`, `art:photography`.
Styles: `art:cubism`, `art:impressionism`. **Not** a particular artwork, which is
`work`, and **not** the artist, who is `person` — a person is linked to a style
by a relation, never by being typed as one.

*why:* New per the owner. The person↔style link (Monet → impressionism) is a
**predicate**, and the grammar sheet already has `associated_with` with subject
`person|group|franchise` → object `culture`; extending its `object_families` to
`culture|art` is the smallest change that carries it.

### place → *no root* (`selected_cardinal: "none"`)
**definition:** A named geographic location — city, country, region or venue.
**Answer `selected_cardinal: "none"`**, since `place` has no cardinal root.

*why:* `family_root_mismatch` is already the top categorisation refusal at 140,
and `none` is emitted only 0.4% of the time, so this must be explicit.

### event → `cardinal:event`
**definition:** A specific dated public occurrence — a named concert, match,
festival or ceremony. **Not** a recurring series of them, which is `tour`.

### tour → `cardinal:event`
**definition:** A named touring series a performer stages across dates, as
distinct from any single date on it.

### ~~idea~~ — **removed**
Removed per the owner, 2026-08-24: ASMR, study-with-me and commentary are not
wanted as terms. **Clean to remove — 0 `presumed_terms` carry it and 0 concepts
exist.** `cardinal:concept` is now reached only through `culture` and `art`.

---

## 3. The refusal vocabulary

**Eight of fifteen `mention_role` values are never used once**, including every
role meaning *present but not a term*. A definition that says "use
`incidental_context` instead" is worthless if the model was never told what that
means, so these are proposed for the prompt alongside the families.

| role | proposed definition | v16 use |
|---|---|---|
| `incidental_context` | Present in the title but not what it is about. | 2.6% |
| `format_token` | A format or packaging word — "MV", "Official", "4K", "Live". | **0.1%** |
| `generic_action` | A verb phrase describing what happens, not a subject. | **0** |
| `unresolved_generic` | A common noun too generic to identify anything. | **0** |
| `tag_roster` | A run of tags listed together rather than a subject. | **0** |
| `analogy` | Named only by comparison, not as a subject. | **0** |
| `publisher` / `uploader` | The account that posted it — provenance, not topic. | **0** |
| `channel_core_topic` | What a channel is habitually about. | **0** |
| `durable_activity_or_idea` | The lasting practice or subject behind the item. | **0** |

Abstain reason for a title carrying nothing: **`no_durable_subject`**.

---

## 4. Decisions taken, and what they cost to build

**`conversation_worthy` → always true.** Not used as a filter. It is emitted
`false` on 831 mentions (8.1%) and read by nothing; forcing it true makes the
field honest about being inert rather than leaving a live-looking signal that is
discarded. **Consider deleting it from the schema** rather than pinning it — a
field every answer must fill and nothing reads costs output tokens on every
mention.

**Removing `idea` and adding `art` keeps both tiers at their current size** — the
ontology stays at 23 families and the wire at 17, so the compiler's
exact-difference check (`compile_semantic_contract.py:438-451`) still balances
and `MODEL_FORBIDDEN_FAMILIES` needs no change. That is a genuine convenience:
a net-zero swap avoids touching the one assertion that would otherwise refuse
the build.

**The change surface, verified:**

| artifact | change |
|---|---|
| `mention_extract_v4.schema.json` | the family enum, **4 copies** |
| `mention_extract_v2.py:58-64` | `FAMILY_CARDINAL` |
| `terms.xlsx` | `llm.family.enum`, `llm.family.cardinal_map`, `ontology.family.enum`, `term_family.map.art` |
| new migration | `ontology.cardinal_root_map`: drop `idea`, add `art` → `cardinal:concept` |
| new migration | `presumed_terms.family` check constraint (`0284:47-51`) |
| new migration | re-pin the wire map — `0300` asserts a hard-coded 17-entry `jsonb` and would now be wrong |
| grammar sheet | `associated_with.object_families` → `culture|art` |

**One decision still open — and it decides whether these terms are ever seen.**
`api.list_assertions` allows `concept_kind in ('creator','work','activity','topic')`.
`culture` currently maps to `concept_kind=culture`, **which is not on that list**,
so culture terms would never reach Memories. `idea` avoided this by mapping to
`topic` with `metadata.topic_axis=idea`.

Two ways:

- **Map both to `topic` with an axis** — `concept_kind=topic;metadata.topic_axis=culture`
  and `…=art`. No migration to the allowlist, matches the pattern `idea` used,
  and they appear in Memories immediately.
- **Add `culture` and `art` to the allowlist** — truer to the taxonomy, one
  migration, and it must not disturb the `era:`/`sphere:`/`scene:` prefix
  exclusions that share `topic`.

I would take the first, and record the second as the tidier thing to do later.
