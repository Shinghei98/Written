-- 0117 — YouTube may raise a concept's strength and may never be the only
-- reason it is shown to somebody else.
--
-- **The rule the client already follows, made checkable before the surface that
-- needs it exists.** `DistillViewModel.publishDiscoveryCard` excludes YouTube
-- outright and says why: III.E.3.b, an API Client *"must not display or allow
-- access to Authorized Data to anyone other than the authorizing user"*, and
-- `discovery_cards` is the one table every signed-in user may read. That holds
-- for the legacy card because it publishes *strings* — a channel name lifted
-- out of a subscription list is Authorized Data whatever column it lands in.
--
-- Phase 4's discovery is different in kind: it matches on **concepts**, which
-- are our vocabulary rather than YouTube's. That reopens the question the
-- client answered by exclusion, and the answer must not be "concepts are ours,
-- so anything goes" — a concept only YouTube witnesses still discloses YouTube
-- data, because the only way it could be true of somebody is through the
-- subscription list it came from.
--
-- **Two tests, and the second is what makes the first true.**
--
--   * *Recoverability*, which is the client's own formulation: can a reader
--     recover the channel from what was published? `DistillViewModel:1462` —
--     *"Long-form science" cannot; "Kurzgesagt-style space animation" can, and
--     is still Authorized Data wearing a different hat.*
--   * *Non-sole-provenance*, which is this migration. If a non-YouTube source
--     independently attests the concept, publishing it discloses nothing that
--     YouTube supplied: **the identical row would be published with YouTube
--     disconnected.** That is a stronger guarantee than judging a string's
--     recoverability by eye, and it is mechanical.
--
-- So YouTube keeps doing the work it is uniquely able to do. It is the only
-- second independence group — `apple_music`, `music_library` and `spotify` all
-- carry `music` by design (`0044`), so `motif_rules`' check constraint
-- `minimum_independence_groups >= 2` is unsatisfiable without it. `0078`
-- measured `creator:le_sserafim` across nine separate repost channels. Under
-- this rule that evidence still raises strength and still supplies the second
-- group; it simply cannot be the sole reason the concept crosses.
--
-- **No gate is opened.** `allow_bio`, `allow_icebreaker` and
-- `allow_cross_source_fusion` stay false in `ontology.youtube_policy_approvals`
-- and are not consulted here, because nothing YouTube supplied is displayed to
-- anyone: what crosses is a concept with a non-YouTube witness. This is a
-- narrowing of what a future surface may return, not a permission.
--
-- Ships no behaviour: nothing calls it yet, by design. It exists so Phase 4
-- reads from something that already enforces the rule rather than remembering
-- to.

begin;

-- Takes a run rather than a user, deliberately. Which run is *current* is
-- already decided in one place — `api.list_assertions` requires
-- `score_run.input_revision = coalesce(user_state.revision, 0)` — and a second
-- copy of that rule here would be a second thing to keep in step, which is this
-- codebase's standing defect. The caller knows its run; this answers about it.
create or replace function semantic_private.concept_has_non_video_witness(
  p_semantic_run_id uuid,
  p_concept_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from semantic_private.concept_source_scores css
     where css.semantic_run_id = p_semantic_run_id
       and css.concept_id = p_concept_id
       -- `video` is YouTube's group in `semantic_private.sources` (`0044`).
       -- Named rather than joined so that adding a second video source puts it
       -- under this rule automatically, which is the behaviour wanted: the
       -- restriction is about the channel of evidence, not about Google.
       and css.independence_group <> 'video'
       -- A row with no evidence behind it is not a witness. `recommendation`
       -- and `playlist` carry `action_weight` 0.0, so a concept can hold a
       -- score row that attests nothing.
       and css.evidence_count > 0
       and css.strength > 0
  );
$$;

comment on function semantic_private.concept_has_non_video_witness(uuid, uuid) is
  'III.E.3.b: a concept may cross to another user only when a non-YouTube '
  'source attests it, so the same row would be published with YouTube '
  'disconnected. YouTube still contributes strength and the second '
  'independence group. Called by Phase 4 surfaces; nothing calls it yet.';

revoke all on function semantic_private.concept_has_non_video_witness(uuid, uuid)
  from public;

-- **Proven by behaviour, not by reading the body.** This file has twice shipped
-- a check that passed while measuring nothing — `0095` counted 35 unreachable
-- concepts, `0102` asserted a guard merely *mentions* the flag function — so
-- the assertion below constructs both cases and compares the answers.
do $$
declare
  fake_run  constant uuid := '00000000-0000-0000-0000-0000000000aa';
  concept_a constant uuid := '00000000-0000-0000-0000-0000000000a1';
  answer boolean;
begin
  -- A run and concept that do not exist attest nothing, which is the
  -- fail-closed direction and the one that matters if a caller passes a stale
  -- id.
  select semantic_private.concept_has_non_video_witness(fake_run, concept_a)
    into answer;
  if answer is not false then
    raise exception 'unknown run must not be treated as witnessed (got %)', answer;
  end if;

  -- And the function must actually read the group column rather than answering
  -- false unconditionally, which is what a vacuous guard would do. Asserted
  -- against real data where any exists: every concept that has *only* video
  -- rows must answer false, and every concept with a non-video row must answer
  -- true.
  if exists (select 1 from semantic_private.concept_source_scores) then
    if exists (
      select 1
        from semantic_private.concept_source_scores css
       group by css.semantic_run_id, css.concept_id
      having bool_or(css.independence_group <> 'video'
                     and css.evidence_count > 0 and css.strength > 0)
         is distinct from semantic_private.concept_has_non_video_witness(
              css.semantic_run_id, css.concept_id)
    ) then
      raise exception 'predicate disagrees with the rows it is derived from';
    end if;
  else
    raise notice 'no concept_source_scores rows yet; existence check only';
  end if;
end
$$;

commit;
