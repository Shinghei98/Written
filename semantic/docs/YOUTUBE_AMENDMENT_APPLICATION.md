# The §3 amendment application — Content Categorization and Tagging

**Status: prepared, not submitted.** Nothing here has been sent to Google.

This is the package for applying to
`developers.google.com/youtube/terms/derived-metrics-policy`, category **3,
Content Categorization and Tagging**. It is filed as a document rather than a
task because the prerequisites have known failure modes that cost weeks when
they bite, and because two things must be *verified false* before it is safe to
submit at all.

---

## 1. What is being applied for, and what it buys

The clause, verbatim:

> You may use analysis to assign descriptive sub-genres or tags to videos and
> channels. These must be additive and distinct from YouTube's video categories.

With the worked example:

> Augmenting API Data with descriptive sub-tags (e.g. labeling a video in the
> 'Gaming' category with specific tags such as 'Speedrun' or 'Minecraft').

**In this codebase that is exactly one boolean:**
`ontology.youtube_policy_approvals.allow_title_tags`, and the mapping kind it
gates is `written_title_tag`. `tools/youtube_topics.py` is written around the
distinction already — `provider_topic` needs no approval because it reads a
label YouTube supplied, `written_title_tag` is the guessing kind and stays shut.

**The concrete gain, measured.** `tools/youtube_topics.py` found 639 real rows
collapsing onto **28 distinct topics, five of which carry 80%** — YouTube labels
nearly everything and labels it very coarsely. Accepted, we could place the
channels YouTube leaves unplaced and refine the coarse ones, which is the
restraint `domainForCreatorTag` currently exercises by matching whole tags
against a small controlled vocabulary because inferring from free text would be
a guess. Licensed, that guess becomes permitted.

## 2. Two things that must be false before submitting

Both are **blocking**, and the first is the trap CLAUDE.md records.

- **`allow_title_tags` must still be `false` in production.** Applying while
  running the unlicensed version of the thing applied for is the worst possible
  posture. Verify, do not assume:

      select allow_title_tags, approval_basis, approval_state
        from ontology.youtube_policy_approvals where revoked_at is null;

  Every row must read `false`. `0078`'s row is `internal_determination` with
  only `allow_uploader_tags` true, which is correct and unaffected.

- **No `written_title_tag` mappings may exist.** The gate is read off the *run's*
  policy row, so a historical run could in principle carry them:

      select count(*) from semantic_private.observation_mappings
       where mapping_kind = 'written_title_tag';

  Expected: 0.

## 3. Prerequisites, each with the failure mode that makes it worth listing

| prerequisite | failure mode |
|---|---|
| **Search Console verified as a `Domain` property** for `written-stl.com`, signed in as an **Owner of Cloud project `672788849005`** | Verifying as the wrong Google account is the standard rejection, and Google does not tell you that is the reason. A URL-prefix property is not a Domain property. |
| Consent screen at `console.cloud.google.com/auth/branding` carries `https://written-stl.com/en-us/` and `https://written-stl.com/en-us/privacy/` **character for character** | Must match `Written/Views/SignInView.swift` exactly. Not `/privacy`, which 301s — **a redirect is not agreement**. |
| Scope justification for `youtube.readonly` | Sensitive, not restricted, so no CASA assessment. The justification is the same form as the amendment request. |
| Demo video | Shoot it against the pipeline that will actually run. CLAUDE.md's standing reason for deferring was that shooting it against a pipeline about to be replaced wastes the work. |
| `web/en-us/privacy/` describes what will be true | It currently describes the conservative reading. **It moves in the same commit as any enablement**, not afterwards — it is a compliance statement, not a description. |

Portal-side setup steps are in `README.md`; this document does not duplicate
them.

## 4. The eligibility argument, stated honestly

The gate is one sentence: ***"Your API Service must reflect an analytics use
case on YouTube."***

**"Analytics use case" is nowhere defined in the document.** CLAUDE.md used to
conclude flatly that a dating platform "is neither", which was an interpretation
written in the voice of a quote; that has been corrected. The argument to make,
and its honest weakness:

- **For.** Memories is an analytics surface over the user's own YouTube
  activity: it groups their channels under **YouTube's own topic labels**, on
  their own page, and shows nobody else. `api.list_assertions` is
  `security definer` scoped to `auth.uid()` with no parameter for whose. The
  product does the thing the permission exists to support — deriving descriptive
  structure over a corpus — and does it for the person who authorised it.
- **Against.** The API Service as a whole is a dating platform, and a reviewer
  may read "analytics use case" as meaning the service's *purpose*, not one of
  its surfaces. There is no clause resolving this.

**Do not oversell it.** The application should describe Memories and the
ontology stage plainly and let the reviewer decide.

## 5. What acceptance does *not* grant — state this internally, not to Google

Getting this wrong in either direction is expensive, so it is recorded here.

- **Not a viewer-level permission.** Asked directly whether the policy permits
  deriving attributes about a viewer from viewing history, the answer is
  **absent**. All six categories concern channels and videos; the only sentence
  naming users is the protected-attributes restriction. Acceptance licenses
  labelling *content*, not concluding things about *people*.
- **Not III.E.3.b relief.** The amendment amends III.E.4.b/c/d. Showing one
  user's YouTube-derived data to another stays prohibited whatever is accepted,
  which is why `0117` exists and why it opens no gate.
- **Not storage relief for names.** Accepted clients keep *statistics* and
  *derived metrics* for 36 months, but *"other data (such as video titles,
  creator names, descriptions, and comment text) must still follow the 30-day
  refresh and deletion policy"*. `0016`'s sweep survives acceptance untouched.
- **Not `allow_cross_source_fusion`, `allow_bio`, `allow_icebreaker` or
  `allow_explanation`.** Those are separate determinations and the schema's
  `surface_scope_check` already refuses bio or icebreaker without fusion.

## 6. If accepted

1. Insert a new `ontology.youtube_policy_approvals` row with
   `approval_basis = 'google_amendment'` and the reference Google returns —
   **never** edit `0078`'s `internal_determination` row. `0078` added
   `approval_basis` precisely so a later reader cannot mistake our own reading
   for Google's acceptance.
2. Activate a `youtube_resolver` model version that exercises
   `written_title_tag`, with its false-positive guards in `parameters` where a
   later reader looks — the shape `0078` used for `min_tag_length`.
3. End the migration with
   `semantic_private.enqueue_recompute_on_analysis_change`, or the new model
   changes what the system *would* compute and nothing it has.
4. Move `web/en-us/privacy/` in the same commit.

## 7. If refused

Nothing breaks. `allow_uploader_tags` is licensed by our own determination
(`0078`) and is unaffected by a refusal, and it is the permission with the
measured payoff — `creator:le_sserafim` across nine repost channels, the second
independence group no music source can supply. The vocabulary work that makes
that permission productive is independent of this application entirely.
