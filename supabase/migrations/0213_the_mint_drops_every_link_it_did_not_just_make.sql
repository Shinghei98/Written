-- 0213 — the mint drops every link it did not just make.
--
-- ## A live, armed data-loss path
--
-- `semantic_private.mint_vocabulary_from_catalogue` publishes a new ontology
-- version and copies the prior one forward. It copies four tables:
-- `concept_revisions`, `concept_labels`, `concept_edges`, `motif_rules`. It does
-- not copy `external_concept_links`, and asked of the catalog its body contains
-- no `from ontology.external_concept_links` at all. The single insert into that
-- table selects `from mint_plan` — the links for the batch being minted now.
--
-- So the next publish carries that batch's links and **nothing else**. There are
-- 760 links at the published version today, every one of them the provenance of
-- a minted artist, and all 760 would be gone.
--
-- **This is `0179` and `0180`'s defect exactly** — the one that took 550 links to
-- 1 and destroyed the provenance of every minted artist with nothing raising.
-- Those were migrations and were repaired. This is the function that runs
-- *automatically*: `arm_vocabulary_mint_on_ingestion` arms it on every ingestion
-- run that succeeds, and it publishes whenever it finds vocabulary to mint. It
-- has not fired only because nothing new has been minted since the fix went into
-- the migrations. The next unfamiliar artist in anybody's library is the trigger.
--
-- It was found while checking a prerequisite for the ISRC work and is not really
-- an ISRC prerequisite. It is a standing hazard that happens to sit in front of
-- it, and minting thousands of recordings behind an unfixed version of it would
-- have been the worst possible time to meet it.
--
-- ## What is not proven here
--
-- The honest test is two real mint batches — mint A, publish, mint B, publish,
-- assert A's links survive — and that needs catalogue vocabulary this database
-- has already minted, so the function early-returns without publishing. The
-- assertions below prove the statement carries links across versions and that
-- the function now reads the table at all. **The two-batch test belongs in the
-- ISRC release**, where batch B is real, and is listed as one of its gates.

begin;

create or replace function semantic_private.mint_vocabulary_from_catalogue(
  p_user_ids uuid[],
  p_songs jsonb default '[]'::jsonb,
  p_artists jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_version text;
  next_version    text;
  new_version_id  uuid;
  songs_stored    integer := 0;
  artists_stored  integer := 0;
  to_mint         integer := 0;
  to_link         integer := 0;
  refused         integer := 0;
  parented        integer := 0;
  enqueued        integer := 0;
begin
  -- 1. The catalogue cache. Version-free, concept-free, user-free — a
  --    third-party answer about a recording, not anybody's evidence. Unique on
  --    `(provider, external_id, payload_hash)`, so an unchanged answer conflicts
  --    and a changed one lands beside its predecessor.
  insert into ontology.external_entities (
    provider, external_id, entity_kind, label, raw_payload,
    payload_hash, license_code, retrieved_at
  )
  select 'apple_music_catalog',
         song ->> 'isrc',
         'song',
         coalesce(song ->> 'label', ''),
         song - 'isrc' - 'label' - 'payload_hash',
         song ->> 'payload_hash',
         'apple_media_services',
         now()
    from jsonb_array_elements(coalesce(p_songs, '[]'::jsonb)) as song
   where coalesce(song ->> 'isrc', '') <> ''
     and coalesce(song ->> 'payload_hash', '') <> ''
  on conflict (provider, external_id, payload_hash) do nothing;
  get diagnostics songs_stored = row_count;

  insert into ontology.external_entities (
    provider, external_id, entity_kind, label, raw_payload,
    payload_hash, license_code, retrieved_at
  )
  select 'apple_music_catalog',
         artist ->> 'external_id',
         'artist',
         coalesce(artist ->> 'name', ''),
         artist - 'external_id' - 'payload_hash',
         artist ->> 'payload_hash',
         'apple_media_services',
         now()
    from jsonb_array_elements(coalesce(p_artists, '[]'::jsonb)) as artist
   where coalesce(artist ->> 'external_id', '') <> ''
     and coalesce(artist ->> 'payload_hash', '') <> ''
     and coalesce(artist ->> 'normalized', '') <> ''
  on conflict (provider, external_id, payload_hash) do nothing;
  get diagnostics artists_stored = row_count;

  -- 2. What is worth minting. The catalogue's latest word per artist, and only
  --    artists somebody actually listens to — driven by ISRCs already in the
  --    vault, never a bulk import of Apple's catalogue.
  --
  --    Dropped first: `on commit drop` clears these at the end of the
  --    transaction, not the end of the call, so a second call in one transaction
  --    would otherwise fail on a name that already exists.
  drop table if exists mint_candidate;
  drop table if exists mint_plan;

  create temporary table mint_candidate on commit drop as
  select distinct on (e.external_id)
         e.external_id                  as apple_id,
         e.id                           as entity_id,
         e.label                        as name,
         e.raw_payload ->> 'normalized' as normalized,
         e.raw_payload -> 'genres_normalized' as genres
    from ontology.external_entities e
   where e.provider = 'apple_music_catalog'
     and e.entity_kind = 'artist'
     and coalesce(e.raw_payload ->> 'normalized', '') <> ''
   order by e.external_id, e.retrieved_at desc;

  select version into current_version
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception 'mint_vocabulary: no published ontology version';
  end if;

  -- **The disposition rules are `0173`'s, unchanged**, and each refusal is a
  -- silent failure this would otherwise cause:
  --   * two catalogue artists normalising alike — minting both makes both
  --     resolve to `candidate` and neither counts;
  --   * a name the vocabulary already carries twice — linking to one leaves the
  --     other colliding;
  --   * a name belonging to a concept of another kind — an artist called Wicked
  --     must not be linked to, or collide with, `work:wicked`. Linking is
  --     restricted to `{creator, organization}`, which is what the mapper's
  --     `_type_compatible` accepts for a creator term.
  create temporary table mint_plan on commit drop as
  with ambiguous as (
    select normalized from mint_candidate group by normalized having count(*) > 1
  ), existing_creator as (
    select l.normalized_label,
           min(l.concept_id::text)::uuid as concept_id,
           count(distinct l.concept_id)  as concepts
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
      join ontology.concept_revisions r
        on r.ontology_version_id = v.id and r.concept_id = l.concept_id
     where l.status = 'active' and r.status = 'active'
       and r.concept_kind in ('creator', 'organization')
     group by l.normalized_label
  ), any_label as (
    select distinct l.normalized_label
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
     where l.status = 'active'
  )
  select c.apple_id, c.entity_id, c.name, c.normalized, c.genres,
         e.concept_id as existing_concept_id,
         case
           when a.normalized is not null      then 'ambiguous_catalogue'
           when e.concepts > 1                then 'ambiguous_vocabulary'
           when e.concept_id is not null      then 'link'
           when o.normalized_label is not null then 'would_collide'
           else                                    'mint'
         end as disposition
    from mint_candidate c
    left join ambiguous a         on a.normalized = c.normalized
    left join existing_creator e  on e.normalized_label = c.normalized
    left join any_label o         on o.normalized_label = c.normalized;

  select count(*) filter (where disposition = 'mint'),
         count(*) filter (where disposition = 'link'),
         count(*) filter (where disposition not in ('mint', 'link'))
    into to_mint, to_link, refused
    from mint_plan;

  -- **Nothing new means no version.** Publishing costs a full copy-forward and a
  -- fresh run for every user; doing that to mint zero concepts is the cost of
  -- arming without a gate, and this is where that cost is refused.
  if to_mint = 0 then
    return jsonb_build_object(
      'minted', 0, 'linked', to_link, 'refused', refused,
      'songs_stored', songs_stored, 'artists_stored', artists_stored,
      'published', false, 'users', coalesce(array_length(p_user_ids, 1), 0)
    );
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;

  insert into ontology.versions (id, version, parent_version_id, status, description)
  select gen_random_uuid(), next_version, v.id, 'draft',
         'Machine mint from apple_music_catalog for ' ||
         coalesce(array_length(p_user_ids, 1), 0)::text || ' account(s).'
    from ontology.versions v
   where v.version = current_version
  on conflict (version) do nothing;

  select id into new_version_id from ontology.versions where version = next_version;
  if new_version_id is null then
    raise exception 'mint_vocabulary: could not open draft %', next_version;
  end if;

  -- 3. Copy-forward, the same four tables `tools/seed_from_csv.py` copies.
  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
    from ontology.concept_revisions r
    join ontology.versions old_v on old_v.id = r.ontology_version_id and old_v.version = current_version
  on conflict do nothing;

  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l
    join ontology.versions old_v on old_v.id = l.ontology_version_id and old_v.version = current_version
  on conflict do nothing;

  insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e
    join ontology.versions old_v on old_v.id = e.ontology_version_id and old_v.version = current_version
  on conflict do nothing;

  -- **The fifth table, and the one this function has never carried.**
  -- `concept_revisions`, `concept_labels`, `concept_edges` and `motif_rules` are
  -- all copied from the prior version above; `external_concept_links` was not,
  -- and its only insert further down writes links for the *current* mint batch.
  -- So batch B's publish carried B's links and nothing else, and every link
  -- batch A had made disappeared from the published version.
  --
  -- That is exactly the defect `0179` and `0180` caused as migrations — 550
  -- links to 1, destroying the provenance of every minted artist with nothing
  -- raising. The migrations were repaired and this function, which runs
  -- automatically on every ingestion that finds new vocabulary, was not.
  insert into ontology.external_concept_links (
    ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, x.concept_id, x.external_entity_id, x.link_type,
         x.confidence, x.status
    from ontology.external_concept_links x
    join ontology.versions old_v
      on old_v.id = x.ontology_version_id and old_v.version = current_version
  on conflict do nothing;

  insert into ontology.motif_rules (
    id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id,
    evidence_predicate_key, output_predicate_key, rule_kind,
    minimum_independence_groups, minimum_strength, configuration, status)
  select gen_random_uuid(), new_version_id, m.rule_key, m.evidence_target_concept_id,
         m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key,
         m.rule_kind, m.minimum_independence_groups, m.minimum_strength,
         m.configuration, m.status
    from ontology.motif_rules m
    join ontology.versions old_v on old_v.id = m.ontology_version_id and old_v.version = current_version
  on conflict do nothing;

  -- 4. Identity, keyed on Apple's artist id so that `Leehom Wang`, `王力宏` and
  --    `Wang Leehom` converge rather than fragmenting into three concepts.
  insert into ontology.concepts (id, concept_key)
  select gen_random_uuid(), 'creator:apple_' || p.apple_id
    from mint_plan p where p.disposition = 'mint'
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, p.name, 'creator',
         null, 'ordinary', 'inferable', 'active',
         jsonb_build_object('provider', 'apple_music_catalog', 'external_id', p.apple_id)
    from mint_plan p
    join ontology.concepts c on c.concept_key = 'creator:apple_' || p.apple_id
   where p.disposition = 'mint'
  on conflict do nothing;

  -- **`alternate` as well as `preferred`.** Only those two auto-accept, and the
  -- resolver emits the bare name, which a prose `preferred` never meets — `0096`
  -- minted 35 concepts that could never resolve by getting this wrong.
  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, c.id, p.name, p.normalized, 'und',
         kind.label_type, 'external', 1.0, 'active',
         jsonb_build_object('provider', 'apple_music_catalog', 'external_id', p.apple_id)
    from mint_plan p
    join ontology.concepts c on c.concept_key = 'creator:apple_' || p.apple_id
   cross join (values ('preferred'), ('alternate')) as kind(label_type)
   where p.disposition = 'mint'
  on conflict do nothing;

  -- 5. The parent. A concept with no `broader` edge is a floating node —
  --    `concept_block` answers null, so the term lands under "Other" and belongs
  --    to no hub. Minting thousands of those is not growth.
  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select distinct new_version_id, c.id, 'broader', g.concept_id, 1.0, 'provider',
         jsonb_build_object('source', 'mint_vocabulary', 'provider', 'apple_music_catalog'),
         'active'
    from mint_plan p
    join ontology.concepts c on c.concept_key = 'creator:apple_' || p.apple_id
   cross join lateral jsonb_array_elements_text(coalesce(p.genres, '[]'::jsonb)) as stated(genre)
    join (
      select l.normalized_label, min(l.concept_id::text)::uuid as concept_id
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.ontology_version_id = l.ontology_version_id and r.concept_id = l.concept_id
       where l.ontology_version_id = new_version_id
         and l.status = 'active' and r.status = 'active'
         and r.concept_kind = 'genre'
       group by l.normalized_label having count(distinct l.concept_id) = 1
    ) g on g.normalized_label = stated.genre
   where p.disposition = 'mint'
     and c.id <> g.concept_id
  on conflict do nothing;

  -- 6. Provenance, for the minted and the merely linked.
  insert into ontology.external_concept_links (
    ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, coalesce(p.existing_concept_id, c.id),
         p.entity_id, 'same_as', 1.0, 'active'
    from mint_plan p
    left join ontology.concepts c on c.concept_key = 'creator:apple_' || p.apple_id
   where p.disposition in ('mint', 'link')
     and coalesce(p.existing_concept_id, c.id) is not null
  on conflict do nothing;

  select count(distinct e.subject_concept_id) into parented
    from ontology.concept_edges e
   where e.ontology_version_id = new_version_id
     and e.predicate_key = 'broader'
     and e.provenance ->> 'source' = 'mint_vocabulary';

  -- 7. Publish through the function built for it. `ontology.publish_version`
  --    takes `share row exclusive` on `ontology.versions`, so two mints
  --    serialise, and it checks for `broader` cycles and unresolvable external
  --    provenance before flipping the pointer. It has existed since `0043` and
  --    nothing has ever called it.
  perform ontology.publish_version(new_version_id);

  select semantic_private.enqueue_recompute_on_analysis_change(
           'mint_vocabulary: ' || next_version
         ) into enqueued;

  return jsonb_build_object(
    'minted', to_mint, 'linked', to_link, 'refused', refused,
    'parented', parented, 'songs_stored', songs_stored,
    'artists_stored', artists_stored, 'published', true,
    'version', next_version, 'recomputes_enqueued', enqueued,
    'users', coalesce(array_length(p_user_ids, 1), 0)
  );
end;
$$;

do $$
declare
  published uuid;
  draft uuid;
  before_links integer;
  carried integer;
begin
  -- 1. The function now reads the table it was dropping. A source check is weak
  --    on its own, which is why it is the second-weakest of the three here — but
  --    the failure being repaired is precisely an *absent statement*, and that is
  --    what this can see.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'semantic_private'
       and p.proname = 'mint_vocabulary_from_catalogue'
       and p.prosrc like '%from ontology.external_concept_links%') then
    raise exception '0213: the mint still never reads existing links';
  end if;

  -- 2. **The copy itself, over the real 760 rows.** A draft version is created,
  --    the statement the function now runs is run against it, and the links must
  --    arrive. Rolled back, so the ontology is untouched.
  select id into published from ontology.versions where status = 'published';
  select count(*) into before_links
    from ontology.external_concept_links where ontology_version_id = published;

  begin
    insert into ontology.versions (id, version, parent_version_id, status, description)
    values (extensions.gen_random_uuid(), '0.0.0-probe', published, 'draft',
            '0213 copy-forward probe')
    returning id into draft;

    -- **Revisions first, and the schema insists.** `external_concept_links` has
    -- a composite foreign key to `concept_revisions(ontology_version_id,
    -- concept_id)`, so a link cannot exist at a version where its concept does
    -- not — which is the constraint that makes a dropped link a *silent* loss
    -- rather than an orphan. The first version of this probe copied links into
    -- a bare draft and was refused, correctly. The function's own ordering was
    -- already right: links go in after revisions, labels and edges.
    insert into ontology.concept_revisions (
      ontology_version_id, concept_id, preferred_label, concept_kind, definition,
      sensitivity, inference_policy, status, metadata)
    select draft, r.concept_id, r.preferred_label, r.concept_kind, r.definition,
           r.sensitivity, r.inference_policy, r.status, r.metadata
      from ontology.concept_revisions r
     where r.ontology_version_id = published
    on conflict do nothing;

    insert into ontology.external_concept_links (
      ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
    select draft, x.concept_id, x.external_entity_id, x.link_type, x.confidence, x.status
      from ontology.external_concept_links x
     where x.ontology_version_id = published
    on conflict do nothing;
    get diagnostics carried = row_count;

    if carried <> before_links then
      raise exception '0213: carried % of % links', carried, before_links;
    end if;

    raise exception using errcode = 'YY001', message = 'probe complete';
  exception
    when sqlstate 'YY001' then null;
  end;

  raise notice '0213: the mint carries % external link(s) across a version', before_links;
end;
$$;

commit;
