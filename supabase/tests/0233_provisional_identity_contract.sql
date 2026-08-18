-- 0233 — a provisional has one live identity, and a strike survives becoming a concept.
--
-- Both properties are latent in production, where `provisional_entities` is
-- empty. This file is what says they hold before a sink fills it.
--
-- Everything runs against seeded rows and rolls back.

begin;

do $$
declare
  alice    uuid := '00000000-0000-4000-8000-00000000a11c';
  version  uuid;
  concept  uuid;
  prov     uuid;
  prov_b   uuid;
  cand     uuid;
  item     uuid;
  n        integer;
  raised   boolean;
begin
  insert into auth.users (id, email) values (alice, 'alice@example.invalid')
  on conflict (id) do nothing;

  select id into version from ontology.versions where status = 'published';
  select cr.concept_id into concept
    from ontology.concept_revisions cr
   where cr.ontology_version_id = version and cr.status = 'active'
   order by cr.concept_id::text limit 1;
  if concept is null then
    raise exception '0233 contract: no active concept in the published version';
  end if;

  -- ---------------------------------------------------------------------
  -- 1. One live identity per (user, label, family)
  -- ---------------------------------------------------------------------
  insert into semantic_private.provisional_entities
    (scope, user_id, canonical_label, normalized_label, family)
  values ('user', alice, 'Contract Probe', 'contract probe', 'work')
  returning id into prov;

  raised := false;
  begin
    insert into semantic_private.provisional_entities
      (scope, user_id, canonical_label, normalized_label, family)
    values ('user', alice, 'CONTRACT PROBE', 'contract probe', 'work');
  exception when unique_violation then
    raised := true;
  end;
  if not raised then
    raise exception
      '0233 contract: a second live identity for the same label and family was accepted';
  end if;

  -- A different family is a different noun and is not a collision.
  insert into semantic_private.provisional_entities
    (scope, user_id, canonical_label, normalized_label, family)
  values ('user', alice, 'Contract Probe', 'contract probe', 'album')
  returning id into prov_b;

  -- ---------------------------------------------------------------------
  -- 2. Quarantine and redirect are history, and do not block a re-mint
  -- ---------------------------------------------------------------------
  -- An erasure must not make a label permanently unmintable. That would be the
  -- one direction the person did not ask for.
  update semantic_private.provisional_entities
     set identity_state = 'quarantined' where id = prov_b;
  insert into semantic_private.provisional_entities
    (scope, user_id, canonical_label, normalized_label, family)
  values ('user', alice, 'Contract Probe', 'contract probe', 'album');

  -- ---------------------------------------------------------------------
  -- 3. A redirect carries the strike into the record Memories honours
  -- ---------------------------------------------------------------------
  insert into semantic_private.user_term_candidates
    (user_id, provisional_entity_id, user_facing_predicate, confidence_tier,
     aggregate_score, primary_route_id, lifecycle_state)
  values (alice, prov, 'affinity_to', 'secondary', 0.5, 'contract_probe', 'active')
  returning id into cand;

  insert into semantic_private.review_items
    (user_id, candidate_id, review_epoch, primary_route_id, confidence_tier,
     aggregate_score, rank, presentation_version)
  values (alice, cand, 900, 'contract_probe', 'secondary', 0.5, 0, 'calibration_v1')
  returning id into item;

  insert into semantic_private.review_exposures
    (user_id, review_item_id, position, presentation_variant)
  values (alice, item, 0, 'calibration_v1');

  insert into semantic_private.review_events
    (user_id, review_item_id, action, reason)
  values (alice, item, 'strike_off', 'ambiguous_rejection');

  insert into semantic_private.user_term_suppressions
    (user_id, concept_id, provisional_entity_id, user_facing_predicate,
     active, source_review_item_id, source_review_epoch)
  values (alice, null, prov, 'affinity_to', true, item, 900);

  -- Before the merge there is no Memories record, because there was no concept
  -- to name in one.
  select count(*) into n from semantic_private.user_suppressions
   where user_id = alice and concept_id = concept and surface = 'memories' and active;
  if n <> 0 then
    raise exception '0233 contract: a Memories suppression existed before the merge';
  end if;

  update semantic_private.provisional_entities
     set redirect_concept_id = concept where id = prov;

  select count(*) into n from semantic_private.user_term_suppressions
   where user_id = alice and concept_id = concept and active;
  if n <> 1 then
    raise exception '0233 contract: the merge wrote % overlay suppressions', n;
  end if;

  select count(*) into n from semantic_private.user_suppressions
   where user_id = alice and concept_id = concept and surface = 'memories' and active;
  if n <> 1 then
    raise exception
      '0233 contract: the merge wrote % Memories suppressions, so a struck term can be drawn as a claim', n;
  end if;

  -- And it names the strike that caused it, which is what `0231` established
  -- the column is for.
  select count(*) into n
    from semantic_private.user_suppressions s
    join semantic_private.review_events e on e.id = s.source_feedback_event_id
   where s.user_id = alice and s.concept_id = concept and s.surface = 'memories'
     and e.action = 'strike_off';
  if n <> 1 then
    raise exception '0233 contract: the Memories suppression names no strike event';
  end if;

  -- ---------------------------------------------------------------------
  -- 4. A suppression it cannot attribute stops the merge
  -- ---------------------------------------------------------------------
  -- Carrying it silently hides a claim nobody can later read a reason for;
  -- dropping it silently shows one. Refusing costs a merge.
  insert into semantic_private.provisional_entities
    (scope, user_id, canonical_label, normalized_label, family)
  values ('user', alice, 'Unattributed', 'unattributed', 'work')
  returning id into prov_b;

  insert into semantic_private.user_term_suppressions
    (user_id, concept_id, provisional_entity_id, user_facing_predicate,
     active, source_review_item_id, source_review_epoch)
  values (alice, null, prov_b, 'affinity_to', true, null, 900);

  raised := false;
  begin
    update semantic_private.provisional_entities
       set redirect_concept_id = concept where id = prov_b;
  exception when others then
    raised := true;
  end;
  if not raised then
    raise exception
      '0233 contract: a merge carrying an unattributable strike was allowed';
  end if;

  raise notice '0233 contract: provisional identity and merge-time suppression hold';
end;
$$;

rollback;
