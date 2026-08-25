# The grammarbook

**The ontology grammar: what it is, what each iteration taught, and what
validates it.** This file is the reference for the semantic lane the way
`CLAUDE.md` is the reference for the app. Where the two disagree about the
grammar, this file controls; where either disagrees with a migration header,
**the migration controls**, because it is the thing that ran.

Three parts, and they answer different questions:

1. **[The framework](#part-1--the-framework)** — the closed vocabularies, the
   roots, the predicates, the wire. Changes only by migration.
2. **[Grammar learned from iterations](#part-2--grammar-learned-from-iterations)**
   — the rules bought by a release that failed. Append-only.
3. **[The golden set](#part-3--the-golden-set-and-how-a-label-becomes-one)** —
   the hand-labelled cases, the constraint that keeps real titles out of git,
   and the loop that turns a judgement into a number.

**[Part 4](#part-4--known-divergences)** is the register of places where two
artifacts currently disagree. It is a debt list: an entry is deleted when it
stops being true.

Measurements are cited here and recorded in `docs/PROJECT-CONTEXT.md`. A number
in this file exists to make a rule checkable, never as the record of a run.

---

## The ring: four artifacts, pinned to each other

No single file holds the grammar. Four do, and a build refuses unless they
agree — which is the property that keeps the vocabulary from forking.

| artifact | path | holds |
|---|---|---|
| **the workbook** (authoring) | `semantic/ontology/terms.xlsx`, sheets `grammar` + `runtime_config` | predicate registry rows, every closed enum, family→root map |
| **the wire schema** | `semantic/contracts/mention_extract_v4.schema.json` | what one model call may emit |
| **the validator** | `semantic/src/written_ontology/mention_extract_v2.py` | what JSON Schema cannot express |
| **the database** | `0291`, `0292`, `0295`, `0306`, `0203`, `0284`, `0042` | roots, predicates, storage, prices |

`tools/compile_semantic_contract.py:266` (`validate`) refuses to build unless the
first three agree; `0300` pins the family→root map to the fourth. The build's
output is `semantic/contracts/compiled_semantic_contract_v1.json`.

**The workbook is authoring input, not authority.** It is where a predicate is
written down first; the compiler is what makes it binding, and the database is
what makes it enforced. A change that reaches `terms.xlsx` and no migration has
not happened.

---

# Part 1 — The framework

## 1.1 The eight cardinal roots

`ontology.cardinal_roots`, `supabase/migrations/0291_eight_immutable_roots.sql:21-45`.

| `root_id` | definition (verbatim, `0291:30-44`) |
|---|---|
| `cardinal:person` | A natural individual. |
| `cardinal:group` | A named collective whose collective identity or membership matters. |
| `cardinal:organization` | A durable institutional, legal, commercial, educational, or governing body. |
| `cardinal:work` | A bounded authored, recorded, published, designed, or released creation. |
| `cardinal:franchise` | A persistent intellectual-property, continuity, or branded universe spanning one or more works. |
| `cardinal:activity` | A repeatable human practice, skill, hobby, sport, or mode of doing. |
| `cardinal:concept` | An abstract subject, discipline, method, theory, style, movement, or idea. |
| `cardinal:event` | A time-bounded public occurrence or eligible public occurrence identity. |

**Immutable three ways, not one.** A `check (immutable)` column; a
`before insert or update or delete` trigger that raises unconditionally
(`0291:49-62`, *"the eight cardinal roots are schema constants; a change is a
migration, not a write"*); and a migration assertion that counts exactly eight
**and proves a ninth is refused** (`0291:271-282`). The third is the one that
matters — a constraint nobody has seen answer *no* is not known to work.

**Two spellings, deliberately.** The database prefixes (`cardinal:person`); the
wire uses the bare name (`person`). The prefix is re-applied where a proposal is
written, `aws/worker/overlay.py:1226`. Do not "fix" one to match the other.

**The root is identity, not versioned vocabulary.** `concept_cardinal_roots`
(`0291:111-117`) is one row per concept and is **unversioned**. The first draft
put it on `concept_revisions`, and the immutability guard correctly refused the
backfill — the header records this at `0291:102-109`.

**Five kinds map to no root, on purpose**: `hub`, `place`, `affinity`,
`identity`, `quantitative_feature` (`0291:90-96`), plus `event_type`, `channel`,
`platform`, `game_category` (`0293:36-39`). A deliberate null **is** an entry, so
`0291:287-293` asserting "every kind has an entry" fails for a *new* kind rather
than letting it ship unrooted.

## 1.2 The families — two tiers, and the trap

**There are two family vocabularies. Confusing them is the main error.**

### Tier A — the ontology enum, 23 values

`terms.xlsx` → `ontology.family.enum`, mirrored exactly by the
`presumed_terms.family` check at `0284:47-51`:

```
activity | album | anime | book | channel | culture | event | event_type |
franchise | game | game_category | group | hub | idea | music_recording |
music_work | organization | person | place | platform | sport | tour | work
```

### Tier B — the wire enum, 17 values (`family_hypothesis`)

What the model may say. It appears in **five** places and all five agree:
`mention_extract_v4.schema.json:190-208`, `:381-399`, `:586-604`, `:803-821`
(four copies); `terms.xlsx` → `llm.family.enum`; the compiled contract's
`output_contract.families`; and `evaluation_corpus_v2.json:4-6`.

| family | → root (wire) | → `concept_kind` (storage) |
|---|---|---|
| `person` | `person` | `creator`, `entity_form=person` |
| `group` | `group` | `creator`, `entity_form=group` |
| `organization` | `organization` | `organization` |
| `franchise` | `franchise` | `work`, `work_type=franchise` |
| `work` | `work` | `work`, `work_type=creative_work` |
| `anime` | `work` | `work`, `work_type=anime` |
| `book` | `work` | `work`, `work_type=book` |
| `game` | `work` | `work`, `work_type=game` |
| `music_work` | `work` | `work`, `work_type=music_work` |
| `album` | `work` | `work`, `work_type=album` |
| `sport` | `activity` | `sport` |
| `activity` | `activity` | `activity` |
| `idea` | `concept` | `topic`, `topic_axis=idea` |
| `place` | **`none`** | `place` |
| `culture` | `concept` | `culture` |
| `event` | `event` | `event`, `event_scope=occurrence` |
| `tour` | `event` | `event`, `event_scope=series` |

**`place` → `none` is not a missing entry.** The family has no root, so a `place`
mention must answer `selected_cardinal: "none"` or be refused
`family_root_mismatch` (`mention_extract_v2.py:201-208`).

**The map lives in three places and is pinned pairwise** — `terms.xlsx`
(`llm.family.cardinal_map`), `mention_extract_v2.py:58-64` (`FAMILY_CARDINAL`),
and `ontology.cardinal_root_map`. Workbook↔validator is checked at
`tools/compile_semantic_contract.py:291-305`; that pair↔database at
`0300:20-46`, which re-states the map as a `jsonb` constant and raises on any
difference.

### The six the model may never emit

23 − 17 = `channel`, `event_type`, `game_category`, `hub`, `platform`,
`music_recording`. A frozenset at `tools/compile_semantic_contract.py:80-83`,
checked as an **exact difference rather than a subset** (`:438-451`) — so a
family added to one tier and not the other fails the build instead of silently
becoming emittable.

Five are plumbing. **`music_recording` is a decision**: `0221` removed recordings
from the versioned ontology because owning a track is not a trait, and the
schema's own field description repeats it (`mention_extract_v4.schema.json:188`).

### A third set — virtual families

`video`, `episode`, `article`, `observation`, `calendar_event`,
`travel_itinerary`, `event_occurrence`, `user_profile`
(`tools/compile_semantic_contract.py:63-66`). These are *subject* types on the
grammar sheet only, and must have **no** storage mapping (`:428-431`) — a mapping
would turn a video into something somebody likes.

## 1.3 The predicate registry

### The registry — 55 predicates

`terms.xlsx` sheet `grammar`: `predicate | subject_families | object_families |
meaning | traversal_min_state | llm_may_propose | llm_may_verify | example`.

**`llm_may_verify` is `F` on every row.** The model proposes; it never verifies.

`traversal_min_state` is the authority a relation must reach before it may be
walked: `verified_relation` → `user_confirmed` → `displayable_suggestion` →
`structural_only` → `never`. `candidate_about` and `candidate_affinity` are
`never`; `interested_in` is `user_confirmed`; the calendar and travel predicates
are `displayable_suggestion`; `transits_through` is `structural_only`.

### The typed columns

`ontology.relation_types`, `0042_semantic_schema.sql:193-208`:
`relation_class` ∈ `hierarchical | associative | descriptive | observed_action |
user_claim`, `inverse_predicate_key`, `is_symmetric`,
`transitive_for_inference`, `max_inference_hops` (0–3), `assertion_safe`.

`0291:140-152` adds the Cardinal spec's propagation columns:
`propagation_weight` (λ), `reverse_propagation_weight`,
`minimum_propagation_authority` ∈ `proposed | displayable | supported |
verified`, `minimum_relation_confidence` (default 0.65),
`may_propagate_user_predicates`, `registry_version`.

**λ defaults to 0, and that is the conservative reading, not an unset field**
(`0291:138-139`): a predicate nobody has priced propagates nothing.

### λ as seeded — `registry_version = 'predicate-v2.0'`

| predicate | λ | min authority | hops |
|---|---|---|---|
| `recording_of` | 0.55 | verified | 1 |
| `part_of_franchise` | 0.45 | supported | 1 |
| `exemplifies` | 0.40 | supported | 1 |
| `about` | 0.35 | **proposed** | — |
| `features` | 0.35 | supported | — |
| `created_by` | 0.35 | supported | — |
| `composed_by` | 0.30 | supported | 1 |
| `performed_by` | 0.30 | supported | — |
| `soundtrack_of` | 0.25 | supported | 1 |
| `member_of_group` | 0.25 | supported | 1 |
| `played_for` | 0.25 | supported | 1 |
| `represented_team_in` | 0.25 | supported | 1 |
| `draws_on` | 0.20 | supported | 1 |
| `official_channel_of` | **0.00** | verified | **0** |

`soundtrack_of` carries the source-action rule in its own description
(`0291:176`): ***"Never implies watched or played."***

**λ is registry data with no consumer today** — see [Part 4](#4-λ-propagation-is-prepared-apparatus-not-live-behaviour).

### The closed user-predicate registry

Five, all `user_claim`, all λ 0, all 0 hops (`0291:193-207`):

| predicate | `assertion_safe` | note (verbatim) |
|---|---|---|
| `interested_in` | **true** | the generic, source-agnostic user affinity; the safest default candidate |
| `practices` | **true** | Requires explicit confirmation or genuine doing evidence. |
| `studies` | **true** | Interest is not study. |
| `creates` | **true** | Never inferred from consumption. |
| `played` | **false** | A true timestamped provider play or explicit confirmation; snapshots and counters are insufficient. |

These five plus `"none"` are exactly the wire's `candidate_user_predicate` enum
(`mention_extract_v4.schema.json:300-307`).

### How a predicate is chosen — the gate

`semantic_private.guard_user_assertion_relation_class`,
`0045_semantic_product_surfaces.sql:2012-2056`, in order:

1. `relation_class` must be `user_claim`. **This is what refuses `watched`,
   `completed_activity`, `attended_activity_at`, `booked_activity_at`** — all
   `observed_action`, because what somebody did is evidence, not a claim about
   them.
2. Inferred + `hometown`/`lives_in` → refused outright.
3. Inferred + not `assertion_safe` → refused. **This is what refuses
   `likes_activity` and `played`.**
4. Inferred + a concept → revision must be `active`, not `sensitive`, and
   `inference_policy ∈ (inferable, review_required)`.

**The model never chooses an assertion predicate.** It emits
`candidate_user_predicate`, stored as `observation_mentions.model_user_predicate`
— *"a candidate the review unit aggregates by, never a claim by itself"*
(`aws/worker/overlay.py:1014-1017`).

### What the scorer may assert — a different, older set

`aws/worker/score.py:118-134`: `affinity_to`, `participates_in_activity`,
`follows_activity`. Selection (`0200:76-78`):

```
participates_in_activity   involvement evidence exists
follows_activity           only viewing evidence exists
affinity_to                evidence that says neither
```

**Which evidence means which is data, not code** —
`semantic_private.sources.engagement_modes`, `not null default '{}'` so an
unclassified source reads as *nothing marked* rather than null (`0200:112-113`).

## 1.4 The relations

### The wire's closed 12

`mention_extract_v4.schema.json:510-541`. `{predicate, object_label_hypothesis}`,
both required, `additionalProperties: false`, **`maxItems: 2` per mention** —
*"a mention that could relate to everything is describing nothing"* (`:252-257`).

```
part_of_franchise, features, about, performed_by, composed_by, recording_of,
soundtrack_of, member_of_group, played_for, official_channel_of,
represented_team_in, located_in
```

**They are exactly the grammar-sheet rows with `llm_may_propose = T`**, asserted
at `tools/compile_semantic_contract.py:388-404` and again in
`semantic/tests/test_semantic_contract.py:125-133`. That assertion is what makes
the workbook column load-bearing rather than documentation.

**The object is a bare label, never an id** (`:511`): *"the model does not know
what has been minted and must never choose one."* An empty relation list is
correct — the prompt says so explicitly
(`emit_no_relation_when_you_do_not_know_one_an_empty_relation_list_is_correct`).

### The thirteenth — `broader`

Not on the wire. A chosen `parent_candidate_id` is converted by the worker into a
`broader` edge marked `"_selected_parent": True`
(`aws/worker/overlay.py:1035-1040`); `0295:41-49` widened the storage check from
12 to 13 to admit it.

### Where a relation lands, by subject type

**Concept or provisional** → `candidate_relation_proposals` (`0203:176-208`).
`authority_state` ∈ `model_proposed | displayable_suggestion | user_confirmed |
catalog_supported | community_supported | verified_relation`, and the whole
safety property is one constraint (`0203:206-207`):

```sql
constraint candidate_relation_traversal_check check (
  traversable = false or authority_state = 'verified_relation')
```

The worker always writes `'model_proposed', false`.

**Presumed term** → `presumed_term_relations`, `0306:23-46`. This table exists
because a presumed term is neither a concept nor a provisional, so **6,982
distinct relation edges from one RIS run were written and wholly discarded**
before it (`0306:3-9`). Its rules:

- Predicate check = the wire's 12 + `broader`.
- `unique (subject_term_id, predicate, object_term_id)` — repeat sightings raise
  `observed_count` rather than inserting (`0306:39-42`).
- `check (subject_term_id <> object_term_id)` — *"a term does not relate to
  itself; that is a spelling"* (`0306:44-45`).
- **Append-only by trigger** (`0306:50-74`): an UPDATE passes only if subject,
  predicate, object, basis and `created_at` are unchanged and `observed_count`
  is non-decreasing. Every DELETE raises.
- **Never traversable by construction rather than by column** (`0306:14-18`) —
  nothing reads this table into the ontology.
- The migration proves it **both ways** (`0306:81-122`): an edge recorded, a
  second sighting counted to 2, a self-edge refused, a rewrite refused.

### The relation object becomes a term

`aws/worker/overlay.py:1103-1116` (`_OBJECT_FAMILY`) — *"read from the grammar
sheet's `object_families` rather than guessed."* Eleven entries for twelve
predicates: **`features` and `about` are absent on purpose**, their object
families being 9- and 13-way unions, so *"a predicate whose object family this
does not know contributes no dictionary entry, which is a gap to notice rather
than a term to invent."*

### The missing-parent proposal (§5.3)

`missing_parent_proposals`, `0295:51-63`. Append-only, using **`0204`'s pattern**
— refuse the delete while the owner exists, permit it once they are gone — so
account deletion still cascades (`0295:67-90`). *"The same proposal from many
users is many rows, which is the evidence a governance pass aggregates. Nothing
reads it into any ontology until a human mints it"* (`0295:16-18`).

## 1.5 The stratum ladder and reason-scoped labels

`0292_reason_scoped_labels_and_the_stratum_ladder.sql`.

**The premise** (`0292:4-9`): a review event is not one signal. *"A keep confirms
the affinity strongly, the identity route somewhat, the root hardly at all; a
`not_relevant` strike is a strong personal negative and almost no statement about
classification; `wrong_identity` penalizes the resolver, not the person's taste."*

### The six supervision domains

`user_affinity`, `identity_route`, `classification_root`,
`classification_parent`, `predicate_route`, `source_action_route`
(`0292:24-26`).

### Table 2 prices — `price_version = 'table2-v1'`

| action | reason | domain | Δ log-odds |
|---|---|---|---|
| keep | `*` | user_affinity | **+2.00** |
| keep | `*` | identity_route | +1.20 |
| keep | `*` | classification_root | +0.35 |
| strike_off | not_interested | user_affinity | −2.50 |
| strike_off | not_interested | identity_route | −0.10 |
| strike_off | ambiguous_rejection | user_affinity | −2.50 |
| strike_off | ambiguous_rejection | identity_route | −0.10 |
| strike_off | wrong_entity | identity_route | −2.00 |
| strike_off | wrong_entity | user_affinity | −0.50 |
| strike_off | wrong_type | classification_root | −2.00 |
| strike_off | wrong_type | classification_parent | −1.00 |
| strike_off | `wrong_parent` | classification_parent | −2.00 ⚠ |
| strike_off | `wrong_parent` | classification_root | −0.10 ⚠ |
| strike_off | wrong_predicate | predicate_route | −2.00 |
| strike_off | not_representative | source_action_route | −2.00 |
| strike_off | too_private | source_action_route | −2.00 |
| edit | `*` | user_affinity | **−2.00** |
| edit | wrong_primary_term | identity_route | −2.00 |
| edit | wrong_type | classification_root | −1.50 |

⚠ **The two `wrong_parent` rows are unreachable** — see
[Part 4](#1-wrong_parent-can-be-priced-and-can-never-be-recorded--live-defect).

**`edit` prices `user_affinity` at −2.00.** An edit counts the original proposal
as negative; it is never a Qwen success.

### The reason vocabulary maps, it does not fork

`0292:11-17` maps the spec's seven codes onto the existing fourteen-word
`review_events.reason` vocabulary rather than adding a second spelling. The base
vocabulary is `0203:338-342`, default `ambiguous_rejection` — *"the honest
reading of one tap: it tunes ranking and says nothing about whether the term was
true"*.

### The fan-out

`emit_calibration_labels()` is an `after insert` **trigger** on `review_events`
(`0292:92-149`) — a trigger rather than a job, because §I-08 requires
keep/strike/edit to recompute immediately.

- Only `keep`, `strike_off`, `edit` emit. **`defer` and `restore` carry no
  label**; *"finish is keep-by-silence"* (`0292:102-104`).
- A term key of null emits nothing — *"an event about nothing prices nothing"*.

### The ladder

`calibration_label_weights`, `security_invoker = on` (`0292:156-179`):

```
k_mass, s_mass  = sum(least(abs(Δ)/2.50, 1.00) * actor_authority) by sign
posterior       = (k_mass + 4) / (k_mass + s_mass + 8)     -- α=β=4, mean 0.5
multiplier      = clamp(posterior / 0.50, 0.50, 1.50)
activation_met  = distinct_users >= 5 and labeled_cards >= 10
```

**Five users is `EmergentTermMiner`'s floor, reused rather than reinvented.** The
[0.5, 1.5] bound is stated at `0257:22-25`: *"so no stratum can be silenced or
amplified into a different product by feedback alone."*

### The strata — the backoff order

"Stratum" means one rung of the hierarchical backoff, most specific first, each
rung dropping dimensions until support is met. **They are seeded in `0257:323-328`
and extended for cardinals in `0291:226-235` — not in `0292`, whose filename
says otherwise.** The cardinal version, `'cardinal_v2'`:

```
target_domain,source_code,action_type,mention_family,mention_role,cardinal,user_predicate
target_domain,source_code,action_type,cardinal,mention_role,user_predicate
target_domain,source_code,cardinal,user_predicate
target_domain,cardinal,user_predicate
```

`calibration_dry_run` (`0257:352-406`) **reports which strata fail support and
never falls back silently**, and counts **one vote per (user, proposal revision,
independence root)**.

## 1.6 Closed grammar with open nouns

### Closed — a fixed enumeration the model selects from

| vocabulary | size | where enforced |
|---|---|---|
| cardinal roots | 8 (+`none`) | schema ×3; `cardinal_roots` trigger; storage check `0295:32-34` |
| families | 17 | schema ×4; compiler exact-difference `:438-451` |
| mention roles | 15 | schema ×3 |
| relation predicates | 12 | schema; grammar sheet `llm_may_propose`; DB check (13 with `broader`) |
| user predicates | 5 (+`none`) | schema; `relation_types`; storage check |
| abstain reasons | 5 | schema |
| source fields | 6 text + `tags` + `inferred` | both schemas |
| invocation outcomes | 14 | `model_invocation_items.outcome` |
| review reasons | 14 | `review_events.reason` |
| authority states | 6 | `candidate_relation_proposals` |

The 15 mention roles: `primary_subject, featured_person, performing_group,
work_or_franchise, creator_identity, channel_core_topic,
durable_activity_or_idea, publisher, uploader, incidental_context, tag_roster,
format_token, generic_action, analogy, unresolved_generic`.

The 5 abstain reasons: `no_durable_subject, hard_suppressed, ambiguous,
insufficient_context, invalid_input`.

### Open — free strings the model may invent

`surface`, `canonical_label_hypothesis`, `english_label`, `original_label`,
`object_label_hypothesis`, and a proposal's `label`, `definition`, `rationale`,
`example_children`, `non_examples`. **Bounded by length only. No `pattern`
anywhere** — see [2.2](#22-no-pattern-and-no-optional-property-the-two-shapes-that-strangled-a-release).

### Closed absolutely: identifiers

`0291:5-8`: *"Qwen selects from the registry and can no more invent a ninth than
rename the eighth, and a root change is a schema migration outside the model path
by construction."*

`llm.output.forbidden_fields` = `term_id | database_id | verified_state |
authority | global_confidence | sql | tool_call | source_url`, backed
structurally by `additionalProperties: false` on every object in both schemas.

**The one id-shaped field the model may emit is an echo.**
`parent_candidate_id` must be one of the ids the request supplied, checked at
`mention_extract_v2.py:214-215`, and it **fails closed**: *"None means the
request supplied none — under which every selection is an invention and is
refused"* (`:159-162`).

### Which artifact enforces what

- **JSON Schema** — every enum, every length, `additionalProperties: false`, the
  status/mentions/abstain agreement.
- **The Python validator** — everything relating the response to the *request*,
  or two mentions to each other: item coverage, offsets, `surface ==
  source[start:end]`, span/role uniqueness, family↔root agreement, the parent
  echo, control characters.
- **The database** — check constraints mirroring the wire enums, so *"a value the
  schema could not emit must not be storable either"* (`0295:11-13`).
- **The compiler** — that all of the above agree, at build time.

## 1.7 The wire

### Request — `mention_extract_request_v2`

`additionalProperties: false` everywhere. `items` 1..8. `fields` is an
**allowlist**: `title`, `channel_label`, `description_excerpt`, `tags`,
`performer`, `composer`, `album` — the last three added by `0290`, *"what lets a
song nominate its film, its franchise or its artist instead of standing alone."*

`source_profile` ∈ `youtube | calendar | apple_music | spotify | music_catalog |
podcast` — *"Which source's predicate profile applies. Not the source's data."*

**`parent_candidates`** — `maxItems: 40`, items `{term_id, label}` **only**;
*"no definition text travels, and nothing about whose request this is."* Chosen
server-side (`aws/worker/overlay.py:190-206`): the 40 published concepts with the
most distinct subject edges, with `era:`/`sphere:`/`scene:` excluded — *"an era
is an axis and a sphere is a scope; neither is a parent a new term may be filed
under."*

`request_id` and `item_id` are opaque and *"must carry nothing about whose
request this is."*

### Response

`{schema_version: "mention_extract_v4", items: [1..8]}`. Each item is
`extracted` (1..5 mentions) or `abstained` (0 mentions, one reason). Three
mention variants, told apart by `source_field`:

| variant | `source_field` | offsets |
|---|---|---|
| `mention_text` | the six scalar fields | yes, `source_field_index: null` |
| `mention_tag` | `tags` | yes, `source_field_index: 0..19` |
| `mention_inferred` | `inferred` (const) | **absent, not nulled** |

**Absent rather than nulled** because *"a reader must not be able to mistake an
inferred mention for an extracted one whose offsets happened to be zero"*
(`:714`). The validator reads the variant from `source_field`, never from a
missing key.

### v3 → v4, exactly

**v4 is v3 plus six required fields on all three mention variants, plus two new
`$defs`. Nothing else changed** — families, roles, predicates, abstain reasons,
source fields, offsets and lengths are byte-identical.

| field | note |
|---|---|
| `selected_cardinal` | 8 roots + `"none"` — *"an explicit member rather than null, because a null inside an enum is not a shape this stack trusts xgrammar with"* |
| `cardinal_confidence` | 0..1; 0 when `none`. *"The full distribution was cut deliberately."* |
| `parent_candidate_id` | echo-only, §5.2 *No model IDs* |
| `missing_parent_proposals` | array `maxItems: 1`. *"An array rather than a nullable object… Never alongside `parent_candidate_id`."* |
| `candidate_user_predicate` | 5 + `"none"`. *"A like grounds `interested_in`; nothing here may claim `practices` from a watch."* |
| `alternatives` | `maxItems: 2`, *"so the model does not choose the globally most famous entity merely to avoid provisional state."* |

### What the trusted layer does with each field

`aws/worker/_write_model_mentions`, `overlay.py:979-1057`:

| wire field | destination |
|---|---|
| `surface` | `observation_mentions.mention_text` + `normalized_text` |
| `family_hypothesis` | `.type_hint` |
| `source_field` | `.source_field`; also selects `model_inferred` vs `model_proposed` |
| `selected_cardinal` | `.model_cardinal` (+ `.model_cardinal_scores` with confidence) |
| `candidate_user_predicate` | `.model_user_predicate` |
| `relation_hypotheses[]` | `candidate_relation_proposals`; object also becomes a `presumed_terms` row |
| `parent_candidate_id` | a synthetic `broader` relation, `_selected_parent: true` |
| `missing_parent_proposals[0]` | `missing_parent_proposals`, root re-prefixed `cardinal:` |
| `alternatives[]` | `presumed_terms` rows with `origin = 'inferred'` |
| `english_label` / `original_label` | `presumed_terms`, **`coalesce`d** so a later call fills a gap and never overwrites |

**Qwen never allocates identity.** The mention is written by the deterministic
worker — *"the identity that may write mentions and may not record
invocations"* (`overlay.py:983-987`).

---

# Part 2 — Grammar learned from iterations

**Append-only. Each entry states the lesson, what it cost, and what falsified
the alternative.** An entry earns its place by having been believed wrong first;
a rule with no failed alternative behind it belongs in Part 1.

## 2.1 Offsets are repaired before validation, or nine tenths is thrown away

`repair_offsets` (`mention_extract_v2.py:315-398`), owner decision 2026-08-19,
`0252:20-23`. **Measured on RIS: 10,917 spans repaired; without it acceptance
was 9% instead of 90%.** Run it exactly where `gateway._accept` runs it —
between the model's answer and both validation layers — or a local score is
measuring a different pipeline.

**The run it was measured on**, 2026-08-22, four A100 80GB, one prompt per item,
one `generate()` call, prefix cached: **7.3–8.0 items/second per card against
~0.5 on the rented L40S lane**, 5,387 items in about three minutes per shard,
90% accepted, 14,501 mentions. **Two things were worth more than any tuning** —
this repair, and raising the output ceiling above the 800 tokens the AWS wire
pins, which long classical titles legitimately exceed (§2.7).

Three sub-rules, each bought separately:

- **Bounds before equality.** Slicing clamps, so with `end` one past the source
  `source[start:end]` silently truncates and can still equal the surface. Only an
  *in-bounds* equal slice means nothing needs repair (`:359-366`).
- **Two or more occurrences → the one nearest the model's stated start.**
  Declining instead refused **382 of 540 YouTube extractions** as
  `offset_invalid`, against 46 of 251 for music, because a long title repeats its
  own words. The argument for choosing: every candidate span holds the identical
  string, so *"only the span differs, and the span is provenance rather than
  meaning"* (`:377-394`, changed 2026-08-20).
- **Raw code points, never normalised** (`:335-338`) — an NFC-folded match would
  hide the `surface_normalization_mismatch` the validator exists to surface.

**Offsets are code points.** A model counting UTF-16 disagrees on any astral
character; one counting bytes disagrees on everything non-ASCII. The equality
check is what catches it, and it is the entire reason `surface` is carried.

## 2.2 No `pattern`, and no optional property: the two shapes that strangled a release

`0298:1-24`. **The v10 release passed its gate and then could not speak** —
the first real calls generated at **0.5–10 tokens/sec, 10 to 50 minutes per
prompt**. Two constructs were outside the shapes this stack has measured
xgrammar 0.2.3 on: `cardinal_scores` was an object of eight **optional** number
properties, and `selected_cardinal` / `missing_parent` were nullable through
enum-with-null and `anyOf`.

The reshape kept every §5.2 answer and changed only the encoding. The rule is now
in the schema's own `description` (`mention_extract_v4.schema.json:5`):

> xgrammar 0.2.3 is trusted **ONLY** with the shapes this stack has measured —
> pure string enums, `[scalar,null]` type unions, and arrays of objects with
> required properties. **No optional properties, no null inside an enum, no
> anyOf-nullable objects.**

**The gate cannot catch this class** — *"it attests identity, not speed"*
(`0298:19-20`) — which is why the rule lives in the artifact rather than in a
test. `0252` is the same defect from the other direction, and is why no `pattern`
appears anywhere in v3 or v4.

## 2.3 A family and a root that disagree are one surface telling two stories

`0300:4-11`. **629 of 649 v6 mentions were misfiled** — K-pop groups as
`music_work` ×270, CJK fandom as `anime` ×21, Mnet as `book`, ANOVA as `sport`.
*"A group filed as `anime` is a family and a root telling two different stories
about one surface, and a stored contradiction cannot be repaired later."*

The repair was not a better prompt. It was pinning the map in three places and
refusing `family_root_mismatch` at validation.

## 2.4 Size is not the axis; task shape is

From the relabel pass (`tools/ris_relabel.py:1-22`). **Prompt v14 stated the
native-language rule three ways and carried a worked example of the exact failing
character; the result was statistically identical — 4,832 accepted against
4,844.**

Then **Qwen2.5-72B-AWQ *regressed*** — it lost the Japanese native the 9B got
right, shortened `Kim Chaewon` to `Chae Won`, and invented "Fairy Tale" for
`髮如雪`.

Two conclusions, both load-bearing:

- **A newer 9B beats an older 72B**, and **4-bit quantisation damages exactly the
  low-frequency multilingual knowledge this needs while leaving schema
  conformance intact** — so the failure is invisible to every structural check.
- **What was left was task shape.** In extraction the model assigns a family,
  selects a root, echoes a parent, emits relations and hits exact offsets in one
  forward pass with thinking disabled and a large grammar constraining every
  token. Asked *one* question with two fields and room to think, it answers.

**The repair pass is therefore a separate call, not a better prompt.** The
extraction schema constrains eighteen fields per mention; the relabel schema
constrains two, *"so the grammar costs almost nothing and the model spends its
budget on the answer rather than on shape."*

### Confirmed a second time, on a different field (2026-08-24)

**The rule was found on labels and has now been reproduced on placement**, which
is what makes it a rule rather than one field's quirk. David's v17 run parented
**374 of 4,003 mentions — 9.3% — and proposed a new parent zero times in 1,540
items**, using 15 of the 40 headings it was given.

The candidate list was not the problem, and checking that mattered: the first
diagnosis was that genres were the wrong *kind* of parent for a person, and the
published tree refutes it — `creator → genre` is **2,441 edges, the dominant
authored pattern**. Bach under Classical is exactly what this catalogue does.
What the run actually shows is inconsistency on a correct list: **Chopin took
`Classical`, Bach took nothing, in the same run off the same list.** That is not
disagreement about Bach.

Asked the same question on its own — `tools/ris_parent.py`, one question, two
fields, thinking on, the candidate id an **enum** rather than a validated string
— the same model placed **1,269 of 1,284 terms, 98.8%**, across **30** of the 40
headings, at 22 terms a second.

|  | in extraction | asked alone |
|---|---|---|
| parented | 374 / 4,003 — **9.3%** | 1,269 / 1,284 — **98.8%** |
| headings used | 15 / 40 | 30 / 40 |

And the placements are **specific rather than safe**: Bach under *Baroque Era*
rather than Classical, Eason Chan under *Cantopop* rather than Mandopop, the
Monteverdi Choir under *Choral*. The fifteen refusals are correct — Sheldon
Cooper, the Marvel Cinematic Universe and Netflix Japan have no home in a list of
music headings, and `none` is an explicit enum member for the same reason it is
elsewhere: **a null inside an enum is not a shape this stack trusts xgrammar
with.**

Two cautions that travel with the number. **347 terms landed in the broad `Music`
bucket** (118 albums, 110 music_works) because no better heading exists among
forty. And **the confidence carries no signal** — 0.85 to 0.95 with a median of
0.95 across 1,269 answers — which is why the column storing it is named
`proposed_parent_confidence_unvalidated`.

**What follows for the extraction prompt: nothing.** v16 → v17 is the controlled
experiment — same fixtures, only the prompt changed — and more prompt text did
not move behaviour. A task-shape defect gets a task-shape fix.

## 2.5 A repair may improve a label and may never damage one

`tools/ris_relabel_merge.py`. The extraction answers are the floor. A replacement
happens only on a **stated, deliberately blunt** test — *"because a subtle one
cannot be checked by reading the report"*:

```
replace the native   when the current native merely echoes the surface
                     and the new native differs from it
replace the English  when the new one contains the old as a word-prefix
                     (Luffy -> Monkey D. Luffy) — never when it is merely
                     different, which is how Kim Chaewon became Chae Won
```

**Everything else is counted and discarded, and the counts are the point: a pass
that improved nothing must report zero rather than looking like it ran.**

## 2.6 A guard was built, tested, and removed on the evidence

Same file. The first pass rendered Los Angeles, Marvel, Spider-Man and 5 Seconds
of Summer in katakana — **34 kana natives, roughly two-thirds wrong**. The
intended fix was to make the model name the entity's language first and refuse
any native whose script contradicted it.

**It does not work**, because the model answers `english` for One Piece, Promare
and Re:Zero — the English name being the one it knows best — so the guard would
have refused every repair the pass exists for.

The entry is here because the guard was reasonable, was built, and was deleted by
measurement rather than argument. **A rule that has only ever answered one way is
not one to believe** — the same reason `0306` proves its trigger both ways.

## 2.7 Narrow the sequence schema when the container fans out

`gateway._sequence_schema:556-582`. A fan-out container that received the
batch-sized schema had the model **padding to the token cap**; measured
2026-08-21, *"every batch refused `output_overflow`, and raising the ceiling only
bought longer rambling."* `items.maxItems` is narrowed to 1 per item instead.

Corollary from RIS: **the output ceiling must sit above the 800 tokens the AWS
wire pins**, which long classical titles legitimately exceed. Two different
defects with the same symptom — read which one before raising a number.

## 2.8 The upload lease is not a poll budget

The sharpest operational lesson, and it survives every instance bounce.

- **`timeout_s` on an async SageMaker invocation is the deadline the container
  gets for writing its result to S3.** A request whose queue wait plus generation
  outlives it fails the upload, **returns to the queue, runs again**, and starves
  a one-at-a-time engine behind it. The queue belongs to the endpoint, so the
  only purge is deleting and recreating it.
- **An answer is read once and deleted, so a caller that gives up early destroys
  the work it just paid for.** An eight-item batch measured **162 s** of
  `ModelLatency` while the client waited **180 s** — so roughly every other call
  was abandoned seconds before the gateway collected it, and the gateway then read
  the S3 object and deleted it as retention requires. Every call succeeded; every
  answer was thrown away.
  **The rule is that a caller's patience must exceed the gateway's own ceiling
  (300 s), never merely the expected latency.** The margin between 162 and 180
  *was* the defect.
- **`MaxConcurrentInvocationsPerInstance` above 1 does not help.** One offline
  vLLM engine means eight concurrent invocations are eight requests sharing one
  worker with eight clocks running. Measured 2026-08-21: **concurrency 8
  delivered zero answers where concurrency 1 delivered steadily.** Batch *inside*
  one request.
- **The configured lease is 240 s** (`model_lane.propose`), sized to worst
  generation *plus* contention rather than to generation alone. **The client's
  own patience is a separate number** — it collects by ticket afterwards, so
  raising the client timeout fixes nothing if the lease is short, and raising the
  lease fixes nothing if the client gives up first. Both numbers, or neither.

Diagnose by reading `ModelLatency` in the endpoint's `data-log` and watching for
one request id succeeding repeatedly. From every other angle it looks like a
queue depth of one and a busy GPU.

## 2.9 A relation with nowhere to land is a relation discarded

`0306:3-9`. One RIS run produced **6,982 distinct relation edges** — 3,631
`performed_by`, 2,995 `part_of_franchise`, 252 `composed_by` — and **every one
was dropped**, because `candidate_relation_proposals` requires a concept or
provisional subject and a presumed term is neither.

The model was correct, the wire was correct, the validation passed, and the
output went nowhere. **Check that each emitted field has a table before
concluding a lane works.**

## 2.10 Count evidence, not applications

`0322`. `presumed_term_relations.observed_count` had counted *corpus
re-applications* — the same three loads replayed — rather than distinct
sightings. The emitter now writes `greatest(stored, excluded)`.

A count that grows when you re-run the loader is measuring the loader.

## 2.11 Failures are structural, never semantic

`mention_extract_v2.py:28-34`. **None of the validator's refusals is an
abstention.** A malformed response says nothing about whether the item had a
durable subject, *"and recording it as `no_durable_subject` would put a model's
bug into a person's profile as evidence about them."*

The same discipline governs diagnostics: a `jsonschema.ValidationError` is
carried as **the path only, never the message**, because *"a validator quotes the
instance it rejected, and the instance is somebody's title"* (`gateway:705-720`).
Drift is reported with the field and its measured value — artifact digests and
version strings only.

## 2.12 Not everything is retryable

`gateway.py:472-478`. `output_overflow`, `schema_invalid`, `offset_invalid`,
`missing_item`, `duplicate_item`, `input_oversize`, `contract_mismatch`,
`retention_failed` are terminal — *"a compact fallback is a distinct schema and
prompt profile, and a hidden 'be shorter' retry would make the recorded prompt
version untrue."*

## 2.13 Validate the document that will be sent

`gateway.py:524-553` validates the **serialised** request, not the intended one,
and `additionalProperties: false` does the work a forbidden-key list used to:
*"a user id, an observation id or an email address is refused because it was
never permitted, not because somebody remembered to name it. **The failure mode
of a deny-list is silence.**"*

## 2.14 The person is the anchor of the entry (owner's rule, 2026-08-25)

**In one entry, look for the person first. Once a person is identified, every
other term in that entry is prioritized to read against that person.**

Bought by the routing queue's own contents: `California`, `Spanish Sahara` and
`西西里` were routed to `hub:places_cultures` on their names alone, while
`Chappell Roan`, `Foals` and `Jay Chou` stood in the same entries — each
already resolvable to a music genre. A song wearing a place name is ambiguous;
a song beside its performer is not. The person is the term whose identity
survives ambiguity best, which is the same fact the person-subtype vocabulary
rests on.

Two enforcement points, and neither is a prompt instruction:

- **Context** (`ris_parent_build.py`): each entry is swept for persons before
  any term is recorded; every non-person term gains
  `person in this entry: <name>` at a rank above every relation
  (`ANCHOR_RANK = -1` against `LINKING`'s 0–3), and carries `anchor_persons`
  structurally beside the prose.
- **Inheritance** (`ris_parent_merge.py`): a non-person term links to its
  entry's persons exactly as an explicit `performed_by` would link it, so the
  person's placement flows to the entry's works under the same demotion-only,
  closure-checked rules. Persons do not anchor persons — a duet partner is not
  an identity — the same `PARTY` asymmetry the explicit relations obey.

---

# Part 3 — The golden set, and how a label becomes one

## 3.1 The constraint that shapes everything here

**Real titles cannot enter git.** Two independent reasons, and either alone would
be sufficient:

- `out/` is git-ignored (`.gitignore:61`), because a distillation is personal
  data and *"exports must never enter history."*
- Migrations `0239` and `0240` **refuse an evaluation invocation that names a
  user, an observation, or retained source text.** So the evaluation lane must
  have something to run against that carries none of those, or it either declines
  and tests nothing or reaches for real accounts and is rejected *after the model
  has been paid for*.

`evaluation_corpus_v1.json` states the consequence plainly: **"A gold set of real
titles would be somebody's viewing history in git history."**

This is why the golden set has two layers and a transfer rule between them. It is
not an accident of tooling.

## 3.2 The two layers

### Layer 1 — committed, synthetic, typed

`semantic/fixtures/mention_extract/evaluation_corpus_v2.json`. **Every title is
invented.** Each case carries:

```json
{"id": "fx_101",
 "title": "<invented>",
 "lesson": "an installment and its franchise are both terms; naming only one loses the other",
 "expect": {"families": ["music_work","game","franchise"], "at_least": 3,
            "note": "..."}}
```

- `families` — families a correct answer must include.
- `forbid_families` — families that must not appear for the named surface.
- `at_least` / `at_most` — bounds on the mention count.
- **`lesson` names the misassignment the case was built from, so a regression
  says what broke rather than that a number moved.**

**Why v2 exists at all**: v1's `expect` is prose — *"a work and a performing
group"* — which a person can read and a run cannot be scored against, so *"did
the categorisation improve"* stayed an opinion over twenty rows. v2 names
families, so a score is a number.

**Versioned in the filename, not by a field alone**, so a changed corpus is a
different corpus and a score measured against one is never silently compared with
a score measured against another.

### Layer 2 — uncommitted, real, seeded

The 20-row draws under `out/`. Real titles from the RIS corpus, drawn with a
**fixed seed** so a re-draw is the *same* sample and a difference is attributable
to the change rather than to a new sample.

## 3.3 The transfer rule

**A hand-labelled real row becomes a corpus case by carrying the lesson across
and inventing the title. Never the title itself.**

The eleven cases at `fx_101`+ are exactly this: derived from eleven real rows
hand-labelled by the owner on 2026-08-23, *"and the lessons were carried across
while the titles were not."*

What must survive the transfer: the **misassignment** (what the extractor got
wrong), the **families** a correct answer needs, and the **structural feature**
of the title that caused the error — a common word needing context, an
installment nested in a franchise, a name that is also a noun. What must not: the
string, the channel, the performer, anything joinable back to a person.

## 3.4 The loop

```
  1. draw     seeded random sample of N (default 20)   →  tools/ris_calendar_sample.py
  2. inspect  the owner reads label + what the gate decided
  3. relabel  corrections recorded
  4. repair   one narrow question, two fields          →  tools/ris_relabel.py
  5. merge    refusing every worse answer, counting    →  tools/ris_relabel_merge.py
  6. transfer lesson → invented title → corpus case    →  evaluation_corpus_v2.json
  7. score    families matched, bounds checked         →  tools/score_categorisation.py
```

**Step 1 is seeded on purpose** (`--seed 20260823`) so step 7's difference is
attributable to the change and not to a new draw.

**Step 7's two refusals are the reason to trust it:**

- **A case not in the answer is reported absent, never scored wrong.** *"A missing
  run and a run that failed every case are different facts, and a scorer that
  folds them together will report progress the first time the file path is
  mistyped."*
- **Items match corpus cases by `row_id` carrying the case id**, which is how
  `ris_corpus_probe.py` submits them — so a mismatch is a missing case rather
  than a silent zero.

## 3.5 Running validation honestly

- **Run `repair_offsets` before validation, exactly as `gateway._accept` does.**
  Without it acceptance is 9%, and the resulting score describes a pipeline that
  does not exist. This is the single easiest way to produce a wrong number here.
- **A score against v1 is never comparable with a score against v2.** The
  filename carries the version for this reason.
- **`corpus_version` is stamped in the file as well as the name**, so a result
  can name what it was measured against.

## 3.6 What the golden set does not cover

Naming it is the point; an uncovered area that looks covered is worse than one
that is obviously absent.

- **Seventeen cases total** (6 in v1, 11 in v2) against a corpus of 5,387 items.
  It is a regression guard, not a benchmark.
- **No case is drawn from a real title**, so it cannot catch a failure whose
  cause is a distribution the invented titles do not reproduce.
- **The sampler is calendar-only.** `ris_calendar_sample.py` draws calendar
  events. A term-level draw is currently ad-hoc, which means the loop above is
  re-derived by hand each session — the one gap in this apparatus worth closing
  with code.
- **Nothing scores relations or roots.** `expect` names families and counts;
  `relation_hypotheses`, `mention_role`, `selected_cardinal` and
  `candidate_user_predicate` are unscored, and `2.3`'s 629-of-649 root defect
  would not have been caught by this corpus.

---

# Part 4 — Known divergences

**A debt register. Delete an entry when it stops being true.** Each is a place
where two artifacts currently disagree; none is a plan.

## 1. `wrong_parent` can be priced and can never be recorded — live defect

**Verified against production 2026-08-23.** Three-way confirmed:

- `api.strike_calibration_item` **accepts** `wrong_parent` among nine reasons
  (`0294:74-79`).
- `calibration_label_prices` holds **2 rows** for it (−2.00
  `classification_parent`, −0.10 `classification_root`).
- `review_events.reason`'s check constraint holds **14 values and `wrong_parent`
  is not among them** (`0203:338-342`; nothing ever ALTERs it).

So a strike carrying `wrong_parent` raises a check violation at tap time, and
**`classification_parent` has received 0 labels, ever**. One of the six
supervision domains is unreachable, and the reason a user would give for the
commonest classification error — right entity, wrong parent — is the one the
system cannot record.

The other eight reasons `0294` admits are all in the constraint, so this is a
single missing value rather than a design disagreement.

## 2. `SOURCE_FIELDS` in the validator is stale

`mention_extract_v2.py:45` declares four fields and comments them as *"mirroring
the schema's `source_field` enum"*. The enum has been **six** since `0290` added
`performer`, `composer`, `album`. Harmless today — the constant is referenced
nowhere but its own definition, and `RequestItem.source_string` validates against
the fields actually sent — but it is a wrong comment on a public constant.

## 3. Per-source predicate profiles are validated and never applied

`terms.xlsx` authors five narrowing profiles (calendar →
`features|about|located_in`, apple_music → six music predicates, etc.). The
compiler checks they narrow and never widen
(`tools/compile_semantic_contract.py:406-412`) and a test asserts the same — but
**the compiler never emits a `source_predicate_profiles` key**, so
`Contract.source_predicates()` always falls through to the full 12. The wire enum
is the full 12 regardless of `source_profile`.

**A calendar item can therefore legally propose `performed_by`.**

## 4. λ propagation is prepared apparatus, not live behaviour

`propagation_weight`, `reverse_propagation_weight`,
`minimum_propagation_authority`, `minimum_relation_confidence` and
`may_propagate_user_predicates` appear in exactly one file in the repository:
`0291`. Neither `resolve.py` nor `score.py` reads them, and the taxonomy
coefficients λ_parent / λ_root the header describes are not stored at all.

(`granularity.py:393` has an unrelated field of the same name — not this.)

## 5. The compiled contract runs ahead of every registered release

The working tree's contract names `prompt = qwen_extractor_v16`,
`grammar = semantic_grammar_v5`. **No migration mentions v15 or v16**; the
highest registered production-shadow release is `qwen_extractor_v12` (`0300`),
and the RIS loads ran under v14.

This is the shape `0215` was corrected for: **a model version that runs ahead of
working code is the same defect as one that lags it**, because the runs record a
version whose parameters describe behaviour that did not happen.

## 6. `_OBJECT_FAMILY` is duplicated by hand

`aws/worker/overlay.py:1103-1116` and `tools/ris_emit_dictionary.py:87-95`. The
second names the first as governing, and **nothing checks them**. Both contain
`created_by`, which is not one of the twelve wire predicates — dead in the
worker, harmless. Both omit `features` and `about`, deliberately.

## 7. Two file-name inversions, cosmetic but confusing

- **The v4 validator lives in `mention_extract_v2.py`** (`SCHEMA_VERSION =
  "mention_extract_v4"` at line 41).
- **`mention_extract_v4.schema.json:17` still carries v2's description** —
  *"Two, not four. The gateway accepts at most two indexed items"* — directly
  above `"maxItems": 8`.

Both are text; the values are right.

## 8. `0292`'s filename says "stratum ladder"; its content is the label ladder

The strata themselves are seeded in `0257:323-328` and extended in
`0291:226-235`. Not a defect — but do not look for them in `0292`.

---

## Appendix — where to look

| topic | authority |
|---|---|
| eight roots, kind→root map, λ columns, `predicate-v2.0` | `0291_eight_immutable_roots.sql` |
| families added to the root map | `0293_...:24-40` |
| calibration labels, Table 2 prices, the ladder view | `0292_reason_scoped_labels_and_the_stratum_ladder.sql` |
| strata / backoff order, calibration parameters, dry run | `0257_...:313-406` |
| cardinal storage columns, `broader`, missing-parent inbox | `0295_the_wire_answers_the_cardinal_questions.sql` |
| the v4 release (schema + request + prompt v10 + gateway) | `0296_the_release_that_answers_the_cardinal_questions.sql` |
| the xgrammar shape rule | `0298_the_grammar_keeps_only_proven_shapes.sql:1-24` |
| wire map pinned to ontology map; the v6-corpus diagnosis | `0300_the_wire_map_is_pinned_to_the_ontology_map.sql:20-46` |
| presumed-term relations | `0306_a_presumed_term_may_state_a_relation.sql` |
| the offset repair, grammar binding | `0252_..._binds_the_grammar_and_repairs_the_arithmetic.sql:1-36` |
| `relation_types` base schema | `0042_semantic_schema.sql:193-208` |
| `candidate_relation_proposals`, `review_events` | `0203_...:176-208`, `:329-359` |
| the dictionary (`presumed_terms`), 23 families | `0284_every_term_enters_the_dictionary.sql:40-95` |
| review card root + breadcrumb, strike reasons | `0294_a_card_shows_its_path_and_a_strike_says_why.sql` |
| assertion predicate gate | `0045_semantic_product_surfaces.sql:2012-2056` |
| engagement predicates | `0200_an_activity_is_watched_or_done.sql:56-115` |
| wire response / request schema | `semantic/contracts/mention_extract_v4.schema.json`, `..._request_v2.schema.json` |
| compiled contract | `semantic/contracts/compiled_semantic_contract_v1.json` |
| validator layer 2 | `semantic/src/written_ontology/mention_extract_v2.py` |
| gateway `_accept`, request build, refusal vocabulary | `semantic/src/written_ontology/gateway.py:311-478`, `:644-757`, `:795-802` |
| the compiler and every cross-check | `tools/compile_semantic_contract.py:45-83`, `:266-500` |
| worker: parent candidates, mention write, relations | `aws/worker/overlay.py:190-219`, `:979-1057`, `:1064-1116` |
| scorer: assertable predicates, engagement selection | `aws/worker/score.py:118-150` |
| authoring workbook | `semantic/ontology/terms.xlsx` (`grammar`, `runtime_config`) |
| typed evaluation corpus | `semantic/fixtures/mention_extract/evaluation_corpus_v2.json` |
| the labelling loop | `tools/ris_calendar_sample.py`, `ris_relabel*.py`, `score_categorisation.py` |
