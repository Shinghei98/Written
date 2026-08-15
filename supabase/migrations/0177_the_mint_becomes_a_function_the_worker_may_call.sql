-- 0177 — the mint becomes a function the worker may call.
--
-- ## What this is
--
-- `0173` mints creator concepts from Apple's catalogue as a one-shot migration:
-- a human runs `tools/apple_catalog.py`, applies the SQL, and a new user's
-- artists become terms. `0176` arms a `mint_vocabulary` job when somebody
-- distils. This is the piece between them — the same minting logic as a callable
-- function, so the thing that runs it can be a worker rather than a person.
--
-- **`0173` is superseded and need not be applied.** It stays in history as the
-- design record and the place the reasoning is written down, but its inline
-- block and this function are the same logic, and two copies of minting SQL is
-- exactly the drift this codebase keeps paying for. Apply one of them. If `0173`
-- has already run, this function simply finds those artists already minted and
-- links rather than duplicating.
--
-- ## Why the worker cannot do this itself
--
-- `semantic_worker` holds no insert on any `ontology` table and `0070` asserts
-- it cannot publish a version. That is a safety property worth keeping: the
-- thing reachable from a queue should not be able to rewrite shared vocabulary
-- at will. So the worker fetches from Apple and hands the answers to this
-- `security definer` function, which is the only thing that writes. The
-- assertion at the foot re-checks that the worker gained nothing directly.
--
-- ## Version numbering, and what the number tells you
--
-- **A machine mint takes the patch position.** The published version moves
-- `0.22.0` → `0.22.1` → `0.22.2`, while a human migration takes the next minor.
-- So the number says who minted it without anybody having to look it up, and a
-- run of automatic mints cannot collide with a migration somebody is writing.
--
-- ## Nothing to mint publishes nothing
--
-- `0176` arms a job on every distillation with no coverage gate, which is the
-- owner's decision and the right one — a threshold tuned on two accounts is a
-- guess. The cost of that decision is paid here instead: if the catalogue names
-- no artist this vocabulary lacks, the function returns before minting a version
-- at all. **The gate is at mint time, where the answer is known, rather than at
-- arm time, where it is not.**
--
-- Publishing is not cheap — copy-forward is the whole ontology, ~6,143 rows at
-- 0.21.0, and every publish invalidates every user's run identity and forces a
-- fresh run each. That is the reason the function takes an *array* of users: one
-- pass over everybody currently due produces one version, not one each.

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

revoke all on function semantic_private.mint_vocabulary_from_catalogue(uuid[], jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function semantic_private.mint_vocabulary_from_catalogue(uuid[], jsonb, jsonb)
  to semantic_worker;

do $$
declare
  granted boolean;
  result  jsonb;
begin
  -- The worker may call the mint and still may not write vocabulary itself.
  -- `0070` asserts the second; this re-asserts it beside the grant that could
  -- have quietly undone it.
  select has_function_privilege(
           'semantic_worker',
           'semantic_private.mint_vocabulary_from_catalogue(uuid[], jsonb, jsonb)',
           'execute') into granted;
  if not granted then
    raise exception '0177: semantic_worker cannot call the mint';
  end if;

  select has_table_privilege('semantic_worker', 'ontology.concepts', 'insert') into granted;
  if granted then
    raise exception '0177: semantic_worker gained a direct write on ontology.concepts';
  end if;
  select has_table_privilege('semantic_worker', 'ontology.concept_labels', 'insert') into granted;
  if granted then
    raise exception '0177: semantic_worker gained a direct write on ontology.concept_labels';
  end if;
  select has_table_privilege('semantic_worker', 'ontology.versions', 'update') into granted;
  if granted then
    raise exception '0177: semantic_worker can publish an ontology version';
  end if;
  select has_function_privilege('semantic_ingestor',
           'semantic_private.mint_vocabulary_from_catalogue(uuid[], jsonb, jsonb)',
           'execute') into granted;
  if granted then
    raise exception '0177: semantic_ingestor may call the mint';
  end if;

  -- **Nothing to mint must publish nothing.** This is the no-gate decision paid
  -- for: a distillation that turns up no new artist arms a job, and the job must
  -- not cost a version. Proved rather than asserted, because the early return is
  -- the only thing standing between "arm on every distillation" and a version
  -- per distillation.
  --
  -- **Run inside a subtransaction that is always rolled back.** If the catalogue
  -- dump has already been applied there *are* artists waiting, and an
  -- unprotected probe would mint them and publish a version as a side effect of
  -- running a migration — the check would cause the very thing it is checking
  -- for. PL/pgSQL variables survive the rollback; rows do not.
  begin
    result := semantic_private.mint_vocabulary_from_catalogue(array[]::uuid[]);
    raise exception 'rollback_the_probe';
  exception when others then
    if sqlerrm <> 'rollback_the_probe' then
      raise;
    end if;
  end;

  if result is null then
    raise exception '0177: the mint returned nothing at all';
  end if;
  if (result ->> 'minted')::integer = 0 and (result ->> 'published')::boolean then
    raise exception '0177: a mint with nothing to mint still published a version';
  end if;
  raise notice '0177: probe rolled back — %', result::text;
end;
$$;

commit;
