-- 0330 — a `wrong_parent` strike reaches `classification_parent`.
--
-- **`0330` widened a check constraint; this is the proof that the widening was
-- about a defect rather than about a constraint.** The migration can show that
-- the installed expression admits the value and still refuses an unknown one.
-- What it cannot show, without seeding a user into somebody's database to test
-- itself, is the thing that was actually broken: a tap carrying `wrong_parent`
-- travelling the whole way from `api.strike_calibration_item` through the
-- constraint into `emit_calibration_labels` and arriving as supervision for the
-- `classification_parent` domain.
--
-- **Its own file rather than an addition to `0230`.** That contract's seed
-- exposes exactly two review items and pins an assertion to the number; a third
-- item for this case would have meant editing a count eight other properties
-- are measured against. A separate fixture fails alone.
--
-- **This is the third time one value has been missing from this constraint.**
-- `0230`'s own comment records the first two — `'user_keep'` and
-- `'user_correction'`, both of which the fourteen-word check had never admitted
-- and both fatal on the first call. The shape recurs because the writer and the
-- constraint live in different migrations and nothing compares them, so the
-- last assertion here is the one that would have caught all three: **every
-- reason `api.strike_calibration_item` can send must be one the column can
-- store.**
--
-- Everything runs against seeded rows and rolls back.

begin;

update semantic_private.feature_flags set enabled = true
 where flag_key = 'calibration_reads';

do $$
declare
  carol   uuid := '00000000-0000-4000-8000-00000000ca01';
  version uuid;
  concept uuid;
  cand    uuid;
  item    uuid;
  stored  text;
  n       integer;
  sendable text[];
  storable text[];
  orphan   text;
begin
  insert into auth.users (id, email) values (carol, 'carol@example.invalid')
  on conflict (id) do nothing;

  select id into version from ontology.versions where status = 'published';
  if version is null then
    raise notice '0330 contract: no published ontology version; nothing to test';
    return;
  end if;

  -- **Not `work`-kinded**, for `0230`'s reason: `0283` stopped offering song-
  -- and album-level terms for review, so a `work` fixture is never exposed and
  -- every assertion below it would measure a page that is not there.
  select cr.concept_id into concept
    from ontology.concept_revisions cr
   where cr.ontology_version_id = version and cr.status = 'active'
     and cr.concept_kind <> 'work'
   order by cr.concept_id::text
   limit 1;

  if concept is null then
    raise exception
      '0330 contract: the published version holds no active non-work concept';
  end if;

  insert into semantic_private.user_term_candidates
    (user_id, concept_id, user_facing_predicate, confidence_tier,
     aggregate_score, primary_route_id, lifecycle_state)
  values (carol, concept, 'affinity_to', 'direct', 0.9, 'contract_probe', 'active')
  returning id into cand;

  insert into semantic_private.review_items
    (user_id, candidate_id, review_epoch, primary_route_id, confidence_tier,
     aggregate_score, rank, presentation_version)
  values (carol, cand, 900, 'contract_probe', 'direct', 0.9, 0, 'calibration_v1')
  returning id into item;

  -- Both forms, because the replay image's `auth.uid()` reads the singular
  -- setting and production's reads the JSON one. Setting one makes this file
  -- fail with "not signed in", which reads exactly like a permission bug.
  perform set_config('request.jwt.claim.sub', carol::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', carol)::text, true);

  -- The strike consults `review_exposures`, so the item has to have been handed
  -- out before it can be answered.
  perform api.begin_calibration(8);

  -- ---------------------------------------------------------------------
  -- 1. The strike completes at all
  -- ---------------------------------------------------------------------
  -- Before `0330` this raised `23514`, and because the strike is one function
  -- body the review event, the suppression and the demotion rolled back with
  -- it. The failure was total, not partial.
  perform api.strike_calibration_item(item, 'wrong_parent');
  -- `user_suppressions`' lineage foreign keys are `deferrable initially
  -- deferred` and this file ends in `rollback`, so without this line they are
  -- never checked here at all. `0230` shipped broken twice underneath a passing
  -- test for exactly this reason.
  set constraints all immediate;

  -- ---------------------------------------------------------------------
  -- 2. The reason is stored as given, not folded to the default
  -- ---------------------------------------------------------------------
  -- `0294`'s allowlist falls back to `ambiguous_rejection` for anything it does
  -- not recognise, so a strike that "succeeded" while quietly recording the
  -- default would look identical from every other angle — and would price the
  -- person's affinity at −2.50 for what was a classification mistake.
  select reason into stored from semantic_private.review_events
   where review_item_id = item and action = 'strike_off';
  if stored is distinct from 'wrong_parent' then
    raise exception
      '0330 contract: the strike stored reason % rather than wrong_parent', stored;
  end if;

  -- ---------------------------------------------------------------------
  -- 3. Both of 0292's prices fire, into the domains they name
  -- ---------------------------------------------------------------------
  select count(*) into n from semantic_private.calibration_labels
   where user_id = carol and target_domain = 'classification_parent'
     and delta_log_odds = -2.00;
  if n <> 1 then
    raise exception
      '0330 contract: % labels reached classification_parent at -2.00', n;
  end if;

  select count(*) into n from semantic_private.calibration_labels
   where user_id = carol and target_domain = 'classification_root'
     and delta_log_odds = -0.10;
  if n <> 1 then
    raise exception
      '0330 contract: % labels reached classification_root at -0.10', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 4. A parent error is not read as a taste signal
  -- ---------------------------------------------------------------------
  -- The whole reason `classification_parent` exists as a separate domain. If
  -- `wrong_parent` had been left to fall back, this count would be 1 and the
  -- supervision would have landed on what the person likes.
  select count(*) into n from semantic_private.calibration_labels
   where user_id = carol and target_domain = 'user_affinity';
  if n <> 0 then
    raise exception
      '0330 contract: a wrong_parent strike wrote % user_affinity labels', n;
  end if;

  -- ---------------------------------------------------------------------
  -- 5. Every reason the RPC can send is one the column can store
  -- ---------------------------------------------------------------------
  -- **The assertion that would have caught all three instances.** The writer
  -- and the constraint are in different migrations and nothing compared them,
  -- which is how `user_keep`, `user_correction` and `wrong_parent` each shipped
  -- able to be sent and unable to be stored. Read both out of the catalog and
  -- name any reason that is in the first and not the second.
  -- **`clause`, not `full`** — the latter is a reserved word and the lateral
  -- fails to parse with it. Verified against production 2026-08-24: this pulls
  -- the nine reasons `0294` allows, and the extraction below pulls the
  -- constraint's list, and the difference was `wrong_parent` alone.
  select array_agg(distinct m[1] order by m[1]) into sendable
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace,
    lateral regexp_matches(pg_get_functiondef(p.oid),
                           'p_reason in \(([^)]*)\)', 'g') as clause,
    lateral regexp_matches(clause[1], '''([a-z_]+)''', 'g') as m
   where ns.nspname = 'api' and p.proname = 'strike_calibration_item';

  -- A silent empty answer here would make the whole property pass by comparing
  -- nothing, which is the failure mode this file exists to argue against.
  if sendable is null or array_length(sendable, 1) is null then
    raise exception
      '0330 contract: could not read the strike RPC''s reason allowlist';
  end if;

  -- **`::text` comes off before the quotes, not after.** `pg_get_constraintdef`
  -- renders each element as `'correct'::text`; stripping quotes first leaves
  -- `correct'` and every reason then reads as an orphan — which looks exactly
  -- like the defect being tested for and is nothing of the sort.
  select array_agg(trim(both '''' from replace(trim(v), '::text', ''))) into storable
    from unnest(string_to_array(
      (regexp_match(
        (select pg_get_constraintdef(c.oid) from pg_constraint c
          where c.conrelid = 'semantic_private.review_events'::regclass
            and c.conname = 'review_events_reason_check'),
        'ARRAY\[(.*)\]'))[1], ',')) as v
   where v is not null;

  select r into orphan from unnest(sendable) as r
   where r not in (select unnest(storable)) limit 1;

  if orphan is not null then
    raise exception
      '0330 contract: api.strike_calibration_item can send %, which review_events.reason cannot store',
      orphan;
  end if;

  raise notice
    '0330 contract: wrong_parent reaches classification_parent; % sendable reasons all storable',
    array_length(sendable, 1);
end;
$$;

rollback;
