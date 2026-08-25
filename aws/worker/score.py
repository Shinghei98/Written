"""Scoring: 12,017 mappings become claims about a person.

**This is the first thing in the system that says something about somebody.**
Everything before it is bookkeeping — a row was captured, an observation was
made, a term resolved to a concept. A `user_assertion` is the first artefact
that asserts *this person has an affinity to this concept*, and it is the reason
the vault exists.

It runs inside the resolver's own `semantic_run`, between the mappings and
`finalize_semantic_run`. Not a second run, deliberately: a score belongs to the
mappings it was computed from, and two runs could interleave with a distillation
and score against inputs that no longer exist. The finalizer's staleness check
covers the whole run, mappings and scores together, only because they share one.

## The scoring model, and what each number refuses to claim

`concept_scores` asks for six numbers and they are not interchangeable. Filling
them all from one aggregate would make five of them decoration.

- **`strength` saturates, it does not sum.** One concept carries 3,893
  `library_song` mappings; a linear sum would be meaningless above about three.
  `w / (w + HALF_WEIGHT)` maps any total onto [0,1) with an interpretable knob:
  at `w == HALF_WEIGHT` the strength is exactly 0.5. Owning a thousand songs by
  an artist is stronger than owning ten, and not a hundred times stronger.

- **`confidence` is about the evidence, not the affinity.** It rises with the
  number of distinct observations and with breadth across independence groups,
  because one source repeating itself is not corroboration. A single mapping is
  low-confidence however heavily weighted.

- **`independent_source_breadth` counts independence *groups*, never sources.**
  `apple_music`, `music_library` and `spotify` all carry the group `music` by
  design — three streaming services agreeing that you played a song is one
  witness, not three. Today every music mapping is in that one group, so this
  is 1 for every concept and will stay 1 until a YouTube observation exists.

- **`stability` is 0.0 on a first run and that is a refusal, not a placeholder.**
  Stability means a score held across runs. With no prior run there is no
  evidence either way, and 1.0 would assert a property from the absence of
  observation — the failure this codebase names as inferring absence from
  omission. The basis is recorded in `explanation` so the zero is readable as
  "not yet measurable" rather than "measured as unstable".

- **`missing_source_count` is what the user has connected that said nothing
  about this concept**, which is the honest denominator for how much of the
  picture we have. A concept evidenced by one of five connected sources is a
  different claim from one evidenced by the only source connected.

## What becomes an assertion

Not every scored concept. `capture broadly, promote narrowly` applies here as
much as at ingestion: a concept below `ELIGIBLE_STRENGTH` gets a score and no
claim, and a concept above it gets an assertion at `machine_state='eligible'`.
Everything scored is inspectable; only what clears the bar is assertable.

The predicate is `affinity_to` — user_claim, assertion-safe ("defeasible or
explicit user affinity"). It is the only predicate in the vocabulary that means
*this person likes this*.

**This file used to say here that an affinity never propagates along
`broader`, and the owner superseded that on 2026-08-25.** The directive:
direct evidence carries full weight; every term connected to it, directly or
transitively through predicate edges, receives a *decaying fraction* — the
registry's per-predicate λ (0291), multiplied per hop, cut off at a
negligibility floor. Liking one K-pop group still never becomes liking Asian
music *by arithmetic accident*: it becomes a small, authored, auditable
fraction of it by λ, and the fraction is visible in the evidence path. The
inferred tail exists to expand the global vocabulary and to be judged by the
person on the Memories page; most of it lands `candidate`, below every bar,
which is the design and not a defect.

## Watching against doing, which `affinity_to` cannot say

**An activity can be watched or done, and they are different facts about a
person.** Somebody who plays football and somebody who follows it share a
concept and share almost nothing else, and until now both arrived as
`affinity_to activity:soccer`. The gap was already written down two hundred
lines below this one, about a game named in a channel's keywords: *"Whether
somebody plays it is a different claim and is not made here."*

**The distinction belongs on the predicate, not on a second concept.** Minting
`activity:soccer` twice would split the evidence between the two and still not
say which was meant, because **the evidence decides, not the concept**. So one
concept keeps accumulating and the claim about it names the engagement:

    participates_in_activity   involvement evidence exists
    follows_activity           only viewing evidence exists
    affinity_to                evidence that says neither

**Which evidence means which is a property of the source and the act**, so it
is read from `semantic_private.sources.engagement_modes` — the column beside
`action_weights`, where a later reader looks — rather than from a list in this
file. A HealthKit workout is involvement; a YouTube subscription is viewing; a
saved track is neither, and saying so is the point of leaving it unmarked.

**Participation outranks viewing** where both exist, because it is a positive
fact that watching does not contradict: somebody who plays and also watches
plays. Only `concept_kind = 'activity'` is affected — for a creator, a work or
a topic there is nothing to watch *or* do, and `affinity_to` remains the whole
claim.

**A concept whose predicate changes carries the person's answer with it.** The
assertion is a different row under a different predicate, and both
`assertion_preferences` (keyed on assertion id) and `user_suppressions` (keyed
on predicate) would otherwise stop matching — so a "don't show me this" would be
silently undone by a re-score. `carry_user_decisions` copies rather than
invents, and copies nothing where there was no decision.
"""

from __future__ import annotations

import json
from typing import Any

# At this total weight a concept scores exactly 0.5. Calibrated against the real
# corpus: a strongly-evidenced artist accumulates roughly 8-15 weighted mappings
# (library songs at 0.48, plays at 0.78, ratings at 0.88), so 6.0 puts a
# well-evidenced artist above 0.5 and a one-song artist near 0.1.
HALF_WEIGHT = 6.0

# Confidence saturates on observation count the same way, but far sooner —
# a handful of independent observations is most of the confidence available.
HALF_OBSERVATIONS = 4.0

# Below this a concept is scored and makes no claim.
ELIGIBLE_STRENGTH = 0.35

# **Where propagation stops (owner, 2026-08-25: "unbounded with floor").**
# A propagated contribution below this raw-weight amount is negligible and the
# walk does not continue through it — depth emerges from the authored λ values
# and the evidence, never from a hop cap. In raw pre-saturation units, same as
# HALF_WEIGHT: 0.05 is one strong play (≈0.78) after two soundtrack_of-sized
# hops (0.25²), which matches the owner's worked example ending at the second
# hop for one song and reaching further only when many songs point the same
# way.
PROPAGATION_FLOOR = 0.05

AFFINITY_PREDICATE = "affinity_to"

# The two engagement predicates. Both are `user_claim` and `assertion_safe` in
# `ontology.relation_types`, which is what `guard_user_assertion_relation_class`
# demands of anything the scorer writes — the observed-action predicates
# (`watched`, `completed_activity`, `attended_activity_at`) are deliberately not
# assertion-safe, because what somebody did is evidence rather than a claim about
# them, and asserting one took the whole worker down once.
PARTICIPATION_PREDICATE = "participates_in_activity"
SPECTATING_PREDICATE = "follows_activity"

# Every predicate this scorer may write. The demotion sweep reads this: an
# assertion left standing under a predicate the sweep does not name is one no
# re-score can ever withdraw.
ASSERTABLE_PREDICATES = (
    AFFINITY_PREDICATE, PARTICIPATION_PREDICATE, SPECTATING_PREDICATE,
)

# **Only an activity can be watched or done.** A creator, a work, a genre or a
# topic has no such distinction — you do not "participate in" Bach — so
# everything else keeps `affinity_to` and the rule never has to guess.
ENGAGEMENT_KINDS = frozenset({"activity"})

# **A trip is an activity by kind and is not an engagement question.**
# `travel:*` concepts are `concept_kind = 'activity'`, and `assert_travel` writes
# them outside the concept loop with `affinity_to` for reasons of its own. They
# carry no mappings — calendar observations may not enter `observation_mappings`
# at all — so they cannot reach the rule below; this names them anyway, because
# a rule that depends on another rule's side effect is one nobody can read.
ENGAGEMENT_EXEMPT_KEY_PREFIXES = ("travel:",)

# **Concept kinds that are scored and never asserted.**
#
# A hub is where a concept *lives*, not something somebody likes. `hub:music` at
# 0.92 says this person likes music, which is true of everyone with a music
# library — it is the denominator, not a fact about them. The three that
# surfaced on a real profile were `music`, `ideas_learning` and `film_video`,
# and none of them distinguishes one person from another.
#
# **Scored, though, and that is deliberate.** `concept_scores` is what a
# Memories page groups by, and a hub with no score would leave a section with no
# heading. The exclusion is on the *claim*, which is the same distinction
# `notAnAction(.container)` draws for a playlist or a calendar: captured
# broadly, promoted narrowly, and a container is structurally not an act.
#
NEVER_ASSERTED_KINDS = frozenset({"hub"})

# **A work clears a lower bar than a creator, because the same strength means
# more evidence.** A creator accumulates across everything they touch — Bach is
# on 417 mappings — while a work is attested only by the songs that belong to
# it, and an album is one work and a dozen artists. Judging both at 0.35 asks a
# cast recording to be as well evidenced as a composer.
#
# **Set from the owner's judgement on their own rows, which is the only thing
# that could set it.** They were asked about three works and answered all three:
# *"Footloose is real"* (0.266, seven mappings), *"do not include Re:Zero"*
# (0.047, one), and — shown the result of the first cut — *"BanG Dream
# shouldn't be there"* (0.237, six).
#
# It went in at 0.20 first, deliberately below both Footloose and BanG Dream!,
# on the grounds that seven mappings against six is not a difference this scale
# can resolve and that splitting them would be fitting a constant to a single
# data point. That was right as far as it went: what was missing was a label on
# the second row, not a finer threshold. With both judged, 0.25 separates two
# *labelled* points rather than guessing between two unlabelled ones.
#
# 0.25 is a total weight of 2.0 — on these actions, five or six songs from the
# same work. It excludes the four-mapping cluster (Bleach, Thousand-Year Blood
# War, MyGO), where a franchise starts looking like one soundtrack somebody
# played, and `work:re_zero` at 0.047 by a wide margin.
#
# **One library and one reviewer, so this is a judgement rather than a
# measurement.** The next library is what would make it either.
ELIGIBLE_STRENGTH_BY_KIND = {"work": 0.25}

# **A bare decade, which is a different argument from the hub above.**
#
# Eras were deliberately kept assertable, on the owner's reading that they are
# the point: *"if he/she listens specifically to 80s German music, it would be a
# strong personality"*. That reading stands and this implements it rather than
# reversing it — **"80s German music" is a decade crossed with a language, not a
# decade.** The composite did not exist then, so the era had to carry it alone.
#
# What a bare decade actually carries was then measured on the owner's library:
# `era:1970s` at 0.403 rested on ABBA, Stevie Wonder, Frankie Kao's 姑娘的酒渦
# and Fritz Kreisler — anglophone pop, Mandopop and a violin recital. Three
# unrelated worlds under one claim, and 1970s British pop and 1970s Cantopop are
# not the same fact about a person. So the decade is the axis and `scene:*` is
# the claim, exactly as `sphere:*` remains assertable on its own: what language
# somebody listens in does differ between two people, and a decade alone barely
# does.
#
# **By key prefix rather than by kind**, because `era:`, `sphere:` and `scene:`
# are all `concept_kind = 'topic'` — the kind cannot separate the axis from the
# claim, and giving eras a kind of their own would rewrite thirteen concepts
# that six migrations already reference.
NEVER_ASSERTED_KEY_PREFIXES = ("era:",)

# **What the ontology may refuse to have inferred.** `review_required` is
# deliberately absent: 890 concepts carry it today and every one of them is
# assertable, so treating it as a refusal would silently empty most of the
# system. These two are the ones whose names already mean "not from inference" —
# `explicit_only` admits a claim the person makes themselves, `prohibited`
# admits none.
NEVER_INFERRED_POLICIES = ("explicit_only", "prohibited")


# **Aggregated in SQL rather than in Python.** 12,017 mappings across ~340
# concepts is small, but pulling them into the Lambda to group them would put
# somebody's whole library in memory for arithmetic Postgres does better — and
# the weights are already columns.
#
# `evidence_weight` and `recency_weight` are what the resolver stored per
# mapping; `default_reliability` and the per-action weight come from
# `semantic_private.sources`, which is authored data and not this file's
# business to invent.
# **A rejection is evidence about which concept the row was about.**
#
# The owner's model: liking a song admits three readings — the singer and the
# song, the singer only, the song only. Striking off the singer eliminates the
# first two, so what remains must be carried by whatever else the row names.
# It is the classical composer/performer/work dilemma with a pop name on it,
# and `CLASSICAL_PERFORMER_MIN_ALBUMS` already solves one corner of it.
#
# **The schema had already named this and nothing acted on it.** A suppression
# is written `label_semantics = 'ambiguous_rejection'`, against
# `explicit_confirmation` for a confirm — the vocabulary says outright that a
# rejection does not tell you *which* reading it was. Redistributing the
# evidence among the concepts that shared the row is disambiguating that. It is
# **not** a concept-level negative, which the contract forbids: nothing here
# asserts that the person dislikes the struck-off concept, only that the rows
# are better explained by something else on them.
#
# **The rule is "a different named role on the same row", and the data taught
# each half of that.** Cynthia Erivo's rows also carry Ariana Grande, Idina
# Menzel, Kristin Chenoweth and the Wicked Movie Cast — so boosting every
# co-occurring name would let striking off one cast member promote the other
# five, who are in exactly the same ambiguous position. Hence *different* role.
# The Berlin Philharmonic's rows carry **no work at all** — 108 creator
# mappings, zero `source_work` — so in classical the gainer is the composer,
# which is why this is written in the resolver's *roles* rather than in
# `concept_kind`.
#
# And it is symmetric because a real suppression demanded it: the first one
# anybody made was **Frank Wildhorn, who has no `creator` mappings at all** —
# he is the composer of *Jekyll & Hyde*. A creator-only rule did nothing for
# him. Striking off the writer says the same kind of thing as striking off the
# singer, so the performers and the work gain instead.
#
# **And genre, era, scene and sphere are excluded.** "I don't like the singer"
# says nothing new about the genre, which the row already supported; raising it
# would count one fact twice.
#
# **Conservation rather than a constant.** The freed weight is exactly what the
# suppressed concept was drawing from those rows, redistributed in proportion to
# what each recipient already rests on them. Measured on the real library:
# Erivo frees 4.247 and Wicked stands at 9.580, so Wicked rises to about 0.66
# from 0.615; the Berlin Philharmonic frees 13.894 across Beethoven at 13.99 and
# Mahler at 13.84. A multiplier would have needed a number nobody measured; this
# needs none, and says something truer — the listening did not change, only the
# account of it.
SUPPRESSION_TRANSFER = """
with weighted as (
  select m.concept_id, m.observation_id,
         m.evidence_path -> 0 ->> 'role' as role,
         m.evidence_weight * m.recency_weight * s.default_reliability
           * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0) as w
    from semantic_private.observation_mappings m
    join semantic_private.observations o on o.id = m.observation_id
    join semantic_private.sources s on s.source_code = o.source_code
   where m.semantic_run_id = %(run)s
     and m.user_id = %(user_id)s
     and m.mapping_state = 'accepted'
), suppressed as (
  select a.concept_id
    from semantic_private.assertion_preferences p
    join semantic_private.user_assertions a on a.id = p.assertion_id
   where p.user_id = %(user_id)s
     and a.user_id = %(user_id)s
     and p.display_state = 'suppressed'
     and a.concept_id is not null
), freed as (
  -- Per row *and per role*: a row whose performer was struck off frees the
  -- performer's weight, and one whose composer was frees the composer's. The
  -- role is carried through so recipients can exclude it.
  select w.observation_id, w.role as freed_role, sum(w.w) as amount
    from weighted w
    join suppressed s on s.concept_id = w.concept_id
   where w.role in ('creator', 'composer', 'source_work')
   group by w.observation_id, w.role
), recipients as (
  select w.observation_id, w.role, w.concept_id, w.w
    from weighted w
   where w.role in ('creator', 'composer', 'source_work')
     and w.concept_id not in (select concept_id from suppressed)
), shares as (
  -- The window cannot sit inside the aggregate below, so the share per row is
  -- computed first. The denominator is every recipient of a *different* role on
  -- the same row, which is what makes the split conserve the freed weight.
  select r.concept_id,
         f.amount * r.w
           / sum(r.w) over (partition by r.observation_id, f.freed_role) as share
    from recipients r
    join freed f
      on f.observation_id = r.observation_id
     and f.freed_role <> r.role
)
select concept_id, sum(share) as extra_weight
  from shares
 group by concept_id
"""

AGGREGATE = """
select
  m.concept_id,
  count(*)                                     as mapping_count,
  count(distinct m.observation_id)             as observation_count,
  count(distinct o.source_code)                as source_count,
  count(distinct s.independence_group)         as breadth,
  sum(
    m.evidence_weight
    * m.recency_weight
    * s.default_reliability
    * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0)
  )                                            as total_weight,
  avg(m.confidence)                            as mapping_agreement,
  avg(m.recency_quality * s.default_reliability) as evidence_quality,
  -- **Did any evidence for this concept say the person does it, and did any say
  -- they watch it.** Read from the source row rather than from a list in
  -- Python, so the answer sits beside `action_weights` where the next reader
  -- looks — and so an action nobody has classified stays *unmarked* rather than
  -- defaulting to either. Both false is a real and common answer: a saved track
  -- is neither watching nor doing.
  bool_or(s.engagement_modes ->> o.action_type = 'participation')
                                               as has_participation_evidence,
  bool_or(s.engagement_modes ->> o.action_type = 'spectating')
                                               as has_spectating_evidence,
  -- **The same channel must supply both, which is the whole claim.** A like is
  -- one act about one video; a subscription is a standing relationship somebody
  -- chose and has not undone. "Subscribed to them *and* liked their work" is a
  -- statement about one channel, so the two sets are intersected rather than
  -- tested independently.
  --
  -- The first version used two `bool_or`s over all mappings for the concept,
  -- and that is a different and much weaker claim: it fired whenever *some*
  -- subscription and *some* like anywhere carried the label. Measured on a real
  -- account, it promoted `concept:fashion` outright on one incidental `Fashion`
  -- tag from a NewJeans subscription and another from a LE SSERAFIM like — two
  -- unrelated artists, neither of whom the person follows for fashion — over a
  -- strength of 0.190 the scorer had correctly judged weak.
  --
  -- `&&` is array overlap. `array_agg ... filter` yields null when nothing
  -- matches and `null && anything` is null, so a concept with only one kind of
  -- attestation fails closed.
  (array_agg(distinct o.normalized_payload ->> 'channel_id')
     filter (where o.source_code = 'youtube'
                and o.action_type = 'subscription'
                and o.normalized_payload ? 'channel_id')
   && array_agg(distinct o.normalized_payload ->> 'channel_id')
     filter (where o.source_code = 'youtube'
                and o.action_type in ('liked', 'liked_video')
                and o.normalized_payload ? 'channel_id'))
                                               as youtube_co_attested,
  -- **The channel is the creator, and subscribing is the whole statement.**
  -- A `channel_identity` mapping off a `subscription` is a 1:1 declaration —
  -- this person follows this creator — resolved by an exact alias match at
  -- `evidence_weight` 1.000. Measured on a real account: `creator:onion_man`,
  -- `creator:kripparrian`, `creator:pewdiepie` and `creator:statquest` each
  -- carry exactly one such mapping and score 0.032-0.036.
  --
  -- **The curve punishes them for a property of the act rather than of the
  -- confidence.** `w/(w+6)` rewards accumulation, which is right for a
  -- musician — liking more of their songs really is more evidence — and
  -- meaningless here, because you cannot subscribe twice. There is nothing
  -- further to accumulate, so a bar calibrated on accumulation can never be
  -- reached, at any weight. That is `0138`'s argument applied to the case
  -- where the conjunction is unavailable.
  bool_or(m.youtube_semantic_kind = 'channel_identity'
          and o.action_type = 'subscription')  as youtube_channel_declared,
  -- **And the works that channel's own keywords name.** The same argument as
  -- the clause above, reaching one object further: a subscription is a
  -- standing choice, `Kripparrian` and `Hearthstone` are both read off the
  -- same declaration, and neither can be accumulated by subscribing twice.
  --
  -- **`uploader_tag` here means the work reading, and the type system is what
  -- makes that exact.** `0168` gives the two readings two roles but one stored
  -- kind, so the kind alone cannot tell them apart — the concept's *kind* can.
  -- The creator-hinted term is refused on type against a `work` concept by
  -- `_type_compatible`, and `title_work` stores `written_title_tag`, so an
  -- `uploader_tag` mapping on a subscription that reached a work can only have
  -- come from `uploader_tag_work`. Read together with the `kind == 'work'`
  -- test in the promotion below; either alone would be wrong.
  bool_or(m.youtube_semantic_kind = 'uploader_tag'
          and o.action_type = 'subscription')  as youtube_tag_declared
from semantic_private.observation_mappings m
join semantic_private.observations o on o.id = m.observation_id
join semantic_private.sources s on s.source_code = o.source_code
where m.semantic_run_id = %(run)s
  and m.user_id = %(user_id)s
  and m.mapping_state = 'accepted'
group by m.concept_id
having sum(
    m.evidence_weight * m.recency_weight * s.default_reliability
    * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0)
  ) > 0
"""

# The mappings behind one concept, for `assertion_evidence`. Its
# `independence_group` must equal the group of the source the observation came
# from — a trigger checks it — so the group is read here rather than assumed.
EVIDENCE = """
select m.id as mapping_id, s.independence_group,
       m.evidence_weight * m.recency_weight * s.default_reliability
         * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0)
         as weight,
       m.recency_weight, m.recency_quality, m.recency_policy_version,
       m.recency_rule_id, m.recency_status, m.recency_timestamp_quality,
       o.source_code, o.action_type
from semantic_private.observation_mappings m
join semantic_private.observations o on o.id = m.observation_id
join semantic_private.sources s on s.source_code = o.source_code
where m.semantic_run_id = %(run)s and m.user_id = %(user_id)s
  and m.concept_id = %(concept)s and m.mapping_state = 'accepted'
"""

CONNECTED_SOURCES = """
select count(distinct source_code) as n
from semantic_private.observations where user_id = %(user_id)s
"""

INSERT_SCORE = """
insert into semantic_private.concept_scores (
  semantic_run_id, user_id, ontology_version_id, concept_id,
  strength, confidence, independent_source_breadth, stability,
  usable_source_count, missing_source_count, explanation,
  mapping_agreement, evidence_quality, recency_policy_version, recency_as_of
) values (
  %(run)s, %(user_id)s, %(version)s, %(concept)s,
  %(strength)s, %(confidence)s, %(breadth)s, %(stability)s,
  %(usable)s, %(missing)s, %(explanation)s,
  %(agreement)s, %(quality)s, %(policy)s, %(as_of)s
)
on conflict (semantic_run_id, concept_id) do nothing
"""

FIND_ASSERTION = """
select id from semantic_private.user_assertions
where user_id = %(user_id)s and predicate_key = %(predicate)s
  and concept_id = %(concept)s
limit 1
"""

INSERT_ASSERTION = """
insert into semantic_private.user_assertions (
  user_id, predicate_key, concept_id, created_ontology_version_id,
  source_semantic_run_id, assertion_origin, machine_state
) values (
  %(user_id)s, %(predicate)s, %(concept)s, %(version)s,
  %(run)s, 'inferred', %(state)s
) returning id
"""

# **An assertion that stops being evidenced becomes `inactive`, never deleted.**
# "Collected then struck off" and "never collected" are different facts, which is
# the same reasoning `markedRemoved` carries in the legacy path.
UPDATE_ASSERTION = """
update semantic_private.user_assertions
set machine_state = %(state)s, updated_at = now()
where id = %(id)s and user_id = %(user_id)s
"""

# **For a long time the comment above described something the code could not do.**
# The eligibility test sat *before* the lookup — `if state != "eligible":
# continue` — so `UPDATE_ASSERTION` was only ever reached with `state`
# `eligible`, and an assertion that stopped clearing the bar simply kept
# standing. Found by changing the scorer so hubs assert nothing, deploying it,
# re-scoring, and watching `hub:music`, `hub:film_video` and
# `hub:ideas_learning` come back `eligible` from a run that had not touched
# them. The scorer could add a claim and could not withdraw one.
#
# Two ways a claim stops holding, and they need two statements because the
# second concept never reaches the loop at all:
#
#   - **Scored and no longer eligible** — the strength fell, or the kind is one
#     that is never asserted. Demoted inside the loop.
#   - **Not scored at all** — the ontology dropped the concept, a ban removed
#     every mapping, the source was disconnected. There is no iteration to hang
#     a demotion on, so it is a sweep after the loop.
#
# **`assertion_origin = 'inferred'` on both.** A declared assertion is something
# a person said about themselves, and a scorer that could retire one would let
# an absence of evidence overrule a statement.
#
# **Both statements name every assertable predicate, not one.** They took a
# single `predicate` while `affinity_to` was the only thing the scorer wrote, and
# leaving them that way would have made the engagement predicates unwithdrawable:
# a concept promoted to `follows_activity` and later falling below the bar would
# have kept its claim forever, because the statement meant to retire it was
# looking somewhere else. **An assertion under a predicate the sweep does not
# name is one no re-score can withdraw** — which is the same defect `0138`
# records from the other direction, a scorer that could add a claim and not
# remove one.
DEMOTE_ASSERTION = """
update semantic_private.user_assertions
set machine_state = 'inactive', updated_at = now()
where user_id = %(user_id)s and predicate_key = any(%(predicates)s::text[])
  and concept_id = %(concept)s
  and assertion_origin = 'inferred' and machine_state <> 'inactive'
"""

DEMOTE_UNSCORED_ASSERTIONS = """
update semantic_private.user_assertions
set machine_state = 'inactive', updated_at = now()
where user_id = %(user_id)s and predicate_key = any(%(predicates)s::text[])
  and assertion_origin = 'inferred' and machine_state <> 'inactive'
  and not (concept_id = any(%(scored)s::uuid[]))
"""

# **The same concept, asserted under a predicate this run did not choose.**
# An activity that used to be `affinity_to` and is now `follows_activity` would
# otherwise stand twice on the page, saying two things about one concept with
# only one of them current. Scoped to the concept, so it can never touch another.
DEMOTE_OTHER_PREDICATES = """
update semantic_private.user_assertions
set machine_state = 'inactive', updated_at = now()
where user_id = %(user_id)s and concept_id = %(concept)s
  and predicate_key = any(%(predicates)s::text[])
  and predicate_key <> %(keep)s
  and assertion_origin = 'inferred' and machine_state <> 'inactive'
returning id, predicate_key
"""

# **A person's answer follows their term to its new predicate.**
#
# Two tables record an answer and both are keyed in a way a predicate change
# breaks: `assertion_preferences` on the assertion id, which is new, and
# `user_suppressions` on the predicate itself. So a re-score that moved
# `activity:soccer` from `affinity_to` to `follows_activity` would put a
# suppressed term back on somebody's page — a decision undone by a background
# job, which is the worst way for one to be undone.
#
# **It copies and never invents.** `select … where` finds nothing when there was
# no decision, and both statements are no-ops then. Measured before writing:
# every suppression and preference in the database today is on a `creator`, so
# this repairs nothing that has happened yet and is written for the first time
# an activity is suppressed.
CARRY_PREFERENCE = """
insert into semantic_private.assertion_preferences (
  assertion_id, user_id, display_state, last_feedback_event_id
)
select %(to_assertion)s, %(user_id)s, old.display_state, old.last_feedback_event_id
  from semantic_private.assertion_preferences as old
 where old.assertion_id = %(from_assertion)s and old.user_id = %(user_id)s
   and old.display_state <> 'default'
on conflict (assertion_id, user_id) do nothing
"""

CARRY_SUPPRESSION = """
insert into semantic_private.user_suppressions (
  user_id, concept_id, user_term_id, predicate_key, surface,
  source_feedback_event_id, active
)
select old.user_id, old.concept_id, old.user_term_id, %(keep)s, old.surface,
       old.source_feedback_event_id, old.active
  from semantic_private.user_suppressions as old
 where old.user_id = %(user_id)s and old.concept_id = %(concept)s
   and old.predicate_key = %(from_predicate)s and old.active
   and not exists (
     select 1 from semantic_private.user_suppressions as held
      where held.user_id = old.user_id and held.concept_id = old.concept_id
        and held.predicate_key = %(keep)s and held.surface = old.surface)
"""

INSERT_SCORE_VERSION = """
insert into semantic_private.assertion_score_versions (
  assertion_id, user_id, semantic_run_id, ontology_version_id,
  strength, confidence, breadth, stability, surfacing_score, display_payload,
  mapping_agreement, evidence_quality, recency_policy_version, recency_as_of
) values (
  %(assertion)s, %(user_id)s, %(run)s, %(version)s,
  %(strength)s, %(confidence)s, %(breadth)s, %(stability)s,
  %(surfacing)s, %(payload)s,
  %(agreement)s, %(quality)s, %(policy)s, %(as_of)s
)
on conflict (assertion_id, semantic_run_id) do nothing
returning id
"""

INSERT_EVIDENCE = """
insert into semantic_private.assertion_evidence (
  assertion_score_version_id, user_id, observation_mapping_id,
  contribution, independence_group, evidence_path,
  recency_weight, recency_quality, recency_policy_version,
  recency_rule_id, recency_status, recency_timestamp_quality, recency_as_of
) values (
  %(version_id)s, %(user_id)s, %(mapping)s,
  %(contribution)s, %(group)s, %(path)s,
  %(recency_weight)s, %(recency_quality)s, %(policy)s,
  %(rule)s, %(status)s, %(quality_label)s, %(as_of)s
)
on conflict (assertion_score_version_id, observation_mapping_id) do nothing
"""

#: **What the person has struck, and for which predicate.** A suppression is
#: keyed on `(concept, user_facing_predicate)` and only `active` ones count —
#: `restored_at` being set is the user changing their mind, and the row survives
#: either way so the history of having struck it is not rewritten.
ACTIVE_SUPPRESSIONS = """
select concept_id, user_facing_predicate
  from semantic_private.user_term_suppressions
 where user_id = %(user_id)s and active and concept_id is not null
"""

CONCEPT_LABELS = """
select c.id, c.concept_key, r.preferred_label, r.concept_kind, r.inference_policy
from ontology.concepts c
join ontology.concept_revisions r on r.concept_id = c.id
where r.ontology_version_id = %(version)s
"""

# **The traversable graph: every predicate edge carrying an authored λ.**
# The owner's clarification (2026-08-25): inference means *all* predicated
# terms, connected directly or indirectly — so the traversal is the whole
# edge set and the per-predicate λ values decide the flow, never a whitelist
# of edge types here. `propagation_weight = 0` rows simply carry no flow,
# which is the registry's decision to make, not this query's.
#
# Bounded three ways, each from the registry or the edge itself: λ > 0, the
# edge's own confidence clears the predicate's `minimum_relation_confidence`,
# and only curated/provider provenance traverses in v1 — a model-stated edge
# proposes vocabulary, it does not yet carry weight. `presumed_term_relations`
# (0306) stays non-traversable exactly as its header says: only catalogue
# edges propagate.
PROPAGATION_EDGES = """
select e.subject_concept_id as source, e.object_concept_id as target,
       t.propagation_weight as lam
from ontology.concept_edges e
join ontology.relation_types t on t.predicate_key = e.predicate_key
where e.ontology_version_id = %(version)s
  and e.status = 'active'
  and t.propagation_weight > 0
  and coalesce(e.confidence, 1.0) >= t.minimum_relation_confidence
  and e.provenance_type in ('curated', 'provider')
"""

# The single strongest mapping behind a source concept, so a derived
# assertion's evidence can name a real row — `assertion_evidence` demands an
# observation mapping, and the honest one is the mapping the propagated weight
# mostly came from, with the path saying how it travelled.
TOP_MAPPING_FOR_CONCEPT = """
select m.id as mapping_id, s.independence_group,
       m.recency_weight, m.recency_quality, m.recency_policy_version,
       m.recency_rule_id, m.recency_status, m.recency_timestamp_quality,
       o.source_code, o.action_type
from semantic_private.observation_mappings m
join semantic_private.observations o on o.id = m.observation_id
join semantic_private.sources s on s.source_code = o.source_code
where m.semantic_run_id = %(run)s and m.user_id = %(user_id)s
  and m.concept_id = %(concept)s and m.mapping_state = 'accepted'
order by m.evidence_weight * m.recency_weight desc
limit 1
"""


def _propagate(direct: dict[str, float],
               edges: dict[str, list[tuple[str, float]]]) -> dict[str, dict[str, Any]]:
    """Walk λ-weighted edges outward from every directly-evidenced concept.

    Per (source, target): the **max** over paths of the per-edge λ product —
    two routes to the same place are one reason, not two, and max is what
    stops a dense subgraph inflating itself. Across sources the contributions
    **sum**, which is the point: many K-pop plays genuinely add up on
    `genre:k_pop`.

    The frontier prunes when `λ_path × W_source < PROPAGATION_FLOOR`, so the
    walk is unbounded in hops and bounded in effect. Best-first per source
    (largest λ first) so the first time a node is settled it is settled at its
    best path.

    Returns target -> {"weight": Σ contributions, "sources": [(source_id,
    contribution, λ_path, hops)] sorted strongest first}.
    """
    import heapq
    received: dict[str, dict[str, Any]] = {}
    for source_id, source_weight in direct.items():
        if source_weight <= 0:
            continue
        best: dict[str, float] = {source_id: 1.0}
        hops: dict[str, int] = {source_id: 0}
        heap = [(-1.0, source_id)]
        while heap:
            neg_lam, node = heapq.heappop(heap)
            lam_here = -neg_lam
            if lam_here < best.get(node, 0.0):
                continue
            for target, lam_edge in edges.get(node, ()):
                lam_path = lam_here * lam_edge
                if lam_path * source_weight < PROPAGATION_FLOOR:
                    continue
                if lam_path > best.get(target, 0.0):
                    best[target] = lam_path
                    hops[target] = hops[node] + 1
                    heapq.heappush(heap, (-lam_path, target))
        for target, lam_path in best.items():
            if target == source_id or target in direct:
                # **Propagation only reaches concepts holding no direct
                # mapping in this run.** A directly-evidenced concept's
                # evidence already speaks; adding a fraction of a neighbour's
                # would count one library twice.
                continue
            entry = received.setdefault(target, {"weight": 0.0, "sources": []})
            contribution = lam_path * source_weight
            entry["weight"] += contribution
            entry["sources"].append(
                (source_id, contribution, lam_path, hops[target]))
    for entry in received.values():
        entry["sources"].sort(key=lambda s: -s[1])
    return received

# **Read from the mappings rather than passed in.** A score's recency policy
# must be the one its evidence was weighted under; taking it as an argument
# means two places can disagree and the row would still insert, recording a
# policy that never touched the numbers.
RUN_POLICY_VERSION = """
select recency_policy_version, count(*) as n
from semantic_private.observation_mappings
where semantic_run_id = %(run)s and user_id = %(user_id)s
group by recency_policy_version order by n desc limit 1
"""


def _saturate(value: float, half: float) -> float:
    """Map a non-negative total onto [0,1), reaching 0.5 at `half`.

    Chosen over a hard cap because a cap loses all ordering above it: every
    heavily-evidenced concept would tie at 1.0 and the strongest signal in the
    library would be indistinguishable from the tenth strongest.
    """
    if value <= 0:
        return 0.0
    return value / (value + half)



# **A trip somebody took, asserted without a single mapping.**
#
# Calendar observations may not enter `observation_mappings` — refused in Python
# by `ObservationMapper._source_projection_is_valid`, again in the database by
# `guard_calendar_observation_mapping`, and §7 licenses only the classifier over
# calendar rows. None of that is bypassed here, and none of it needs to be:
# `assertion_has_calendar_evidence` already has a branch matching on
# `predicate_key` with no mapping join at all, so a calendar assertion is meant
# to be recognised by its predicate rather than by evidence rows.
#
# The predicate is the classifier's own, `scheduled_travel_to`, and it has been
# in `ontology.relation_types` all along.
#
# **The latest reading per item, never every reading.** Observations are
# immutable, so a projector bump leaves the old projection in place beside the
# new one — `place:saint_louis` from before the anchor rule still sits in the
# vault next to the row that correctly omits it. Taking `distinct on
# (source_item_hmac) … order by created_at desc` is what stops a superseded
# reading resurrecting a base as a holiday.
TRAVEL_PLACES = """
select place_key, occurred_at from (
  select distinct on (observation.source_item_hmac)
         observation.normalized_payload ->> 'place_key' as place_key,
         observation.occurred_at
  from semantic_private.observations as observation
  where observation.user_id = %(user_id)s
    and semantic_private.is_private_calendar_source(observation.source_code)
  order by observation.source_item_hmac, observation.created_at desc
) as latest
where place_key is not null
"""

TRAVEL_CONCEPT = """
select concept.id
from ontology.concepts as concept
join ontology.concept_revisions as revision
  on revision.concept_id = concept.id
 and revision.ontology_version_id = %(version)s
 and revision.status = 'active'
where concept.concept_key = %(key)s
"""

# One booked trip is sufficient, which is the owner's rule and the classifier's
# own — `scheduled_travel_to` carries `evidence_confidence` 0.92 off a single
# strong ticket. There is no bar to clear and nothing to accumulate, so the
# figures below are flat rather than computed: a second trip to the same place
# says "again", not "more true".
TRAVEL_STRENGTH = 0.5
TRAVEL_CONFIDENCE = 0.92


def assertion_predicate(kind: str | None, concept_key: str, aggregate: Any) -> str:
    """Which claim this evidence supports: doing it, watching it, or neither.

    **The evidence decides, not the concept.** One `activity:soccer` accumulates
    everything and this picks the sentence to put in front of it, so a person who
    plays and a person who follows are told apart without splitting the term.

    Participation wins where both are present: it is a positive fact that
    watching does not contradict. Where neither is present the answer is
    `affinity_to` — which is not a failure but the honest reading of evidence
    that says nothing about engagement, and is what every non-activity concept
    gets by construction.
    """
    if kind not in ENGAGEMENT_KINDS:
        return AFFINITY_PREDICATE
    if concept_key.startswith(ENGAGEMENT_EXEMPT_KEY_PREFIXES):
        return AFFINITY_PREDICATE
    if aggregate.get("has_participation_evidence"):
        return PARTICIPATION_PREDICATE
    if aggregate.get("has_spectating_evidence"):
        return SPECTATING_PREDICATE
    return AFFINITY_PREDICATE


def carry_user_decisions(connection, *, user_id: str, concept_id: str,
                         keep: str, retired: list[dict[str, Any]],
                         assertion_id: str) -> int:
    """Move a suppression or a confirmation onto the predicate now in use.

    Returns how many decisions were carried, so a run that moved somebody's
    answer says so rather than doing it quietly.
    """
    carried = 0
    for row in retired:
        with connection.cursor() as cursor:
            cursor.execute(CARRY_PREFERENCE, {
                "to_assertion": assertion_id, "from_assertion": row["id"],
                "user_id": user_id,
            })
            carried += cursor.rowcount
            cursor.execute(CARRY_SUPPRESSION, {
                "user_id": user_id, "concept": concept_id, "keep": keep,
                "from_predicate": row["predicate_key"],
            })
            carried += cursor.rowcount
    return carried


def assert_travel(connection, user_id: str, run_id: str, version: str,
                  as_of: Any, policy_version: Any,
                  suppressed: set[tuple[str, str]], counts: dict[str, Any]) -> list[str]:
    """Assert a trip per place the calendar says somebody went to.

    Returns the concept ids asserted. Writes no evidence rows, which is what
    keeps every calendar guard satisfied rather than argued with.

    **The caller must add these to `scored_concepts`.** The demotion sweep
    retires every `affinity_to` assertion whose concept this run did not score,
    and a trip is scored here rather than in the concept loop — so without that
    the sweep sets each trip `inactive` moments after it is written, which is
    exactly what happened the first time: two assertions, two current scores,
    both dead on arrival and invisible to the page."""
    with connection.cursor() as cursor:
        cursor.execute(TRAVEL_PLACES, {"user_id": user_id})
        places = {row["place_key"]: row["occurred_at"] for row in cursor.fetchall()}
    if not places:
        return []

    asserted: list[str] = []
    for place_key in sorted(places):
        travel_key = "travel:" + place_key.split(":", 1)[1]
        with connection.cursor() as cursor:
            cursor.execute(TRAVEL_CONCEPT, {"version": version, "key": travel_key})
            row = cursor.fetchone()
        # A place with no minted trip resolves to nothing. Counted by its
        # absence rather than raised: the vocabulary is authored, and a place the
        # catalogue can name before the ontology can is an ordinary lag.
        if row is None:
            continue
        concept_id = str(row["id"])

        with connection.cursor() as cursor:
            cursor.execute(FIND_ASSERTION, {
                "user_id": user_id, "predicate": "affinity_to",
                "concept": concept_id,
            })
            existing = cursor.fetchone()
            # The same refusal on the travel route, which writes outside the
            # concept loop and would otherwise be the one place a struck term
            # could still be asserted.
            if existing is None and (concept_id, "affinity_to") in suppressed:
                counts["user_suppressed"] = counts.get("user_suppressed", 0) + 1
                continue
            if existing is None:
                cursor.execute(INSERT_ASSERTION, {
                    "user_id": user_id, "predicate": "affinity_to",
                    "concept": concept_id, "version": version,
                    "run": run_id, "state": "eligible",
                })
                assertion_id = str(cursor.fetchone()["id"])
            else:
                assertion_id = str(existing["id"])
                cursor.execute(UPDATE_ASSERTION, {
                    "id": assertion_id, "user_id": user_id, "state": "eligible",
                })

            # **A score with no evidence, and that is the whole point.**
            # `list_assertions` withholds an inferred assertion whose score was
            # not computed at the current revision, so a trip needs a score row
            # to be visible at all — but every evidence guard fires on
            # `assertion_evidence`, and there are no rows here to fire on.
            cursor.execute(INSERT_SCORE_VERSION, {
                "assertion": assertion_id, "user_id": user_id, "run": run_id,
                "version": version, "strength": TRAVEL_STRENGTH,
                "confidence": TRAVEL_CONFIDENCE, "breadth": 1,
                "stability": 0.0, "surfacing": TRAVEL_STRENGTH,
                "payload": "{}", "agreement": None, "quality": None,
                "policy": policy_version, "as_of": as_of,
            })
        asserted.append(concept_id)
    return asserted


def score_user(connection, user_id: str, run_id: str, version: str,
               as_of: Any) -> dict[str, Any]:
    """Score every concept this run mapped, and assert the ones that clear the bar.

    Returns counts for the run metrics. Writes nothing outside the run, and
    promotes nothing — `finalize_semantic_run` does that, and only after
    re-checking that the input revision has not moved.
    """
    counts: dict[str, Any] = {
        "scored": 0, "eligible": 0, "candidate": 0, "evidence_rows": 0,
        "demoted": 0,
    }
    scored_concepts: list[str] = []
    travel_concepts: list[str] = []

    with connection.cursor() as cursor:
        cursor.execute(RUN_POLICY_VERSION, {"run": run_id, "user_id": user_id})
        row = cursor.fetchone()
    if row is None:
        # No mappings, so nothing to score. Not a failure: a run over a library
        # that resolved to nothing is a real and uninteresting outcome.
        return counts
    policy_version = row["recency_policy_version"]

    # **A trip is suggested, and the person strikes it off if it is wrong.**
    # The owner's ruling: treat it exactly like a creator or a content creator —
    # assert it, show it, and let suppression be the correction. Being wrong in
    # public and corrected is how the model learns which evidence means what,
    # and the long game is latent correlation that no hand-written rule would
    # have found.
    #
    # **The predicate is `affinity_to`, and the choice is deliberate.**
    # `travel_interest` is the semantically obvious one and its description
    # forbids precisely this — *"never entailed by a booking alone"* — so using
    # it would mean overriding a sentence written to stop it. `affinity_to` is
    # `assertion_safe` and means *"defeasible or explicit user affinity"*:
    # defeasible is exactly the model here, a claim that stands until the person
    # overturns it. It is also the owner's own framing, that a place is an
    # affinity.
    #
    # `scheduled_travel_to` is not used and cannot be: it is
    # `relation_class = 'observed_action'` with `assertion_safe = false`, because
    # what somebody did is evidence rather than a claim about them. Asserting it
    # took the whole worker down once.
    with connection.cursor() as cursor:
        cursor.execute(ACTIVE_SUPPRESSIONS, {"user_id": user_id})
        suppressed = {
            (str(row["concept_id"]), row["user_facing_predicate"])
            for row in cursor.fetchall()
        }
    counts["user_suppressions"] = len(suppressed)

    travel_concepts = assert_travel(
        connection, user_id=user_id, run_id=run_id, version=version,
        as_of=as_of, policy_version=policy_version,
        suppressed=suppressed, counts=counts,
    )
    counts["travel"] = len(travel_concepts)

    with connection.cursor() as cursor:
        cursor.execute(CONCEPT_LABELS, {"version": version})
        labels = {str(row["id"]): row for row in cursor.fetchall()}


    with connection.cursor() as cursor:
        cursor.execute(CONNECTED_SOURCES, {"user_id": user_id})
        row = cursor.fetchone()
        connected = int(row["n"]) if row else 0

    with connection.cursor() as cursor:
        cursor.execute(AGGREGATE, {"run": run_id, "user_id": user_id})
        aggregates = cursor.fetchall()

    # The weight freed by suppressed creators, already apportioned to the
    # composers and works that shared their rows. Fetched separately rather than
    # folded into `AGGREGATE` so the base scoring query stays the thing it has
    # always been, and so a run with no suppressions does no extra arithmetic.
    with connection.cursor() as cursor:
        cursor.execute(SUPPRESSION_TRANSFER, {"run": run_id, "user_id": user_id})
        transferred = {
            str(row["concept_id"]): float(row["extra_weight"])
            for row in cursor.fetchall()
        }
    counts["transferred_concepts"] = len(transferred)

    # **λ propagation (owner's directive, 2026-08-25).** Runs on raw
    # pre-saturation weight, exactly like the suppression transfer above and
    # for the same reason: the curve, not the constant, decides what a
    # fraction is worth. Direct weight per concept is what the loop below will
    # saturate — total plus transfer — so the walk starts from the same
    # numbers the person's direct terms are scored on.
    direct_weights = {
        str(agg["concept_id"]):
            float(agg["total_weight"]) + transferred.get(str(agg["concept_id"]), 0.0)
        for agg in aggregates
    }
    with connection.cursor() as cursor:
        cursor.execute(PROPAGATION_EDGES, {"version": version})
        edges: dict[str, list[tuple[str, float]]] = {}
        for row in cursor.fetchall():
            edges.setdefault(str(row["source"]), []).append(
                (str(row["target"]), float(row["lam"])))
    propagated = _propagate(direct_weights, edges)
    counts["propagated_concepts"] = len(propagated)

    for agg in aggregates:
        concept_id = str(agg["concept_id"])
        label = labels.get(concept_id, {})

        # **The transfer is added before saturation, not after.** Saturation is
        # what makes a strength comparable between people, and adding to the
        # output of a curve that is nearly flat at the top would give a large
        # transfer almost no effect on a well-evidenced concept and a small one
        # a large effect on a weak one — the opposite of what the evidence says.
        # It is the same arithmetic that made a flat 0.3 performer weight
        # useless: the curve, not the constant, decides what a change is worth.
        transfer = transferred.get(concept_id, 0.0)
        strength = _saturate(float(agg["total_weight"]) + transfer, HALF_WEIGHT)
        observation_confidence = _saturate(
            float(agg["observation_count"]), HALF_OBSERVATIONS)
        breadth = int(agg["breadth"])
        # Breadth multiplies confidence rather than strength: a second
        # independent witness does not make somebody like an artist more, it
        # makes us more sure they do.
        confidence = min(1.0, observation_confidence * (1.0 + 0.25 * (breadth - 1)))
        usable = int(agg["source_count"])

        explanation = {
            "total_weight": round(float(agg["total_weight"]), 4),
            "mapping_count": int(agg["mapping_count"]),
            "observation_count": int(agg["observation_count"]),
            "half_weight": HALF_WEIGHT,
            # Recorded whenever it is non-zero, because a score that moved for a
            # reason nobody can see is the thing an explanation exists to stop.
            **({"transferred_from_suppressed": round(transfer, 4)} if transfer else {}),
            "stability_basis": "no_prior_run",
            "concept_key": label.get("concept_key"),
        }

        with connection.cursor() as cursor:
            cursor.execute(INSERT_SCORE, {
                "run": run_id, "user_id": user_id, "version": version,
                "concept": concept_id,
                "strength": strength, "confidence": confidence,
                "breadth": breadth, "stability": 0.0,
                "usable": usable, "missing": max(0, connected - usable),
                "explanation": json.dumps(explanation),
                "agreement": float(agg["mapping_agreement"]),
                "quality": float(agg["evidence_quality"]),
                "policy": policy_version, "as_of": as_of,
            })
        counts["scored"] += 1
        scored_concepts.append(concept_id)

        kind = label.get("concept_kind")
        key = label.get("concept_key") or ""
        # **The ontology decides assertability, not only the key.**
        # `genre:apple_19` is Apple's "Worldwide" — a catalogue drawer rather
        # than a taste — and it scored 0.391 and was asserted about a real
        # person. Nothing in a key or a kind separates it from `genre:baroque`,
        # which has 45 children and is a perfectly good thing to say about
        # somebody, and `0220` measured that child count cannot either.
        #
        # So it is said in the ontology, on the concept, where one correction
        # serves every reader — and `inference_policy` already had the word for
        # it. `explicit_only` means *a person may claim this, the system may
        # never infer it*, which is exactly a container genre: still scored,
        # still evidence for its children, never a claim about anybody.
        # `prohibited` is the same refusal, harder.
        policy = label.get("inference_policy") or "inferable"
        if policy in NEVER_INFERRED_POLICIES:
            counts["policy_withheld"] = counts.get("policy_withheld", 0) + 1
            state = "candidate"
        elif kind in NEVER_ASSERTED_KINDS or key.startswith(NEVER_ASSERTED_KEY_PREFIXES):
            # Counted rather than skipped silently: a kind quietly asserting
            # nothing is indistinguishable from a kind nothing ever scored.
            counts["container_kind"] = counts.get("container_kind", 0) + 1
            state = "candidate"
        else:
            bar = ELIGIBLE_STRENGTH_BY_KIND.get(kind, ELIGIBLE_STRENGTH)
            # **Subscribed to a channel *and* liked something from that same
            # channel is eligible outright, whatever the strength.** The two are
            # different kinds of evidence rather than different amounts of one:
            # a like is a single act about a single video, a subscription is a
            # standing relationship somebody chose. Their conjunction, *on one
            # channel*, is the strongest statement this data can make.
            #
            # The same-channel part is load-bearing and was missing from the
            # first version — see `AGGREGATE`, where the intersection now
            # happens.
            #
            # A weight could not express it. Calibrated on the same account,
            # one mapping contributes ~0.21 after decay and the bar needs 3.23,
            # so a lone subscription reaches 0.036 even at the maximum weight of
            # 1.0 — no number in `action_weights` moves a two-mapping creator
            # across, which is why this is a rule rather than a tuning.
            #
            # Deliberately not a lower *bar* for subscriptions alone: that would
            # admit every channel somebody followed once and forgot, which is a
            # different and much weaker claim.
            co_attested = bool(agg.get("youtube_co_attested"))
            if co_attested and strength < bar:
                counts["subscribed_and_liked"] = \
                    counts.get("subscribed_and_liked", 0) + 1

            # **A subscribed channel asserts its own creator, and nothing
            # else.** Restricted to `creator` on purpose: subscribing to
            # Bioinformagician declares that you follow Bioinformagician, and
            # it does *not* declare bioinformatics — a subject is something you
            # would have to aggregate across channels, and it still has to,
            # which is why `subject:*` keeps accumulating past this rule.
            #
            # It is bounded by what the alias set holds. `channel_identity`
            # resolves only on an exact curated alias, so this cannot admit an
            # arbitrary channel name; it admits the ones somebody catalogued.
            # The cost is real and accepted: a person with sixty catalogued
            # subscriptions gets sixty terms, every one of them true, ranked by
            # strength so the strongest reads first.
            channel_declared = (
                kind == "creator" and bool(agg.get("youtube_channel_declared"))
            )
            if channel_declared and strength < bar:
                counts["subscribed_channel"] = \
                    counts.get("subscribed_channel", 0) + 1

            # **A subscribed channel also asserts the works its own keywords
            # name.** The rule above reaches the channel; this one reaches what
            # the channel says it is about, and stops there.
            #
            # **Why this is not the `subject` case the rule above refuses.**
            # That refusal is exact and stands: *"subscribing to
            # Bioinformagician declares that you follow Bioinformagician, and
            # it does not declare bioinformatics — a subject is something you
            # would have to aggregate across channels."* A work is the other
            # thing. `Hearthstone` in Kripparrian's keyword list is not a theme
            # abstracted from what he posts; it is the name of the object the
            # channel is about, written by its owner, and reading it aggregates
            # nothing. Whether somebody *plays* it is a different claim and is
            # not made here — the assertion is `affinity_to`, which is what it
            # already means for a creator nobody claims you have met.
            #
            # **Bounded twice over, and the bounds are what make it safe.**
            # `GAME_TAG_CATALOGUE` is a list somebody authored, so this cannot
            # admit an arbitrary keyword; and the same curve argument applies —
            # one subscription is one lineage at strength ~0.035 against a work
            # bar of 0.25, so no weight in `action_weights` reaches it and this
            # has to be a rule or nothing.
            #
            # **The cost, stated rather than discovered.** A person subscribed
            # to a games channel gets that game as a term whether they play it
            # or watch it, which is the same trade the creator rule already
            # accepted for sixty catalogued subscriptions — every one of them
            # true, ranked by strength so the strongest reads first, and struck
            # off in one tap by the person if wrong.
            tag_declared = (
                kind == "work" and bool(agg.get("youtube_tag_declared"))
            )
            if tag_declared and strength < bar:
                counts["subscribed_work"] = \
                    counts.get("subscribed_work", 0) + 1

            state = ("eligible"
                     if (strength >= bar or co_attested or channel_declared
                         or tag_declared)
                     else "candidate")
        counts[state] += 1
        if state != "eligible":
            # Scored and inspectable, asserting nothing. Promote narrowly — and
            # withdraw anything this concept was asserting before, since it no
            # longer clears the bar it once cleared. Every predicate, because
            # the one it was asserting under is not necessarily the one this run
            # would have chosen.
            with connection.cursor() as cursor:
                cursor.execute(DEMOTE_ASSERTION, {
                    "user_id": user_id,
                    "predicates": list(ASSERTABLE_PREDICATES),
                    "concept": concept_id,
                })
                counts["demoted"] += cursor.rowcount
            continue

        predicate = assertion_predicate(kind, key, agg)
        if predicate != AFFINITY_PREDICATE:
            counts[predicate] = counts.get(predicate, 0) + 1

        with connection.cursor() as cursor:
            cursor.execute(FIND_ASSERTION, {
                "user_id": user_id, "predicate": predicate,
                "concept": concept_id,
            })
            existing = cursor.fetchone()

        # **What the person struck is not asserted about them, and an assertion
        # that already stands is demoted rather than left alone.** Placed here
        # because both `state` and `predicate` are known, and because it has to
        # reach the *update* as well as the insert: a term struck after it was
        # asserted is the case that matters most, and gating only the insert
        # would leave it standing forever.
        #
        # `candidate`, not absent — the concept is still scored and still
        # evidence. This is the same withholding shape as `policy_withheld`, and
        # it is a *personal* refusal: it says nothing about whether the term is
        # right for anybody else, which is why it lives here and not in the
        # ontology.
        if (concept_id, predicate) in suppressed:
            counts["user_suppressed"] = counts.get("user_suppressed", 0) + 1
            state = "candidate"

        if existing:
            assertion_id = existing["id"]
            with connection.cursor() as cursor:
                cursor.execute(UPDATE_ASSERTION, {
                    "id": assertion_id, "user_id": user_id, "state": state,
                })
        else:
            with connection.cursor() as cursor:
                cursor.execute(INSERT_ASSERTION, {
                    "user_id": user_id, "predicate": predicate,
                    "concept": concept_id, "version": version,
                    "run": run_id, "state": state,
                })
                assertion_id = cursor.fetchone()["id"]

        # **One concept says one thing.** Anything this concept was asserting
        # under another predicate is retired, and whatever the person had
        # answered about it follows to the predicate now in use.
        with connection.cursor() as cursor:
            cursor.execute(DEMOTE_OTHER_PREDICATES, {
                "user_id": user_id, "concept": concept_id,
                "predicates": list(ASSERTABLE_PREDICATES), "keep": predicate,
            })
            superseded = cursor.fetchall()
        if superseded:
            counts["repredicated"] = counts.get("repredicated", 0) + len(superseded)
            counts["decisions_carried"] = counts.get("decisions_carried", 0) + \
                carry_user_decisions(
                    connection, user_id=user_id, concept_id=concept_id,
                    keep=predicate, retired=superseded, assertion_id=assertion_id,
                )

        payload = {
            "concept_key": label.get("concept_key"),
            "label": label.get("preferred_label"),
            "kind": label.get("concept_kind"),
            # **The claim, on the row the page reads.** `list_assertions` already
            # returns `predicate_key`, but a display payload that named only the
            # concept would leave a client unable to say *watches* rather than
            # *likes* without a second lookup.
            "predicate": predicate,
        }
        with connection.cursor() as cursor:
            cursor.execute(INSERT_SCORE_VERSION, {
                "assertion": assertion_id, "user_id": user_id, "run": run_id,
                "version": version, "strength": strength,
                "confidence": confidence, "breadth": breadth, "stability": 0.0,
                "surfacing": strength * confidence,
                "payload": json.dumps(payload),
                "agreement": float(agg["mapping_agreement"]),
                "quality": float(agg["evidence_quality"]),
                "policy": policy_version, "as_of": as_of,
            })
            version_row = cursor.fetchone()

        if version_row is None:
            # Already scored in this run. Its evidence is already written.
            continue
        score_version_id = version_row["id"]

        with connection.cursor() as cursor:
            cursor.execute(EVIDENCE, {
                "run": run_id, "user_id": user_id, "concept": concept_id,
            })
            evidence = cursor.fetchall()

        total = sum(float(e["weight"]) for e in evidence) or 1.0
        # Batched for the same reason the mappings are: one concept can rest on
        # thousands of mappings, and a round trip each turns an explanation into
        # a timeout.
        evidence_rows = []
        for item in evidence:
            evidence_rows.append({
                    "version_id": score_version_id, "user_id": user_id,
                    "mapping": item["mapping_id"],
                    # A share of the whole, so `contribution` stays in [0,1] and
                    # the set sums to one. It answers "how much of this claim
                    # rests on this row", which is what an explanation needs.
                    "contribution": float(item["weight"]) / total,
                    "group": item["independence_group"],
                    "path": json.dumps({
                        "source": item["source_code"],
                        "action": item["action_type"],
                    }),
                    "recency_weight": item["recency_weight"],
                    "recency_quality": item["recency_quality"],
                    "policy": item["recency_policy_version"],
                    "rule": item["recency_rule_id"],
                    "status": item["recency_status"],
                    "quality_label": item["recency_timestamp_quality"],
                "as_of": as_of,
            })
        if evidence_rows:
            with connection.cursor() as cursor:
                cursor.executemany(INSERT_EVIDENCE, evidence_rows)
            counts["evidence_rows"] += len(evidence_rows)

    # ------------------------------------------------------------------
    # The propagated tail: every concept the evidence reaches only through
    # λ-weighted edges. Same writes as a direct concept, marked derived at
    # every layer so nothing downstream can mistake arithmetic for evidence.
    # ------------------------------------------------------------------
    for concept_id, arrival in propagated.items():
        label = labels.get(concept_id)
        if label is None:
            # An edge reaching a concept with no active revision at this
            # version — counted, not scored; a claim needs a name.
            counts["propagated_unlabelled"] = \
                counts.get("propagated_unlabelled", 0) + 1
            continue

        strength = _saturate(arrival["weight"], HALF_WEIGHT)
        # **A derived concept's confidence counts reasons, not observations.**
        # It has no observations of its own; what it has is distinct direct
        # concepts pointing at it, and that is the honest analogue of the
        # observation count — one strong source is a hint, several agreeing is
        # a pattern. Breadth is 1: independence lives on real evidence.
        confidence = _saturate(float(len(arrival["sources"])), HALF_OBSERVATIONS)

        explanation = {
            "derived": True,
            "propagated_weight": round(arrival["weight"], 4),
            "direct_weight": 0,
            "source_concepts": [
                {"concept_key": (labels.get(s) or {}).get("concept_key"),
                 "contribution": round(c, 4), "lambda_path": round(l, 4),
                 "hops": h}
                for s, c, l, h in arrival["sources"][:8]
            ],
            "half_weight": HALF_WEIGHT,
            "propagation_floor": PROPAGATION_FLOOR,
            "stability_basis": "no_prior_run",
            "concept_key": label.get("concept_key"),
        }
        with connection.cursor() as cursor:
            cursor.execute(INSERT_SCORE, {
                "run": run_id, "user_id": user_id, "version": version,
                "concept": concept_id,
                "strength": strength, "confidence": confidence,
                "breadth": 1, "stability": 0.0,
                "usable": 0, "missing": connected,
                "explanation": json.dumps(explanation),
                "agreement": None, "quality": None,
                "policy": policy_version, "as_of": as_of,
            })
        counts["scored"] += 1
        scored_concepts.append(concept_id)

        kind = label.get("concept_kind")
        key = label.get("concept_key") or ""
        policy = label.get("inference_policy") or "inferable"
        if policy in NEVER_INFERRED_POLICIES:
            counts["policy_withheld"] = counts.get("policy_withheld", 0) + 1
            state = "candidate"
        elif kind in NEVER_ASSERTED_KINDS or key.startswith(NEVER_ASSERTED_KEY_PREFIXES):
            counts["container_kind"] = counts.get("container_kind", 0) + 1
            state = "candidate"
        else:
            bar = ELIGIBLE_STRENGTH_BY_KIND.get(kind, ELIGIBLE_STRENGTH)
            state = "eligible" if strength >= bar else "candidate"
        counts[state] += 1
        # **Unlike a direct concept, a derived `candidate` still gets its
        # assertion row.** The direct loop demotes-and-continues below the
        # bar; here the whole point of the tail is to reach the Memories page
        # under a cutoff release that admits it, and `list_assertions` already
        # includes `candidate` — machine_state is the claim's standing, not
        # its visibility.
        predicate = assertion_predicate(kind, key, {})
        if (concept_id, predicate) in suppressed:
            counts["user_suppressed"] = counts.get("user_suppressed", 0) + 1
            state = "candidate"

        with connection.cursor() as cursor:
            cursor.execute(FIND_ASSERTION, {
                "user_id": user_id, "predicate": predicate,
                "concept": concept_id,
            })
            existing = cursor.fetchone()
        if existing:
            assertion_id = existing["id"]
            with connection.cursor() as cursor:
                cursor.execute(UPDATE_ASSERTION, {
                    "id": assertion_id, "user_id": user_id, "state": state,
                })
        else:
            with connection.cursor() as cursor:
                cursor.execute(INSERT_ASSERTION, {
                    "user_id": user_id, "predicate": predicate,
                    "concept": concept_id, "version": version,
                    "run": run_id, "state": state,
                })
                assertion_id = cursor.fetchone()["id"]

        with connection.cursor() as cursor:
            cursor.execute(DEMOTE_OTHER_PREDICATES, {
                "user_id": user_id, "concept": concept_id,
                "predicates": list(ASSERTABLE_PREDICATES), "keep": predicate,
            })
            superseded = cursor.fetchall()
        if superseded:
            counts["repredicated"] = counts.get("repredicated", 0) + len(superseded)
            counts["decisions_carried"] = counts.get("decisions_carried", 0) + \
                carry_user_decisions(
                    connection, user_id=user_id, concept_id=concept_id,
                    keep=predicate, retired=superseded, assertion_id=assertion_id,
                )

        payload = {
            "concept_key": label.get("concept_key"),
            "label": label.get("preferred_label"),
            "kind": label.get("concept_kind"),
            "predicate": predicate,
            "derived": True,
        }
        with connection.cursor() as cursor:
            cursor.execute(INSERT_SCORE_VERSION, {
                "assertion": assertion_id, "user_id": user_id, "run": run_id,
                "version": version, "strength": strength,
                "confidence": confidence, "breadth": 1, "stability": 0.0,
                "surfacing": strength * confidence,
                "payload": json.dumps(payload),
                "agreement": None, "quality": None,
                "policy": policy_version, "as_of": as_of,
            })
            version_row = cursor.fetchone()
        if version_row is None:
            continue
        score_version_id = version_row["id"]

        # **Evidence names a real mapping, reached through a stated path.**
        # `assertion_evidence` demands an observation mapping; the honest one
        # is the strongest mapping behind each contributing source concept,
        # with the path recording the hop count and λ that carried it here.
        total = arrival["weight"] or 1.0
        evidence_rows = []
        for source_id, contribution, lam_path, hop_count in arrival["sources"][:5]:
            with connection.cursor() as cursor:
                cursor.execute(TOP_MAPPING_FOR_CONCEPT, {
                    "run": run_id, "user_id": user_id, "concept": source_id,
                })
                top = cursor.fetchone()
            if top is None:
                continue
            evidence_rows.append({
                "version_id": score_version_id, "user_id": user_id,
                "mapping": top["mapping_id"],
                "contribution": min(1.0, contribution / total),
                "group": top["independence_group"],
                "path": json.dumps({
                    "step": "lambda_propagation",
                    "from_concept_key": (labels.get(source_id) or {}).get("concept_key"),
                    "lambda_path": round(lam_path, 4),
                    "hops": hop_count,
                    "source": top["source_code"],
                    "action": top["action_type"],
                }),
                "recency_weight": top["recency_weight"],
                "recency_quality": top["recency_quality"],
                "policy": top["recency_policy_version"],
                "rule": top["recency_rule_id"],
                "status": top["recency_status"],
                "quality_label": top["recency_timestamp_quality"],
                "as_of": as_of,
            })
        if evidence_rows:
            with connection.cursor() as cursor:
                cursor.executemany(INSERT_EVIDENCE, evidence_rows)
            counts["evidence_rows"] += len(evidence_rows)

    # **The sweep, and its guard is the whole of its safety.** A run that scored
    # nothing has learned nothing, and running this against an empty
    # `scored_concepts` would retire every claim the person has — a failed
    # resolver, a disconnected source or an empty ontology version would read as
    # somebody who likes nothing. `score_user` already returns early when a run
    # mapped nothing at all (that path never reaches here); this covers the
    # other shape, where the loop ran and produced no scores.
    scored_concepts.extend(travel_concepts)
    if scored_concepts:
        with connection.cursor() as cursor:
            cursor.execute(DEMOTE_UNSCORED_ASSERTIONS, {
                "user_id": user_id,
                "predicates": list(ASSERTABLE_PREDICATES),
                "scored": scored_concepts,
            })
            counts["demoted"] += cursor.rowcount

    return counts
