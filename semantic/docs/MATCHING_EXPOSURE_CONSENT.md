# Matching exposure: the consent design

**Status: design, nothing built.** No migration, no Swift, no grant written.

## Why it is needed

`api.discover_profiles` returns each card with the terms that person may show on
the matching surface. Measured 2026-08-13, it returns **none, for everybody**:

| surface | rows per account | `can_select` |
|---|---|---|
| memories | 103 / 75 | **all true** |
| matching | 103 / 75 | **0** |
| bio | 103 / 75 | **0** |
| icebreaker | 103 / 75 | **0** |

All `permission_source = 'default_policy'`. That is not a fault — the default
grants everything on the surface that shows you to *yourself* and nothing on any
surface that shows you to somebody else. The system is fail-closed exactly where
it should be, and **nobody has ever been asked the question that opens it**.

Writing those booleans true by hand would be fabricating consent, which is the
thing `0061` and `guard_raw_healthkit_grant` exist to prevent.

## What is actually being asked

Three permissions, and they are a ladder rather than a set:

| | what it permits | what a person would feel |
|---|---|---|
| `can_select` | the term influences **who you are shown to**, and is never displayed | "use this to find people like me" |
| `can_name` | the term may be **shown** to a match | "let them see the word" |
| `can_explain` | the term may appear in a sentence saying **why** you matched | "say it out loud" |

**Ask for `select` and `name` together.** They are not useful apart: a term that
matches but cannot be named produces *"you two have something in common"* with
no content, which is worse than silence because it invites a question the app
refuses to answer. **Leave `can_explain` false and out of scope** — a sentence
explaining a match is a different act, and the schema treats it as one.

## The shape it has to take

**A standing policy, not an update.** `user_assertions_initialize_surface_permissions`
inserts four rows for every new assertion, with the three outward surfaces
`false`. So a one-off `update` over today's rows would be silently undone by
tomorrow's re-score. The grant must be a fact the trigger consults.

    semantic_private.user_surface_grants
      user_id, surface, allow_select, allow_name, allow_explain,
      consent_version, granted_at, revoked_at

- the init trigger reads it and stamps `permission_source = 'user_grant'`
- the grant RPC back-fills existing rows in the same transaction
- revoking sets `revoked_at` and narrows existing rows, which the existing
  `invalidate_on_surface_permission_narrowing_v031` trigger already turns into
  invalidated outputs

**`public.record_matching_grant(allow_select, allow_name, consent_version)`**,
modelled on `public.record_fitness_grant` (`0061`): subject is `auth.uid()` with
**no parameter for whose consent it is**, because a function that let a caller
name that would be a function for forging it.

## Per-assertion control already exists

No new picker. `matching_terms` already excludes an assertion whose
`assertion_preferences.display_state` is `suppressed`, or which has an active
`user_suppressions` row for `surface = 'matching'`. So the design is **a blanket
grant with per-term opt-out through the mechanism Memories already draws** —
the same suppression a person uses to remove a term from their own page.

That is worth stating plainly to the user, because it means the answer is not
irreversible and not all-or-nothing.

## Three refusals the grant cannot override

These are enforced by triggers on `assertion_surface_permissions` and will
refuse a grant regardless of what the person agreed to:

- **YouTube-evidenced assertions** — `assertion_permissions_guard_youtube`
  refuses `can_select` on an outward surface unless the YouTube policy approves
  it. III.E.3.b, enforced at the permission layer as well as in
  `concept_has_non_video_witness`.
- **Calendar-evidenced assertions** — `assertion_permissions_guard_calendar`,
  same shape.
- **HealthKit-evidenced assertions** — `guard_healthkit_surface_permission`
  requires the fitness grant, whose four booleans are all false today.

**So the grant must tolerate partial success.** Some assertions will refuse to
open, and the RPC must not fail the whole transaction when they do — nor report
success as though everything opened. It should return how many were granted and
how many were refused, without saying which, since the reason is a fact about
another policy rather than about the person.

## Where to ask

**On Memories, not in onboarding.** Onboarding is too early — no assertions
exist yet, so the question would be abstract and the answer uninformed. Memories
is the one screen where somebody is already looking at the exact list that would
be exposed, which is the only place the question can be asked concretely:

> *These are your terms. May the people you match with see them?*

`FitnessPurposePrimer`'s shape: a `BiographicsSheet`, a title, three or four
lines, and — the part that makes it a consent screen rather than an
advertisement — **the refusals said out loud**. Its own comment: *"A consent
screen that only lists benefits is asking for agreement to something unstated."*

Proposed lines:

    ✓  Helps find people who share what you care about
    ✓  Only terms you can see on this page, never your sources
    ✗  Never your calendar, your activity, or anything from YouTube
    ✗  You can remove any single term, any time

The third line is true because of the three trigger refusals above, and is the
most reassuring thing that can honestly be said.

## Open decisions

1. **Does `matching` imply `bio`?** They share the `discovery_profile_reads`
   flag in `assert_surface_allowed`, and a term used for matching but absent
   from the bio is invisible to the person it matched. Asking twice is honest;
   asking once is kinder. Recommend: one grant covering both, named as such.
2. **What happens to somebody who declines?** They stay discoverable on card
   interests exactly as today. Nothing degrades — which must remain true, or the
   primer becomes a permission dialog wearing a friendlier hat.
3. **Re-asking.** `NotificationPrimer` offers "not now" and returns in three
   days. A decline here should probably be final until Settings, because the
   question is about disclosure rather than a system permission.

## What this does not decide

Whether the terms are any good. The assertion set has been read down the strong
end only, and `genre:asian_music` is a container in all but name. Exposing terms
to strangers raises the cost of a wrong one from *"my page looks odd"* to
*"somebody was told something untrue about me"*, so the review recorded in Known
gaps should finish first.
