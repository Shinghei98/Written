# Icebreakers: a shared bridge, and a different specific on each side

**Status: specification, nothing built.** Written against the first real match —
Timi liked David on 2026-08-14, he accepted, and `public.conversations` went from
zero rows to one. Every number below is from that pair or from the schema as it
stands.

## The sentence

The owner's shape, in his own examples:

> You both like **Italy**. Timi likes **Italian food**, ask her about it!

> You both like **anime**. Timi is obsessed with **One Piece**, ask her about it!

Three parts, and the middle one is what the legacy icebreaker cannot do:

| Part | Where it comes from |
|---|---|
| the **bridge** — Italy, anime | a concept *both* people reach |
| the **specific** — Italian food, One Piece | the partner's own term *under* that bridge |
| the **verb** — likes, is obsessed with | the renderer, in Swift, never in SQL |

**The bridge is shared; the specifics differ.** That is the whole difference from
`seed_icebreaker`, whose creator branch collapses both subjects onto one string —
so it can say *"you both listen to Ado"* and never *"you both like anime, and she
is the one who loves One Piece."*

## The schema already models this

Nothing here needs inventing. `semantic_private.dyad_alignment_pairs` carries:

    bridge_concept_id                   the shared parent
    viewer_assertion_id                 this reader's term under it
    subject_assertion_id                the partner's term under it
    graph_distance, relation_distance   how far each side sits from the bridge
    embedding_distance, transport_mass  how close the two sides are
    specificity, information_value      how much the bridge is worth saying
    explanation_path                    how the bridge was reached

and `icebreaker_frames` carries `bridge_mode`, `template_version`,
`frame_payload`, `rendered_text`, `state` and `exposed_at`.

**`specificity` and `information_value` are the interesting columns.** They are
what should rank *One Piece* above *anime* as the thing to ask about, and what
should stop a bridge so general that agreeing on it says nothing — the
`genre:asian_music` problem, a concept at 0.942 that is a container in all but
name and scores once for everything its four children score for.

## The blocks are the bridge graph

The block work of 2026-08-14 built exactly the graph a bridge walks. A block *is*
a candidate bridge: two people's K-Pop cards share `genre:k_pop` and hold
different terms underneath. The `broader` edges authored that night — members
reaching their genre, trips reaching TRAVEL, six creators reaching CONTENT
CREATORS — are the same edges an alignment traverses.

So the ranking has a shape already visible on the page: **the block is the
bridge, the rows inside it are the specifics.**

## What the first real dyad actually has

Measured, and it is the finding that should govern the build order:

    David   99 eligible assertions
    Timi     0 assertions, in any state
    direct concept overlap: 0

**There is no bridge to compute.** Timi's vault is calendar and YouTube only —
her 593 Spotify rows never reached it, because her device has not distilled since
Spotify was added to `semanticIngestionSources`. So the first authorised dyad in
the system would produce an empty run.

That is not a reason to wait. It is a reason to build the producer so that an
empty result is a *correct* result rather than a crash — and to test it against
the second pair, not the first.

## Rules the producer must hold

- **A dyad may only be computed for an authorised pair.**
  `guard_dyad_run_current` refuses any run where
  `active_match_authorization_id_v031(viewer, subject)` is null, and a
  conversation is what makes it non-null. This is why the match had to exist
  before any of this could be written.
- **Both revisions are pinned on the run.** `dyad_runs` carries
  `viewer_revision` and `subject_revision`; a frame computed against a stale
  revision is the same defect as a Memories page showing yesterday's scores, and
  `dyad_run_is_current` exists to answer it.
- **Provisional until seen, frozen after.** Phase 5's own words: *"atomically
  revalidate immediately before first display; freeze exposed frames as history;
  invalidate only unexposed frames."* A frame somebody has read is what they
  were told, and rewriting it later would make the record of a conversation
  disagree with the conversation.
- **Ingredients in SQL, language in Swift.** The legacy trigger does set
  intersection and knows no English, and `IcebreakerCard` picks the verb. Keep
  that split: "likes" against "is obsessed with" is a judgement about tone, and
  copy that needs a migration to change will not get changed.
- **The flip happens once.** `viewer` and `subject` are named on the row, so the
  sentence differs per reader by construction — but only one place may decide
  which side the reader is on. The legacy path learned this the hard way:
  anything downstream deciding for itself whether `subject_a` is "mine" is a
  second copy of that decision, and the day they disagree somebody is told to
  ask their match about their own favourite band.
- **No bridge means no card.** Never a generic one. This is settled behaviour
  from the legacy path and it is what the cleared `Unknown Organizer` theme now
  does.

## Open questions

1. **What makes a bridge worth saying?** `genre:asian_music` is shared by
   anybody who likes K-pop *or* J-pop *or* Cantopop, so agreeing on it is nearly
   free. `information_value` is the column for this and nothing computes it. A
   bridge that four of five people share is not a conversation.
2. **How far may a bridge be from a term?** One `broader` hop is "you both like
   anime". Four hops reaches `hub:music`, which is true of everybody with a
   library. `graph_distance` is recorded; the cap is undecided.
3. **May the two sides bridge on the same term?** If both love One Piece, is
   that a better icebreaker or a worse one? The sentence shape assumes a
   difference, and identical terms are the case the legacy path handled by
   collapsing — which is what made it dull.
4. **Whose YouTube may cross?** `concept_has_non_video_witness` exists because a
   concept only YouTube witnesses still discloses YouTube data. A bridge is
   shown to the *other* person, so III.E.3.b applies and the witness test must
   gate it — the same rule `matching_terms` follows, not the looser one Memories
   gets as the owner's own page.
5. **Does a frame survive a suppression?** If Timi strikes off One Piece after a
   frame naming it has been exposed, the frame is history and the term is gone.
   Frozen-and-honest is probably right, and it should be a decision rather than
   a consequence.
