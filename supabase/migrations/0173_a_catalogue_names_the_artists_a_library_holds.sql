-- 0173 — a catalogue names the artists a library holds.
--
-- ## What was measured
--
-- 2026-08-14, across both real accounts:
--
-- | | distinct performers | in the creator vocabulary | |
-- |---|---|---|---|
-- | the library `0075` was minted from | 1,050 | 238 | **22.7%** |
-- | the second account | 479 | 31 | **6.5%** |
--
-- **The number that decides it: the two accounts share 307 performers and only
-- 29 of them are in the vocabulary.** 278 genuine commonalities between two real
-- people are invisible — the one thing distillation exists to compute. 1,140
-- creator concepts exist, 602 have never matched anything, and Taylor Swift is
-- absent.
--
-- The vocabulary does not generalise to a second user and does not cover the
-- first. **Authoring cannot close a tail that grows with every signup**, and the
-- growth path that was supposed to — `EmergentTermMiner` — is never invoked:
-- `handler.py` registers only `recompute_user`, nothing enqueues `mine_terms`,
-- `resolve.py` stamps `safe_for_global_mining=False` on every music term, and
-- `exact_terms_only` discards an unmatched term before the mapper sees it. The
-- 448 unmatched performers leave no record but an integer in run metrics.
--
-- ## What decides that a concept exists
--
-- **Apple's catalogue, keyed on its artist id** (owner, 2026-08-14). The id is
-- the point: `Leehom Wang`, `王力宏` and `Wang Leehom` converge on one concept
-- rather than fragmenting into three that can never match each other. A name is
-- a label; an id is an identity.
--
-- This is the `0075` lane, not the `0134` lane — `tools/seed_from_csv.py:12-16`
-- draws it: *"the CSVs hold the hand-authored core … and generated migrations
-- hold what is read out of a library."* No CSV family is added and no
-- `seed_*.csv` is touched, so `test_seed_consistency` keeps mirroring `0044`.
--
-- ## Order of application, which is not optional
--
-- This reads `ontology.external_entities` and mints nothing if it is empty, so
-- **`tools/apple_catalog.py`'s generated migration must be applied first.** That
-- tool is where the network call lives; no MusicKit credential goes near the
-- database and no catalogue lookup sits inside the scoring path.
--
-- **`0172` is deliberately left free for that generated dump**, so the two
-- arrive in the order they must be applied in rather than relying on somebody
-- remembering. `0171` is its other precondition — it grants `semantic_worker`
-- the read on `external_entities`.
--
-- It **raises rather than passing quietly** when there are no artist rows. A
-- migration that mints nothing and reports success is how the operator learns
-- the ordering was wrong six weeks later.
--
-- ## The three ways this fails silently, and what refuses each
--
-- 1. **`normalized_label` computed the wrong way.** An alias matches only if its
--    stored form is byte-identical to `normalize_text`, which folds punctuation
--    to spaces; `str.lower()` keeps it, so `P!nk` would store as `p!nk` and
--    never match `p nk`. `apple_catalog.py` imports `normalize_text` itself and
--    carries the answer in `raw_payload->>'normalized'`, because SQL cannot
--    reproduce a Unicode-category fold. Rows without it are refused below.
-- 2. **A label collision makes *both* concepts worthless.** `graph.py:168-190`
--    downgrades a colliding match to `candidate`, and the scorer counts only
--    `accepted` — so two artists sharing a name silently cancel each other. Both
--    kinds are skipped here: a catalogue name matching more than one existing
--    concept, and two catalogue artists normalising alike.
-- 3. **An alias that is an ordinary word over-matches.** Judged *not* to apply
--    to this lane and deliberately not guarded: `resolve.py:126-133` narrows the
--    `work` lane because titles are matched against free text, and `0134`
--    refused bare `Eve` because a YouTube *uploader tag* is free text. A creator
--    term is only ever emitted from `primary_performer`, `credited_artists` or a
--    composer field — already an artist name — and `_type_compatible` maps a
--    `creator` hint to `{creator, organization}` alone. Recorded so the next
--    reader knows it was considered rather than missed.
--
-- ## What this does not do
--
-- It mints **only artists somebody actually listens to**, since the catalogue
-- rows are driven by ISRCs already in the vault. An unattested concept is weight
-- in the alias graph that answers nothing.
--
-- It does not re-mint an artist the vocabulary already names: an existing
-- concept is **linked**, never duplicated, so `creator:jay_chou` keeps its id,
-- its mappings and the live assertions resting on it.

begin;

insert into ontology.versions (id, version, parent_version_id, status, description)
select gen_random_uuid(), '0.22.0', v.id, 'draft',
       'Creator concepts minted from Apple''s catalogue, keyed on artist id.'
  from ontology.versions v
 where v.version = '0.21.0'
on conflict (version) do nothing;

do $$
begin
  if not exists (select 1 from ontology.versions where version = '0.22.0') then
    raise exception '0173: no 0.21.0 to branch from — check the ontology head';
  end if;
end;
$$;

-- Copy-forward, identical in shape to what `tools/seed_from_csv.py` emits.
insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
select new_v.id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
from ontology.concept_revisions r
join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = '0.21.0'
cross join (select id from ontology.versions where version = '0.22.0') new_v
on conflict do nothing;

insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
select new_v.id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
from ontology.concept_labels l
join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = '0.21.0'
cross join (select id from ontology.versions where version = '0.22.0') new_v
on conflict do nothing;

insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
select new_v.id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
from ontology.concept_edges e
join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = '0.21.0'
cross join (select id from ontology.versions where version = '0.22.0') new_v
on conflict do nothing;

insert into ontology.motif_rules (
  id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
  evidence_predicate_key, output_predicate_key, rule_kind,
  minimum_independence_groups, minimum_strength, configuration, status)
select gen_random_uuid(), new_v.id, m.rule_key, m.evidence_target_concept_id,
       m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key,
       m.rule_kind, m.minimum_independence_groups, m.minimum_strength,
       m.configuration, m.status
from ontology.motif_rules m
join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = '0.21.0'
cross join (select id from ontology.versions where version = '0.22.0') new_v
on conflict do nothing;

-- **The catalogue's latest word per artist.** `external_entities` is append-only
-- on `(provider, external_id, payload_hash)`, so a renamed artist has two rows
-- and the newest is the one to believe — the same "read the current item, not
-- every revision" rule the vault uses one layer down.
create temporary table mint_candidate on commit drop as
select distinct on (e.external_id)
       e.external_id                     as apple_id,
       e.id                              as entity_id,
       e.label                           as name,
       e.raw_payload ->> 'normalized'    as normalized
  from ontology.external_entities e
 where e.provider = 'apple_music_catalog'
   and e.entity_kind = 'artist'
   and coalesce(e.raw_payload ->> 'normalized', '') <> ''
 order by e.external_id, e.retrieved_at desc;

do $$
declare
  total integer;
begin
  select count(*) into total from mint_candidate;
  if total = 0 then
    raise exception
      '0173: no apple_music_catalog artist entities. Apply the migration from '
      '`tools/apple_catalog.py` first — this migration mints from what that one '
      'stores, and minting nothing while reporting success is worse than failing.';
  end if;
  raise notice '0173: % catalogue artists to consider', total;
end;
$$;

-- **A name the catalogue states twice is refused, not guessed at.** Two distinct
-- Apple ids normalising to the same string would mint two concepts sharing a
-- label, which is precisely the collision that makes both unusable.
create temporary table mint_ambiguous on commit drop as
select normalized
  from mint_candidate
 group by normalized
having count(*) > 1;

-- **A name the vocabulary already carries more than once is refused too**, for
-- the same reason from the other direction: linking to one of them leaves the
-- other still colliding.
--
-- **Restricted to the kinds a creator term can reach.** `graph.py`'s
-- `_type_compatible` maps a `creator` hint to `{creator, organization}`, so
-- those are the only concepts an artist name may be linked to. Matching on
-- label alone would file an Apple *artist* entity against `work:wicked` — the
-- provenance would read as though the catalogue had named a musical.
create temporary table existing_creator on commit drop as
select l.normalized_label,
       min(l.concept_id::text)::uuid as concept_id,
       count(distinct l.concept_id)  as concepts
  from ontology.concept_labels l
  join ontology.versions v
    on v.id = l.ontology_version_id and v.version = '0.22.0'
  join ontology.concept_revisions r
    on r.ontology_version_id = v.id and r.concept_id = l.concept_id
 where l.status = 'active'
   and r.status = 'active'
   and r.concept_kind in ('creator', 'organization')
 group by l.normalized_label;

-- Every label at this version, whatever its kind. **The alias graph is keyed on
-- the normalised string and knows nothing about kinds**, so a minted creator
-- sharing a name with a work or a genre collides with it, and `graph.py`
-- downgrades *both* to `candidate`. Minting `creator:apple_…` labelled `Wicked`
-- beside `work:wicked` would cost the work concept as well as gaining nothing.
create temporary table any_label on commit drop as
select distinct l.normalized_label
  from ontology.concept_labels l
  join ontology.versions v
    on v.id = l.ontology_version_id and v.version = '0.22.0'
 where l.status = 'active';

create temporary table mint_plan on commit drop as
select c.apple_id,
       c.entity_id,
       c.name,
       c.normalized,
       e.concept_id                                as existing_concept_id,
       case
         when a.normalized is not null            then 'ambiguous_catalogue'
         when e.concepts > 1                      then 'ambiguous_vocabulary'
         when e.concept_id is not null            then 'link'
         when o.normalized_label is not null      then 'would_collide'
         else                                          'mint'
       end                                         as disposition
  from mint_candidate c
  left join mint_ambiguous a  on a.normalized = c.normalized
  left join existing_creator e on e.normalized_label = c.normalized
  left join any_label o        on o.normalized_label = c.normalized;

do $$
declare
  minting integer; linking integer; ambiguous integer; colliding integer;
begin
  select count(*) filter (where disposition = 'mint'),
         count(*) filter (where disposition = 'link'),
         count(*) filter (where disposition like 'ambiguous%'),
         count(*) filter (where disposition = 'would_collide')
    into minting, linking, ambiguous, colliding
    from mint_plan;
  -- **Said out loud rather than left to inference.** A skipped artist is a
  -- person's term that will not resolve, and a silent cap reads as coverage.
  raise notice '0173: % to mint, % to link, % refused as ambiguous, % refused as colliding',
    minting, linking, ambiguous, colliding;
end;
$$;

-- 1. The concepts. `creator:apple_<id>` — the catalogue's identity, not a slug
--    of the name, so `0091`'s nine-artists-into-one merge cannot recur here.
insert into ontology.concepts (id, concept_key)
select gen_random_uuid(), 'creator:apple_' || p.apple_id
  from mint_plan p
 where p.disposition = 'mint'
on conflict (concept_key) do nothing;

-- 2. The revision. `creator`, because `graph.py`'s `_type_compatible` maps a
--    `creator` term hint to `{creator, organization}` and nothing else.
insert into ontology.concept_revisions (
  ontology_version_id, concept_id, preferred_label, concept_kind,
  definition, sensitivity, inference_policy, status, metadata)
select new_v.id, c.id, p.name, 'creator',
       null, 'ordinary', 'inferable', 'active',
       jsonb_build_object('provider', 'apple_music_catalog', 'external_id', p.apple_id)
  from mint_plan p
  join ontology.concepts c on c.concept_key = 'creator:apple_' || p.apple_id
 cross join (select id from ontology.versions where version = '0.22.0') new_v
 where p.disposition = 'mint'
on conflict do nothing;

-- 3. The label, and the one that actually matches.
--
--    **`alternate`, not `preferred`.** Only `preferred` and `alternate`
--    auto-accept (`graph.py:14`), and `0096` minted 35 concepts that could never
--    resolve by giving them prose `preferred` labels the resolver never emits.
--    Here the two happen to be the same string, so both are written: the
--    `preferred` is what a person reads on a card, the `alternate` is the
--    matching token. `normalized_label` comes from the tool, never from
--    `lower()`.
insert into ontology.concept_labels (
  ontology_version_id, concept_id, label, normalized_label, locale,
  label_type, provenance_type, confidence, status, external_ref)
select new_v.id, c.id, p.name, p.normalized, 'und',
       kind.label_type, 'external', 1.0, 'active',
       jsonb_build_object('provider', 'apple_music_catalog', 'external_id', p.apple_id)
  from mint_plan p
  join ontology.concepts c on c.concept_key = 'creator:apple_' || p.apple_id
 cross join (select id from ontology.versions where version = '0.22.0') new_v
 cross join (values ('preferred'), ('alternate')) as kind(label_type)
 where p.disposition = 'mint'
on conflict do nothing;

-- 4. The parent. **A concept without one is a floating node, and minting
--    thousands of those is not growth.**
--
--    `concept_block` answers null for a creator with no `broader` edge, so the
--    term lands under "Other" on Memories, belongs to no hub, and is invisible
--    to anything that reasons over the hierarchy. `0162` exists precisely
--    because eight k-pop members were minted without one and had to be given
--    parents by hand afterwards — which does not scale to a catalogue.
--
--    Apple states an artist's own `genreNames`, so the parent arrives in the
--    same response as the identity. The genre is matched by its **normalised**
--    form, precomputed by the tool for the same reason the artist's name is:
--    SQL cannot reproduce a Unicode-category fold.
--
--    **Only where the genre resolves to exactly one concept.** An unrecognised
--    genre yields no edge rather than a guessed one, and an ambiguous one is
--    refused for the same reason a colliding label is.
insert into ontology.concept_edges (
  ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
  confidence, provenance_type, provenance, status)
select distinct new_v.id, c.id, 'broader', g.concept_id, 1.0, 'provider',
       jsonb_build_object('source', '0173', 'provider', 'apple_music_catalog'),
       'active'
  from mint_plan p
  join ontology.concepts c on c.concept_key = 'creator:apple_' || p.apple_id
  join ontology.external_entities e on e.id = p.entity_id
  cross join lateral jsonb_array_elements_text(
    coalesce(e.raw_payload -> 'genres_normalized', '[]'::jsonb)
  ) as stated(genre)
  join (
    select l.normalized_label,
           min(l.concept_id::text)::uuid as concept_id
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = '0.22.0'
      join ontology.concept_revisions r
        on r.ontology_version_id = v.id and r.concept_id = l.concept_id
     where l.status = 'active'
       and r.status = 'active'
       and r.concept_kind = 'genre'
     group by l.normalized_label
    having count(distinct l.concept_id) = 1
  ) g on g.normalized_label = stated.genre
 cross join (select id from ontology.versions where version = '0.22.0') new_v
 where p.disposition = 'mint'
on conflict do nothing;

-- 5. Provenance, for both the minted and the merely linked.
--
--    **This is what `external_concept_links` is for**, and it is the reason the
--    catalogue is auditable rather than folklore: every concept here can name
--    the entity it came from. It cannot mint — its composite foreign key is to
--    `concept_revisions(ontology_version_id, concept_id)` — so it annotates a
--    concept this same migration created, at this same version.
insert into ontology.external_concept_links (
  ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
select new_v.id,
       coalesce(p.existing_concept_id, c.id),
       p.entity_id, 'same_as', 1.0, 'active'
  from mint_plan p
  left join ontology.concepts c on c.concept_key = 'creator:apple_' || p.apple_id
 cross join (select id from ontology.versions where version = '0.22.0') new_v
 where p.disposition in ('mint', 'link')
   and coalesce(p.existing_concept_id, c.id) is not null
on conflict do nothing;

do $$
declare
  sample record;
  resolved integer;
  minted integer;
  parented integer;
  unresolvable text;
begin
  -- **Resolvability, not a count.** `0096` is the precedent: 35 concepts, all
  -- present, all correct by any count, none of them able to match a term. The
  -- question is whether a label the resolver would emit finds this concept at
  -- this version, so that is the question asked.
  select count(*) into minted
    from mint_plan where disposition = 'mint';

  select p.normalized into unresolvable
    from mint_plan p
   where p.disposition = 'mint'
     and not exists (
       select 1
         from ontology.concept_labels l
         join ontology.versions v
           on v.id = l.ontology_version_id and v.version = '0.22.0'
        where l.normalized_label = p.normalized
          and l.status = 'active'
          and l.label_type in ('preferred', 'alternate'))
   limit 1;
  if unresolvable is not null then
    raise exception '0173: minted a creator that cannot resolve: %', unresolvable;
  end if;

  -- And the negative: nothing *this migration minted* may collide, or it and
  -- its twin are both worth nothing.
  --
  -- **Scoped to the new concepts on purpose.** Measured before writing this:
  -- **7 colliding labels already exist at 0.21.0**, so a blanket check would
  -- fail the migration over a condition it did not cause and cannot fix here.
  -- Those seven are a real defect — each pair silently resolves to `candidate`
  -- and contributes no evidence — but they are their own piece of work, and a
  -- guard that refuses to run because of somebody else's bug is a guard that
  -- gets deleted.
  select count(*) into resolved
    from mint_plan p
    join ontology.concept_labels l on l.normalized_label = p.normalized
    join ontology.versions v
      on v.id = l.ontology_version_id and v.version = '0.22.0'
   where p.disposition = 'mint'
     and l.status = 'active'
   group by p.normalized
  having count(distinct l.concept_id) > 1
   limit 1;
  if resolved is not null then
    -- A backstop rather than the guard: `would_collide` above already refuses
    -- these. Reaching here means that filter and this check disagree, which is
    -- worth stopping for.
    raise exception
      '0173: a minted creator collides with an existing label — both sides '
      'would resolve to candidate and neither would count';
  end if;

  raise notice '0173: % creators minted and resolvable, no collisions', minted;

  -- **Parent coverage, said out loud.** An artist Apple states no genre for
  -- legitimately has no parent, so this is a notice rather than a failure — but
  -- a run where *nothing* got one means the genre join is broken, and a number
  -- nobody prints is a number nobody checks. If `parented` is 0 while `minted`
  -- is large, `genres_normalized` is missing from the catalogue payload and the
  -- vocabulary is growing flat.
  select count(distinct e.subject_concept_id) into parented
    from ontology.concept_edges e
    join ontology.versions v
      on v.id = e.ontology_version_id and v.version = '0.22.0'
    join mint_plan p
      on p.disposition = 'mint'
    join ontology.concepts c
      on c.concept_key = 'creator:apple_' || p.apple_id
     and c.id = e.subject_concept_id
   where e.predicate_key = 'broader';
  raise notice '0173: % of % minted creators have a genre parent', parented, minted;

  for sample in
    select p.name from mint_plan p where p.disposition = 'link' limit 3
  loop
    raise notice '0173: linked existing concept for %', sample.name;
  end loop;
end;
$$;

update ontology.versions set status = 'retired'
 where version = '0.21.0' and status = 'published';
update ontology.versions set status = 'published', published_at = now()
 where version = '0.22.0';

do $$
declare
  published integer;
  enqueued  integer;
begin
  select count(*) into published from ontology.versions where status = 'published';
  if published <> 1 then
    raise exception '0173: expected exactly one published ontology version, found %', published;
  end if;

  -- **The last statement, and the only thing that makes any of this run.** A new
  -- ontology version is one of the three levers that forces a fresh run, so no
  -- model version is bumped here — the resolver's behaviour has not changed, the
  -- vocabulary it reads has.
  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology 0.22.0: a catalogue names the artists a library holds'
         ) into enqueued;
  raise notice '0173: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
