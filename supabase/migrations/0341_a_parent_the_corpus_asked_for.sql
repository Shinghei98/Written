-- 0341 — a missing parent is proposed, corroborated, and only then minted.
--
-- **The create-new arm of the assign-or-create decision (owner, 2026-08-24),
-- which until now existed only as a form nobody ever filled in.** The
-- extraction schema's `missing_parent_proposal` demands seven authored fields
-- and produced **zero proposals in 1,540 items across every prompt version**.
-- With no way to say "the right heading is missing", the placement pass dumped
-- terms into the nearest broad bucket instead — 491 of 1,262 placements (39%)
-- on a broad heading, `One Piece` under Arts & live culture, and
-- `culture:taiwan` needed by the owner's own worked example while nothing in
-- any code path could create it.
--
-- The cheap proposal now exists (`tools/ris_parent_propose.py`: label, family,
-- hub, confidence — three of four fields closed). This migration is where a
-- proposal becomes a concept, and the two gates between are the point:
--
-- **Gate 1 — corroboration: only grounded terms count.** A term attested only
-- by inference is the lane the offset checks cannot reach *by design*
-- (`mention_extract_v2.py:250`), and it is the lane 16 false `One Piece`
-- mentions arrived through — every one anchored on the prompt's own worked
-- example, against a live rule forbidding exactly that. An ungrounded
-- proposal is recorded (evidence is never discarded) and never counted.
--
-- **Gate 2 — the floor: N distinct terms must ask for the same parent.** One
-- term proposing a heading is the term wearing a hat; a heading is a place
-- where many things live. The floor is a parameter with a default of 3 —
-- stated, not hidden, and movable without a migration.
--
-- ## Why this reuses the kept-mint machinery instead of inserting rows
--
-- `semantic_private.mint_from_kept_requests` is the only thing that has ever
-- minted a concept at runtime, and what it does is not an insert: a draft
-- version, `copy_forward_version`, concepts + revisions + labels + edges,
-- collision checks (same-kind links, other-kind refuses), `publish_version`.
-- **A second minter that skipped any of that would be the catalogue growing a
-- second spelling of itself.** This function mirrors those mechanics
-- statement-for-statement; what differs is only the admission test — a keep is
-- one person's decision about their own term, a proposal is corpus evidence
-- about a heading — and the parent, which here is the proposal's own hub.
--
-- ## A known limit, named rather than papered over
--
-- The proposal's family is a wire family, and the wire has no `genre`. A
-- missing music genre arrives as `art` (→ `movement:`) or `culture`; a
-- missing franchise-as-heading arrives as `franchise` (→ `work:`), which is
-- the `One Piece` case and the catalogue's own convention
-- (`work:spider_man`). If genre-shaped proposals dominate a future corpus,
-- the wire needs the family before this table needs a change.

create table semantic_private.parent_proposals (
  id uuid primary key default gen_random_uuid(),
  -- The proposed heading, normalized exactly as the kept minter normalizes —
  -- one rule, not a second spelling of it.
  normalized_label text not null check (length(btrim(normalized_label)) > 0),
  proposal_label text not null check (length(btrim(proposal_label)) > 0),
  family text not null references ontology.family_mint_convention (family),
  hub_key text not null check (hub_key like 'hub:%'),
  -- Which dictionary term asked for it, by the placement pass's own key.
  proposed_by_term text not null,
  -- **Gate 1 travels with the row.** False means the proposing term was never
  -- seen with an offset — recorded, never counted.
  grounded boolean not null,
  confidence numeric check (confidence is null or confidence between 0 and 1),
  corpus text not null,
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'refused')),
  outcome jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  check ((status = 'pending') = (completed_at is null)),
  -- One term proposes one heading once per corpus; a re-emission updates
  -- nothing and duplicates nothing.
  unique (normalized_label, family, proposed_by_term, corpus)
);

create index parent_proposals_pending_idx
  on semantic_private.parent_proposals (normalized_label, family)
  where status = 'pending';

comment on table semantic_private.parent_proposals is
  'Headings the placement pass said were missing (needs_new_parent). A '
  'proposal from an ungrounded term is stored and never counted; N distinct '
  'grounded terms proposing the same heading is what mints it — '
  'mint_proposed_parents holds both gates.';

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
           -- **Gate 1 inside the aggregate**: distinct grounded proposers.
           count(distinct p.proposed_by_term)
             filter (where p.grounded) as grounded_terms,
           count(distinct p.proposed_by_term) as all_terms,
           -- The hub the proposals themselves agree on; ties break stably.
           (select p2.hub_key from semantic_private.parent_proposals p2
             where p2.normalized_label = p.normalized_label
               and p2.family = p.family and p2.status = 'pending'
             group by p2.hub_key
             order by count(*) desc, p2.hub_key limit 1) as hub_key,
           -- The best-attested spelling becomes the label.
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
             -- **Gate 2.** Below the floor is held pending, not refused: the
             -- next corpus may corroborate, and evidence keeps accruing.
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
         count(*) filter (where disposition = 'hold')
    into to_mint, linked, held
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

    -- **The hub edge, and it is never invented.** The hub arrived as an enum
    -- the proposal pass could not step outside, and `hub_id` resolved it
    -- against live concepts — a proposal naming a hub this catalogue does not
    -- hold was refused above, not defaulted.
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
    on conflict do nothing;

    perform ontology.publish_version(new_version_id);
  end if;

  -- 'hold' rows stay pending on purpose — the floor is a threshold evidence
  -- can still cross, not a verdict.
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
     and k.disposition <> 'hold';

  return jsonb_build_object(
    'minted', to_mint, 'linked', linked, 'held_below_floor', held,
    'floor', p_floor,
    'version', coalesce(next_version, current_version));
end;
$$;

revoke all on function semantic_private.mint_proposed_parents(integer)
  from public;

comment on function semantic_private.mint_proposed_parents(integer) is
  'Mints headings that >= p_floor distinct grounded terms proposed, through '
  'the same draft/copy-forward/publish machinery as mint_from_kept_requests, '
  'parented under the hub the proposals named. Ungrounded proposals never '
  'count (the inferred lane is the one no offset check can reach); '
  'below-floor groups stay pending so later corpora can corroborate.';

-- ---------------------------------------------------------------------------
-- Proven both ways, over the real machinery, rolled back by raising
-- ---------------------------------------------------------------------------
-- **Both gates are the migration, so both are made to answer twice.** The
-- probe runs the actual mint — draft version, copy-forward, publish — and
-- rolls the whole thing back with a raise; `parent_proposals` has no delete
-- guard yet, but the raise pattern is the one this chain has used all day and
-- it cannot half-succeed.
do $$
declare
  receipt jsonb;
  minted_key text;
  hub_id uuid;
begin
  begin
    -- Three grounded terms and one ungrounded propose the same heading; a
    -- second heading is proposed by two grounded and one ungrounded term.
    insert into semantic_private.parent_proposals
      (normalized_label, proposal_label, family, hub_key,
       proposed_by_term, grounded, confidence, corpus)
    values
      ('0341 probe heading', '0341 Probe Heading', 'culture',
       'hub:places_cultures', 'term_a|culture', true,  0.9, 'probe'),
      ('0341 probe heading', '0341 Probe Heading', 'culture',
       'hub:places_cultures', 'term_b|culture', true,  0.9, 'probe'),
      ('0341 probe heading', '0341 Probe Heading', 'culture',
       'hub:places_cultures', 'term_c|culture', true,  0.9, 'probe'),
      ('0341 probe heading', '0341 Probe Heading', 'culture',
       'hub:places_cultures', 'term_d|culture', false, 0.9, 'probe'),
      ('0341 probe thin', '0341 Probe Thin', 'culture',
       'hub:places_cultures', 'term_e|culture', true,  0.9, 'probe'),
      ('0341 probe thin', '0341 Probe Thin', 'culture',
       'hub:places_cultures', 'term_f|culture', true,  0.9, 'probe'),
      ('0341 probe thin', '0341 Probe Thin', 'culture',
       'hub:places_cultures', 'term_g|culture', false, 0.9, 'probe');

    receipt := semantic_private.mint_proposed_parents(3);

    -- The corroborated heading minted; the thin one held.
    if (receipt ->> 'minted')::integer <> 1 then
      raise exception '0341: expected 1 mint, got %', receipt;
    end if;
    if (receipt ->> 'held_below_floor')::integer <> 1 then
      raise exception
        '0341: the two-grounded heading should hold below a floor of 3, got %',
        receipt;
    end if;

    -- **The ungrounded proposer did not count.** `probe thin` had three
    -- proposers and only two grounded — if it minted, gate 1 is not a gate.
    minted_key := ontology.mint_concept_key('culture', 'topic',
                                            '0341 probe thin', '0341 Probe Thin');
    if exists (select 1 from ontology.concepts where concept_key = minted_key) then
      raise exception '0341: an inference-corroborated heading was minted';
    end if;

    -- The minted heading exists, under the named hub, in the new version.
    minted_key := ontology.mint_concept_key('culture', 'topic',
                                            '0341 probe heading',
                                            '0341 Probe Heading');
    select c.id into hub_id from ontology.concepts c
     where c.concept_key = 'hub:places_cultures';
    if not exists (
      select 1 from ontology.concept_edges e
      join ontology.concepts c on c.id = e.subject_concept_id
     where c.concept_key = minted_key
       and e.predicate_key = 'broader'
       and e.object_concept_id = hub_id
       and e.status = 'active') then
      raise exception '0341: the minted heading carries no edge to its hub';
    end if;

    -- The held group is still pending — a threshold, not a verdict.
    if exists (select 1 from semantic_private.parent_proposals
                where normalized_label = '0341 probe thin'
                  and status <> 'pending') then
      raise exception '0341: a below-floor proposal was closed';
    end if;

    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then
      raise notice '0341: both gates answer both ways; probe rolled back';
  end;

  -- And the rollback held: no probe residue in durable tables.
  if exists (select 1 from semantic_private.parent_proposals
              where corpus = 'probe') then
    raise exception '0341: probe proposals survived their rollback';
  end if;
  if exists (select 1 from ontology.concepts
              where concept_key like '%0341_probe%') then
    raise exception '0341: a probe concept survived its rollback';
  end if;
end;
$$;
