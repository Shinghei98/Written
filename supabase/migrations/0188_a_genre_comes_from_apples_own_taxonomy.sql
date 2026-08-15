-- 0188 — a genre comes from Apple's own taxonomy.
--
-- ## What is wrong today
--
-- Our genre vocabulary is a hand-written subset of Apple's, so most of what
-- Apple says about a library lands nowhere. Measured 2026-08-15 over the 931
-- catalogue artists: **45 distinct genre strings, 24 reach a `genre:` concept
-- and 21 do not** — `bollywood` (10 artists), `indian pop` (6), `indie rock`
-- (5), `indie pop` (4), `chinese hip hop` (3), then `afrobeats`, `britpop`,
-- `french pop`, `chinese rock`, `latin`, `bengali`, `big band`, `downtempo`.
--
-- An artist whose only stated genre is unmatched gets **no `broader` edge**, and
-- a concept with no parent is a floating node: `concept_block` answers null and
-- the term is drawn under "Other", or falls to the `hub:music` fallback and
-- reads MUSIC. Hand-authoring the missing ones does not fix it, because the next
-- library names a genre nobody anticipated.
--
-- ## Where the tree came from, and why it is not the obvious endpoint
--
-- `tools/apple_genres.py`, and the measurements are in its header. The short
-- version, because it decides the shape of this migration:
--
--     us/genres, ids 1-6000  ->  22 genres. No J-Pop, no Bollywood, no Afrobeats.
--     all 167 storefronts    ->  **57 genres**, in English, with parents
--
-- **Apple's genre catalogue is per storefront.** Asking `us` finds a fifth of
-- the vocabulary; asking every storefront with `l=en-…` finds `African ->
-- Afrobeats, Amapiano`, `Indian -> Bollywood, Indian Pop, Regional Indian`,
-- `Pop -> K-Pop, J-Pop, Mandopop, Cantopop`, `Brazilian -> Samba, Bossa Nova,
-- MPB`. It is also why our hand-authored genres are exactly J-Pop, Mandopop,
-- Cantopop and Anime: somebody was reading these storefronts by hand.
--
-- 56 genres are minted or linked here; Music itself is excluded because
-- `hub:music` is our word for it, and that substitution is the one place our
-- vocabulary is preferred to Apple's.
--
-- ## Three decisions this encodes
--
-- **Link, never duplicate.** Where Apple's normalised name already matches an
-- active `genre` label, our concept is kept and Apple's id is attached through
-- `external_concept_links`. `genre:pop`, `genre:j_pop`, `genre:rock` and the
-- rest keep their ids, their mappings and their scores.
--
-- **A linked concept keeps the parents it has.** Apple states J-Pop's parent as
-- Music; ours sits under `genre:pop` *and* `genre:asian_music`, which is better
-- and was decided by a person. So a `broader` edge is written only for a genre
-- this migration mints — never onto one somebody already parented.
--
-- **Eleven genres parent to `hub:music` because Apple names a parent it does
-- not expose.** `1262` (the Indian family) and `1122` (the Brazilian one) appear
-- as `parentId` on `Bollywood`, `Indian Pop`, `Regional Indian`, `Indian
-- Classical`, `Devotional & Spiritual`, `Samba`, `Bossa Nova`, `MPB`, `Forró`,
-- `Sertanejo` and `Baile Funk`, and answer 404 from every storefront including
-- the ones carrying their children. Naming them ourselves — inferring "Indian"
-- from its children — is the inference this whole design refuses, so they are
-- treated as top-level and the tool reports them on every run.
--
-- ## What this does not do
--
-- **It does not give the new genres a sphere, scene or era.** Those come from
-- exact, case-sensitive membership of the hand-authored tables in
-- `tools/music_dictionary.py`, and a genre outside them yields nothing with
-- nothing logged (`0171` measured what that costs). Apple's taxonomy cannot
-- supply an editorial judgement about language or decade.
-- `tools/apple_catalog.py` already prints the candidates; after this, that
-- report is the to-do list.
--
-- **It does not put genres on the Memories page.** `list_assertions` returns
-- `creator`, `work` and `activity` only. This changes headings and matching.

begin;

create or replace function semantic_private.mint_genres_from_catalogue(p_genres jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  stored    integer := 0;
  to_mint   integer := 0;
  to_link   integer := 0;
  refused   integer := 0;
  parented  integer := 0;
  enqueued  integer := 0;
begin
  -- 1. The catalogue cache, the same shape artists are stored in: version-free,
  --    concept-free, user-free. Unique on `(provider, external_id,
  --    payload_hash)`, so an unchanged answer conflicts and a changed one lands
  --    beside its predecessor rather than overwriting it.
  insert into ontology.external_entities (
    provider, external_id, entity_kind, label, raw_payload,
    payload_hash, license_code, retrieved_at)
  select 'apple_music_catalog', g ->> 'external_id', 'genre',
         coalesce(g ->> 'name', ''),
         g - 'external_id' - 'payload_hash',
         g ->> 'payload_hash', 'apple_media_services', now()
    from jsonb_array_elements(coalesce(p_genres, '[]'::jsonb)) as g
   where coalesce(g ->> 'external_id', '') <> ''
     and coalesce(g ->> 'payload_hash', '') <> ''
     and coalesce(g ->> 'normalized', '') <> ''
  on conflict (provider, external_id, payload_hash) do nothing;
  get diagnostics stored = row_count;

  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception 'mint_genres: no published ontology version';
  end if;

  drop table if exists genre_candidate;
  drop table if exists genre_plan;

  -- 2. The catalogue's latest word per genre.
  create temporary table genre_candidate on commit drop as
  select distinct on (e.external_id)
         e.external_id                    as apple_id,
         e.id                             as entity_id,
         e.label                          as name,
         e.raw_payload ->> 'normalized'   as normalized,
         e.raw_payload ->> 'parent_id'    as parent_apple_id
    from ontology.external_entities e
   where e.provider = 'apple_music_catalog'
     and e.entity_kind = 'genre'
     and coalesce(e.raw_payload ->> 'normalized', '') <> ''
   order by e.external_id, e.retrieved_at desc;

  -- 3. The plan. `0173`'s disposition rules, narrowed to genres: two catalogue
  --    genres normalising alike would both resolve to `candidate` and neither
  --    would count; a name the vocabulary already carries twice cannot be linked
  --    to without leaving the other colliding; and a name belonging to a concept
  --    of another kind must not be linked to at all.
  create temporary table genre_plan on commit drop as
  with ambiguous as (
    select normalized from genre_candidate group by normalized having count(*) > 1
  ), existing_genre as (
    select l.normalized_label,
           min(l.concept_id::text)::uuid as concept_id,
           count(distinct l.concept_id)  as concepts
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
      join ontology.concept_revisions r
        on r.ontology_version_id = v.id and r.concept_id = l.concept_id
     where l.status = 'active' and r.status = 'active'
       and r.concept_kind = 'genre'
     group by l.normalized_label
  ), any_label as (
    select distinct l.normalized_label
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
     where l.status = 'active'
  )
  select c.apple_id, c.entity_id, c.name, c.normalized, c.parent_apple_id,
         'genre:apple_' || c.apple_id as concept_key,
         e.concept_id as existing_concept_id,
         case
           when a.normalized is not null       then 'ambiguous_catalogue'
           when e.concepts > 1                 then 'ambiguous_vocabulary'
           when e.concept_id is not null       then 'link'
           when o.normalized_label is not null  then 'would_collide'
           else                                     'mint'
         end as disposition
    from genre_candidate c
    left join ambiguous a       on a.normalized = c.normalized
    left join existing_genre e  on e.normalized_label = c.normalized
    left join any_label o       on o.normalized_label = c.normalized;

  select count(*) filter (where disposition = 'mint'),
         count(*) filter (where disposition = 'link'),
         count(*) filter (where disposition not in ('mint', 'link'))
    into to_mint, to_link, refused
    from genre_plan;

  -- **Nothing new means no version.** Publishing copies the whole ontology
  -- forward and forces a fresh run for every account; doing that to mint zero
  -- concepts is a cost with nothing bought.
  if to_mint = 0 then
    return jsonb_build_object(
      'stored', stored, 'minted', 0, 'linked', to_link,
      'refused', refused, 'published', false
    );
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Apple''s genre taxonomy, unioned across storefronts.');
  select id into new_version_id from ontology.versions where version = next_version;

  -- 4. Copy-forward, the same five tables `0184` carried.
  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
    from ontology.concept_revisions r where r.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l where l.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e where e.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.motif_rules (id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id, evidence_predicate_key, output_predicate_key, rule_kind, minimum_independence_groups, minimum_strength, configuration, status)
  select extensions.gen_random_uuid(), new_version_id, m.rule_key, m.evidence_target_concept_id, m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key, m.rule_kind, m.minimum_independence_groups, m.minimum_strength, m.configuration, m.status
    from ontology.motif_rules m where m.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.external_concept_links (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, x.concept_id, x.external_entity_id, x.link_type, x.confidence, x.status
    from ontology.external_concept_links x where x.ontology_version_id = old_version_id
  on conflict do nothing;

  -- 5. Identity, keyed on Apple's genre id so a rename upstream does not
  --    fragment the concept.
  insert into ontology.concepts (id, concept_key)
  select extensions.gen_random_uuid(), p.concept_key
    from genre_plan p where p.disposition = 'mint'
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, p.name, 'genre',
         'Music genre as stated by the provider on the track; never inferred '
         || 'from a title.',
         'ordinary', 'inferable', 'active',
         jsonb_build_object('provider', 'apple_music_catalog', 'external_id', p.apple_id)
    from genre_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
   where p.disposition = 'mint'
  on conflict do nothing;

  -- **`alternate` as well as `preferred`.** Only those two auto-accept, and the
  -- resolver emits the bare genre string, which a prose `preferred` never meets.
  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, c.id, p.name, p.normalized, 'und',
         kind.label_type, 'external', 1.0, 'active',
         jsonb_build_object('provider', 'apple_music_catalog', 'external_id', p.apple_id)
    from genre_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
   cross join (values ('preferred'), ('alternate')) as kind(label_type)
   where p.disposition = 'mint'
  on conflict do nothing;

  -- 6. The parent. Apple's `parentId` resolved to whichever concept holds that
  --    id — ours where the genre was linked, the minted one otherwise — and
  --    `hub:music` for a top-level genre or one whose parent Apple names but
  --    does not expose.
  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select distinct new_version_id, child.id, 'broader', parent.id, 1.0, 'provider',
         jsonb_build_object('source', 'mint_genres',
                            'provider', 'apple_music_catalog',
                            'apple_parent_id', coalesce(p.parent_apple_id, '34')),
         'active'
    from genre_plan p
    join ontology.concepts child on child.concept_key = p.concept_key
    join lateral (
      select coalesce(
               (select coalesce(up.existing_concept_id, c2.id)
                  from genre_plan up
                  left join ontology.concepts c2 on c2.concept_key = up.concept_key
                 where up.apple_id = p.parent_apple_id),
               (select id from ontology.concepts where concept_key = 'hub:music')
             ) as id
    ) as parent on true
   where p.disposition = 'mint'
     and parent.id is not null
     and child.id <> parent.id
  on conflict do nothing;

  select count(distinct e.subject_concept_id) into parented
    from ontology.concept_edges e
   where e.ontology_version_id = new_version_id
     and e.predicate_key = 'broader'
     and e.provenance ->> 'source' = 'mint_genres';

  -- 7. Provenance, for the minted and the merely linked.
  insert into ontology.external_concept_links (
    ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, coalesce(p.existing_concept_id, c.id),
         p.entity_id, 'same_as', 1.0, 'active'
    from genre_plan p
    left join ontology.concepts c on c.concept_key = p.concept_key
   where p.disposition in ('mint', 'link')
     and coalesce(p.existing_concept_id, c.id) is not null
  on conflict do nothing;

  perform ontology.publish_version(new_version_id);

  select semantic_private.enqueue_recompute_on_analysis_change(
           'mint_genres: ' || next_version
         ) into enqueued;

  return jsonb_build_object(
    'stored', stored, 'minted', to_mint, 'linked', to_link,
    'refused', refused, 'parented', parented, 'published', true,
    'version', next_version, 'recomputes_enqueued', enqueued
  );
end;
$$;

revoke all on function semantic_private.mint_genres_from_catalogue(jsonb)
  from public, anon, authenticated;

commit;
