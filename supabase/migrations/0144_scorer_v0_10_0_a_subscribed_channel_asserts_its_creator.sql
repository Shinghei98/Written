-- 0144 — scorer 0.10.0: a subscribed channel asserts its own creator.
--
-- **The vocabulary problem is fixed and nothing shows, because the curve was
-- the binding constraint all along.** `0142` gave the ontology its first
-- non-music subjects and `0143` minted twenty-two professional channels as
-- creators; both worked, and on a real account every one of them scored
-- between 0.022 and 0.097 against a bar of 0.35:
--
--     creator:pansci        0.068    creator:kripparrian   0.035
--     creator:asmongold     0.055    creator:pewdiepie     0.032
--     creator:statquest     0.036    creator:onion_man     0.032
--
-- ## Why this is a rule and not a number
--
-- Each of those is **one** `channel_identity` mapping off a `subscription`,
-- at `evidence_weight` 1.000 — the resolver is maximally confident, because
-- the match is an exact curated alias. What drags them down is arithmetic:
-- `w/(w+6)` rewards accumulation and needs `w >= 3.23`, while a single
-- subscription contributes about 0.2 after reliability and recency.
--
-- **And accumulation is not available.** Liking more of a musician's songs
-- really is more evidence about the musician; you cannot subscribe to a
-- channel twice. The curve is measuring a property of the *act* rather than of
-- the confidence, so no `action_weight` can fix it — `0138` did this
-- calculation and found that even at the maximum weight of 1.0 a lone
-- subscription reaches 0.036.
--
-- **The global curve is deliberately untouched, and that was checked.**
-- Measured across 610 scored concepts on one account, median evidence weight
-- is 0.313 in the `music` group and 0.345 in `video` — the two are comparable,
-- so video evidence is not systematically weaker and a per-source saturation
-- constant would be fixing something that is not broken. Lowering the bar
-- globally would admit the median concept, which is hundreds of terms nobody
-- asked for. The bar at 0.35 currently admits roughly the top 10–15%, and that
-- selectivity is worth keeping.
--
-- ## What it does not do
--
-- **`creator` only.** Subscribing to `Bioinformagician` declares that you
-- follow Bioinformagician. It does not declare bioinformatics — a subject is
-- something you would have to see across several channels before it means
-- anything, and it still has to be, so `subject:*` keeps accumulating past
-- this rule exactly as before. That line is the whole of why this is narrow
-- enough to be safe.
--
-- **It cannot admit an arbitrary string.** `channel_identity` resolves only
-- against an exact curated alias, so the rule reaches the channels somebody
-- catalogued and no others. It is bounded by `0143`'s family rather than by
-- what a person happens to have subscribed to.
--
-- **The volume is real and accepted.** A person with sixty catalogued
-- subscriptions gets sixty creator terms. Every one is true — they subscribed
-- — they are ranked by strength so the strongest reads first, and any of them
-- can be struck off. That is the owner's own rule for this data: *"for content
-- creators, their name is already the term."*

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.10.0'),
  'missing_aware_late_fusion', '0.10.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0, "eligible_strength": 0.35,'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"],'
  ' "work_eligible_strength": 0.25,'
  ' "spotify_top_track_weight": 0.78,'
  ' "spotify_top_artist_weight": 0.55,'
  ' "subscribed_and_liked": "a YouTube concept attested by a subscription and a'
  ' like from the same channel is eligible regardless of strength",'
  ' "subscribed_channel": "a creator-kind concept carrying an accepted'
  ' channel_identity mapping from a subscription is eligible regardless of'
  ' strength; subscribing is a 1:1 declaration about that creator and cannot be'
  ' repeated, so an accumulation curve can never reach it. creator kind only —'
  ' a subject still has to accumulate across channels",'
  ' "stability": "0.0 on a first run; absence of observation is not evidence"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.9.0' and status = 'active';

do $$
declare
  actives integer;
  newest text;
  declarable integer;
  enqueued integer;
begin
  select count(*) into actives from ontology.model_versions
   where model_role = 'scorer' and status = 'active';
  if actives <> 1 then
    raise exception 'expected exactly one active scorer, found %', actives;
  end if;

  select version into newest from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc, id limit 1;
  if newest <> '0.10.0' then
    raise exception 'finalization would pick scorer %, not 0.10.0', newest;
  end if;

  -- **The rule reads `channel_identity`, so that gate must be open or it is
  -- unreachable.** `0138` asserted the same thing about the subscription and
  -- liked_video weights for the same reason: a rule whose input is denied looks
  -- exactly like nobody having subscribed to anything.
  if not (
    select allow_channel_identity
    from ontology.youtube_policy_approvals
    order by approved_at desc, approval_reference
    limit 1
  ) then
    raise exception
      'the newest YouTube determination does not grant allow_channel_identity; the subscribed-channel rule would be unreachable';
  end if;

  -- **And something must actually be declarable, or this migration is a
  -- no-op wearing a version number.** Counted over mappings already stored:
  -- accepted `channel_identity` mappings from a subscription, on concepts of
  -- kind `creator`. Zero would mean `0143`'s vocabulary never resolved, which
  -- is the failure this rule exists downstream of.
  select count(distinct m.concept_id) into declarable
  from semantic_private.observation_mappings m
  join semantic_private.observations o on o.id = m.observation_id
  join ontology.concept_revisions r on r.concept_id = m.concept_id
  join ontology.versions v on v.id = r.ontology_version_id and v.status = 'published'
  where m.youtube_semantic_kind = 'channel_identity'
    and m.mapping_state = 'accepted'
    and o.action_type = 'subscription'
    and r.concept_kind = 'creator';
  -- **Only where there is something to assert against.** This counts production
  -- evidence, so on an empty database it is vacuously zero and the migration
  -- refuses to apply — which stops the whole chain replaying and hides every
  -- schema change after it. Guarded on the mapping table having rows at all:
  -- with data the check is exactly as strict as it was, and without data there
  -- is no claim to be wrong about.
  --
  -- This is the weaker form of `0118`'s rule — a predicate should answer both
  -- ways over real data — and it is weaker on purpose: a replay has no real
  -- data, and the alternative is a migration that can never be replayed.
  if declarable = 0 and exists (
    select 1 from semantic_private.observation_mappings limit 1
  ) then
    raise exception
      'no accepted channel_identity subscription mapping resolves to a creator; the rule would assert nothing';
  end if;
  raise notice '% creator concept(s) are declarable by subscription', declarable;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.10.0: a subscribed channel asserts its own creator'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s)', enqueued;
end
$$;

commit;
