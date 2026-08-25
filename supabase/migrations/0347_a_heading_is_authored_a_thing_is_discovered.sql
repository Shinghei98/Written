-- 0347 — the mint gate learns the difference between a thing and a heading.
--
-- **The owner's rule, 2026-08-25, completing the person-method translation:**
-- categories are selected, never invented. `0346` supplies the recognised
-- heading inventory from one curated CC0 source; this migration closes the
-- other half — `mint_proposed_parents` no longer mints a proposal whose
-- family makes it a *category*, because a model-imagined category boundary
-- is the root defect no gate downstream can repair. Measured on the v19
-- proposal pass: "Chinese pop music", "C-pop"-class near-synonyms, "Songs",
-- "Music albums", "Chinese actors" — ~half of the 39 that crossed the
-- N=3 grounded floor were category-soup wearing the least-bad wrong family.
--
-- **What keeps minting: families whose referent the world fixes.**
--
--   franchise   One Piece, Promare — a branded universe is a thing
--   culture     the owner's founding case: unseen countries mint here
--   place       a named location is a thing
--   event       a dated public occurrence is a thing
--
-- **What stops: everything a proposal can only reach by drawing a boundary.**
-- person/group/organization as *parents* are occupation-soup by construction
-- (a party parents nothing; parties arrive through relations); art and field
-- belong to the authored `movement:`/`subject:` inventories; work-shaped
-- families (work, anime, book, game, music_work, album) as parents duplicate
-- what `soundtrack_of`/`part_of_franchise` relations already carry; activity
-- and sport are `0198`'s imported inventories. Held proposals are **not
-- refused** — they stay `pending` as the authoring queue, the same loop that
-- produced the twelve person kinds: the model prepares evidence, the human
-- mints vocabulary.

create or replace function semantic_private.proposal_family_may_mint(p_family text)
returns boolean
language sql
immutable
as $$
  -- **Immutable and a literal list, for `0133`'s reason**: a helper reading a
  -- table could not be immutable, and a table would let a row quietly change
  -- what is enforced. The wire families absent from this list are not
  -- unhandled — they are the authoring queue, and `mint_proposed_parents`
  -- counts them out loud on every run.
  select p_family in ('franchise', 'culture', 'place', 'event');
$$;

comment on function semantic_private.proposal_family_may_mint(text) is
  'Whether a proposed parent''s family names a world-fixed thing (mintable) '
  'or a category boundary (authored-only; the proposal is held as the '
  'authoring queue). Owner''s rule 2026-08-25: categories are selected, '
  'never invented.';

-- The gate itself: one added disposition, everything else untouched.
create or replace function semantic_private.mint_proposed_parents(
  p_floor integer default 3)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  current_version text;
  next_version    text;
  new_version_id  uuid;
  to_mint integer := 0;
  linked  integer := 0;
  held    integer := 0;
  queued  integer := 0;
begin
  if p_floor < 1 then
    raise exception 'mint_proposed_parents: the floor must be at least 1';
  end if;

  select version into current_version
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception 'mint_proposed_parents: no published ontology version';
  end if;

  drop table if exists proposal_plan;
  create temporary table proposal_plan on commit drop as
  with tallied as (
    select p.normalized_label, p.family,
           count(distinct p.proposed_by_term)
             filter (where p.grounded) as grounded_terms,
           count(distinct p.proposed_by_term) as all_terms,
           (select p2.hub_key from semantic_private.parent_proposals p2
             where p2.normalized_label = p.normalized_label
               and p2.family = p.family and p2.status = 'pending'
             group by p2.hub_key
             order by count(*) desc, p2.hub_key limit 1) as hub_key,
           (select p3.proposal_label from semantic_private.parent_proposals p3
             where p3.normalized_label = p.normalized_label
               and p3.family = p.family and p3.status = 'pending'
             group by p3.proposal_label
             order by count(*) desc, p3.proposal_label limit 1) as label
      from semantic_private.parent_proposals p
     where p.status = 'pending'
     group by p.normalized_label, p.family
  ), shaped as (
    select t.*,
           fc.concept_kind,
           (select c.id from ontology.concepts c
             where c.concept_key = t.hub_key and c.retired_at is null) as hub_id
      from tallied t
      join ontology.family_mint_convention fc on fc.family = t.family
  ), disposed as (
    select s.*,
           case
             -- **The owner's line between discovered and authored.** A
             -- category-family proposal never mints, whatever its support —
             -- it queues for the human, pending so evidence keeps accruing.
             when not semantic_private.proposal_family_may_mint(s.family)
               then 'queue_for_authoring'
             when s.grounded_terms < p_floor then 'hold'
             when s.hub_id is null then 'refused:unknown_hub'
             when same_kind.concepts > 1 then 'refused:ambiguous_vocabulary'
             when same_kind.concept_id is not null then 'link'
             when other_kind.held then 'refused:label_collision_other_kind'
             else 'mint'
           end as disposition,
           same_kind.concept_id as link_concept_id
      from shaped s
      left join lateral (
        select min(l.concept_id::text)::uuid as concept_id,
               count(distinct l.concept_id) as concepts
          from ontology.concept_labels l
          join ontology.versions cv
            on cv.id = l.ontology_version_id and cv.version = current_version
          join ontology.concept_revisions cr
            on cr.ontology_version_id = cv.id and cr.concept_id = l.concept_id
         where l.status = 'active' and cr.status = 'active'
           and l.normalized_label = s.normalized_label
           and cr.concept_kind = s.concept_kind
      ) same_kind on true
      left join lateral (
        select exists (
          select 1 from ontology.concept_labels l
            join ontology.versions cv
              on cv.id = l.ontology_version_id and cv.version = current_version
            join ontology.concept_revisions cr
              on cr.ontology_version_id = cv.id and cr.concept_id = l.concept_id
           where l.status = 'active' and cr.status = 'active'
             and l.normalized_label = s.normalized_label
             and cr.concept_kind <> s.concept_kind
        ) as held
      ) other_kind on true
  )
  select * from disposed;

  select count(*) filter (where disposition = 'mint'),
         count(*) filter (where disposition = 'link'),
         count(*) filter (where disposition = 'hold'),
         count(*) filter (where disposition = 'queue_for_authoring')
    into to_mint, linked, held, queued
    from proposal_plan;

  if to_mint > 0 then
    next_version := split_part(current_version, '.', 1) || '.'
                 || split_part(current_version, '.', 2) || '.'
                 || (split_part(current_version, '.', 3)::integer + 1)::text;

    insert into ontology.versions (id, version, parent_version_id, status, description)
    select gen_random_uuid(), next_version, v.id, 'draft',
           'Corroborated parent mint: ' || to_mint::text
           || ' heading(s) proposed by >= ' || p_floor::text
           || ' grounded terms each.'
      from ontology.versions v where v.version = current_version
    on conflict (version) do nothing;

    select id into new_version_id from ontology.versions where version = next_version;
    if new_version_id is null then
      raise exception 'mint_proposed_parents: could not open draft %', next_version;
    end if;

    perform ontology.copy_forward_version(
      (select id from ontology.versions where version = current_version),
      new_version_id);

    insert into ontology.concepts (id, concept_key)
    select gen_random_uuid(),
           ontology.mint_concept_key(k.family, k.concept_kind,
                                     k.normalized_label, k.label)
      from proposal_plan k where k.disposition = 'mint'
    on conflict (concept_key) do nothing;

    insert into ontology.concept_revisions (
      ontology_version_id, concept_id, preferred_label, concept_kind,
      definition, sensitivity, inference_policy, status, metadata)
    select distinct on (c.id)
           new_version_id, c.id, k.label, k.concept_kind,
           null, 'ordinary', 'inferable', 'active',
           jsonb_build_object('origin', 'corroborated_parent_proposal',
                              'mention_family', k.family,
                              'grounded_terms', k.grounded_terms)
      from proposal_plan k
      join ontology.concepts c
        on c.concept_key = ontology.mint_concept_key(k.family, k.concept_kind,
                                                     k.normalized_label, k.label)
     where k.disposition = 'mint'
    on conflict do nothing;

    insert into ontology.concept_labels (
      ontology_version_id, concept_id, label, normalized_label, locale,
      label_type, provenance_type, confidence, status, external_ref)
    select distinct on (c.id, kind.label_type)
           new_version_id, c.id, k.label, k.normalized_label, 'und',
           kind.label_type, 'curated', 1.0, 'active',
           jsonb_build_object('origin', 'corroborated_parent_proposal')
      from proposal_plan k
      join ontology.concepts c
        on c.concept_key = ontology.mint_concept_key(k.family, k.concept_kind,
                                                     k.normalized_label, k.label)
     cross join (values ('preferred'), ('alternate')) as kind(label_type)
     where k.disposition = 'mint'
    on conflict do nothing;

    insert into ontology.concept_edges (
      ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
      confidence, provenance_type, provenance, status)
    select distinct on (c.id)
           new_version_id, c.id, 'broader', k.hub_id,
           1.0, 'provider',
           jsonb_build_object('source', '0341_parent_proposals',
                              'grounded_terms', k.grounded_terms),
           'active'
      from proposal_plan k
      join ontology.concepts c
        on c.concept_key = ontology.mint_concept_key(k.family, k.concept_kind,
                                                     k.normalized_label, k.label)
     where k.disposition = 'mint'
       and k.hub_id is not null
    on conflict do nothing;

    perform ontology.publish_version(new_version_id);
  end if;

  -- 'hold' and 'queue_for_authoring' both stay pending: one is a threshold
  -- evidence can cross, the other is a queue a person drains.
  update semantic_private.parent_proposals p
     set status = case when k.disposition like 'refused%' then 'refused'
                       else 'completed' end,
         completed_at = now(),
         outcome = jsonb_build_object(
           'disposition', k.disposition,
           'concept_id', coalesce(
             k.link_concept_id,
             (select c.id from ontology.concepts c
               where c.concept_key = ontology.mint_concept_key(
                       k.family, k.concept_kind, k.normalized_label, k.label))),
           'ontology_version', coalesce(next_version, current_version))
    from proposal_plan k
   where p.normalized_label = k.normalized_label
     and p.family = k.family
     and p.status = 'pending'
     and k.disposition not in ('hold', 'queue_for_authoring');

  return jsonb_build_object(
    'minted', to_mint, 'linked', linked, 'held_below_floor', held,
    'queued_for_authoring', queued,
    'floor', p_floor,
    'version', coalesce(next_version, current_version));
end;
$$;

revoke all on function semantic_private.mint_proposed_parents(integer)
  from public;

-- ---------------------------------------------------------------------------
-- Proven both ways: a thing mints, a category queues, at identical support
-- ---------------------------------------------------------------------------
do $$
declare
  receipt jsonb;
  minted_key text;
begin
  begin
    insert into semantic_private.parent_proposals
      (normalized_label, proposal_label, family, hub_key,
       proposed_by_term, grounded, confidence, corpus)
    values
      -- A thing: three grounded terms name a franchise. Mints.
      ('0347 probe universe', '0347 Probe Universe', 'franchise',
       'hub:film_video', 'term_a|work', true, 0.9, 'probe'),
      ('0347 probe universe', '0347 Probe Universe', 'franchise',
       'hub:film_video', 'term_b|work', true, 0.9, 'probe'),
      ('0347 probe universe', '0347 Probe Universe', 'franchise',
       'hub:film_video', 'term_c|work', true, 0.9, 'probe'),
      -- A category: the same support, an art-family heading. Queues.
      ('0347 probe style', '0347 Probe Style', 'art',
       'hub:arts_live', 'term_d|work', true, 0.9, 'probe'),
      ('0347 probe style', '0347 Probe Style', 'art',
       'hub:arts_live', 'term_e|work', true, 0.9, 'probe'),
      ('0347 probe style', '0347 Probe Style', 'art',
       'hub:arts_live', 'term_f|work', true, 0.9, 'probe');

    receipt := semantic_private.mint_proposed_parents(3);

    if (receipt ->> 'minted')::integer <> 1 then
      raise exception '0347: expected the franchise to mint, got %', receipt;
    end if;
    if (receipt ->> 'queued_for_authoring')::integer <> 1 then
      raise exception '0347: expected the category to queue, got %', receipt;
    end if;

    -- The category minted nothing, and its proposals are still pending.
    minted_key := ontology.mint_concept_key('art', 'topic',
                                            '0347 probe style', '0347 Probe Style');
    if exists (select 1 from ontology.concepts where concept_key = minted_key) then
      raise exception '0347: a category-family heading was minted';
    end if;
    if exists (select 1 from semantic_private.parent_proposals
                where normalized_label = '0347 probe style'
                  and status <> 'pending') then
      raise exception '0347: a queued category proposal was closed';
    end if;

    -- The thing really minted.
    minted_key := ontology.mint_concept_key('franchise', 'work',
                                            '0347 probe universe',
                                            '0347 Probe Universe');
    if not exists (select 1 from ontology.concepts where concept_key = minted_key) then
      raise exception '0347: the franchise did not mint';
    end if;

    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then
      raise notice '0347: thing mints, category queues; probe rolled back';
  end;

  if exists (select 1 from semantic_private.parent_proposals where corpus = 'probe') then
    raise exception '0347: probe proposals survived their rollback';
  end if;
end;
$$;
