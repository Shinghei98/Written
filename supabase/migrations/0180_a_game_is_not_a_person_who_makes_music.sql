-- 0180 — a game is not a person who makes music.
--
-- ## What is wrong today
--
-- `Where Winds Meet` is an eligible term on a real account, drawn as a creator,
-- at 0.474. It is a video game. `0177`'s mint turns every artist Apple's
-- catalogue names into a `creator` concept, and Apple lists a game soundtrack
-- under an "artist" named after the game — so the mint produced a person who
-- does not exist, and will keep producing one for every game, anime and film
-- soundtrack in anybody's library.
--
-- ## The signal, and the one that looks right and is not
--
-- **Not the artist's genre.** Apple answers `Where Winds Meet` with
-- `genreNames: ["Video Game"]`, which looks decisive until you ask it about the
-- other two artists carrying that genre (measured 2026-08-15): `Yida`, who
-- *composed* that soundtrack and is an eligible term on a real account at 0.424,
-- and `星戈音樂`, a studio. Routing on the genre turns a songwriter into a video
-- game.
--
-- **The album title, which names the game and nobody else.** Apple states:
--
--     albumName:    "When the Wind Rises (Where Winds Meet Original Game Soundtrack (Qinghe))"
--     artistName:   "Where Winds Meet & Yida"
--     composerName: "Yida"
--
-- So `game_titles_in` reads the name sitting before the soundtrack marker and
-- the mint routes the credit that *matches* it. `Where Winds Meet` matches and
-- becomes a work; `Yida` does not and stays a creator. This is a read of what
-- Apple printed, not a judgement about a name, and it is an allow-list: an album
-- that names no game routes nothing.
--
-- `albumName` costs no request — it is a field on the `filter[isrc]` response
-- already being made, which is the `part=` shape the extraction rule licenses.
-- Cached song rows stored before it was kept lack the key, so `missing_isrcs`
-- asks for those ISRCs once more and then never again; it is a key test rather
-- than a timestamp.
--
-- ## What this migration does beyond replacing the function
--
-- **`creator:apple_1849120613` already exists and is drawn on a page.** A new
-- lane cannot fix a concept already minted, and the mint would in fact refuse to
-- mint the work at all: `any_label` sees the creator's active label and answers
-- `would_collide`. So the correction is made here, in the shape `0158` set for a
-- concept minted wrongly — **the old concept keeps its id and its mappings, is
-- deprecated with its labels withheld, and the assertion resting on it is
-- retired `inactive`.** Nothing is deleted and no history is rewritten.
--
-- The work concept is minted here too rather than left for the next mint, so
-- that the page is correct at the end of this migration rather than at the end
-- of somebody's next distillation.
--
-- ## Version 0.23.0, and why a migration must publish it
--
-- `guard_published_version` makes a published version immutable — the same wall
-- `0179` met — so deprecating a label means copying the ontology forward. A
-- human migration takes the minor position; the next machine mint takes
-- `0.23.1`.

begin;

-- 1. The mint, with the game lane. Generated from the deployed
--    `0177` definition so that everything this does not change is
--    byte-identical to what is running.
CREATE OR REPLACE FUNCTION semantic_private.mint_vocabulary_from_catalogue(p_user_ids uuid[], p_songs jsonb DEFAULT '[]'::jsonb, p_artists jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  games_minted    integer := 0;
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
         e.raw_payload -> 'genres_normalized' as genres,
         coalesce((e.raw_payload ->> 'is_game')::boolean, false) as is_game
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
  ), existing_work as (
    select l.normalized_label,
           min(l.concept_id::text)::uuid as concept_id,
           count(distinct l.concept_id)  as concepts
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
      join ontology.concept_revisions r
        on r.ontology_version_id = v.id and r.concept_id = l.concept_id
     where l.status = 'active' and r.status = 'active'
       and r.concept_kind = 'work'
     group by l.normalized_label
  ), any_label as (
    select distinct l.normalized_label
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
     where l.status = 'active'
  )
  select c.apple_id, c.entity_id, c.name, c.normalized, c.genres, c.is_game,
         case when c.is_game then 'work:apple_' else 'creator:apple_' end
           || c.apple_id as concept_key,
         case when c.is_game then w.concept_id else e.concept_id end
           as existing_concept_id,
         case
           when a.normalized is not null      then 'ambiguous_catalogue'
           when (case when c.is_game then w.concepts else e.concepts end) > 1
                                              then 'ambiguous_vocabulary'
           when (case when c.is_game then w.concept_id else e.concept_id end)
                is not null                   then 'link'
           when o.normalized_label is not null then 'would_collide'
           else                                    'mint'
         end as disposition
    from mint_candidate c
    left join ambiguous a         on a.normalized = c.normalized
    left join existing_creator e  on e.normalized_label = c.normalized
    left join existing_work w     on w.normalized_label = c.normalized
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
  select gen_random_uuid(), p.concept_key
    from mint_plan p where p.disposition = 'mint'
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, p.name,
         case when p.is_game then 'work' else 'creator' end,
         null, 'ordinary', 'inferable', 'active',
         jsonb_build_object('provider', 'apple_music_catalog', 'external_id', p.apple_id)
    from mint_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
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
    join ontology.concepts c on c.concept_key = p.concept_key
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
    join ontology.concepts c on c.concept_key = p.concept_key
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
     and not p.is_game
     and c.id <> g.concept_id
  on conflict do nothing;

  -- **A game's parent is the games hub, not its stated genre.** `Video Game` is
  -- what Apple calls the genre of these entries, and taking it literally is what
  -- made a game look like a kind of music. `hub:games_play` is where
  -- `work:hearthstone` and its two siblings already sit.
  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select distinct new_version_id, c.id, 'broader', hub.id, 1.0, 'provider',
         jsonb_build_object('source', 'mint_vocabulary',
                            'provider', 'apple_music_catalog',
                            'basis', 'album_names_the_game'),
         'active'
    from mint_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
    join ontology.concepts hub on hub.concept_key = 'hub:games_play'
   where p.disposition = 'mint'
     and p.is_game
     and c.id <> hub.id
  on conflict do nothing;

  -- 6. Provenance, for the minted and the merely linked.
  insert into ontology.external_concept_links (
    ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, coalesce(p.existing_concept_id, c.id),
         p.entity_id, 'same_as', 1.0, 'active'
    from mint_plan p
    left join ontology.concepts c on c.concept_key = p.concept_key
   where p.disposition in ('mint', 'link')
     and coalesce(p.existing_concept_id, c.id) is not null
  on conflict do nothing;

  select count(*) into games_minted
    from mint_plan where disposition = 'mint' and is_game;

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
    'parented', parented, 'games', games_minted,
    'songs_stored', songs_stored,
    'artists_stored', artists_stored, 'published', true,
    'version', next_version, 'recomputes_enqueued', enqueued,
    'users', coalesce(array_length(p_user_ids, 1), 0)
  );
end;
$function$;

-- 2. The correction. `0158`'s shape: the wrongly minted concept keeps its id and
--    its mappings, is deprecated with its labels withheld so nothing resolves to
--    it again, and the assertion resting on it is retired `inactive` rather than
--    deleted. The work is minted here so the page is right at the end of this
--    migration rather than at the end of somebody's next distillation.
do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  wrong_concept   uuid;
  game_concept    uuid;
  hub_concept     uuid;
  source_edges    integer;
  copied_edges    integer;
  withheld        integer := 0;
  retired         integer := 0;
  labels_copied   integer := 0;
  enqueued        integer := 0;
  published_now   text;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception '0180: no published ontology version';
  end if;

  select id into wrong_concept
    from ontology.concepts where concept_key = 'creator:apple_1849120613';
  select id into hub_concept
    from ontology.concepts where concept_key = 'hub:games_play';
  if wrong_concept is null or hub_concept is null then
    raise exception '0180: expected creator:apple_1849120613 and hub:games_play to exist';
  end if;

  select count(*) into source_edges
    from ontology.concept_edges where ontology_version_id = old_version_id;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Where Winds Meet is a game: deprecate the minted creator, mint the '
          || 'work under hub:games_play. Copied forward from ' || current_version || '.');
  select id into new_version_id from ontology.versions where version = next_version;

  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy,
         case when r.concept_id = wrong_concept then 'deprecated' else r.status end,
         r.metadata
    from ontology.concept_revisions r
   where r.ontology_version_id = old_version_id
  on conflict do nothing;

  -- **Withheld, not deleted.** A deprecated label stops the resolver reaching
  -- the concept without pretending the concept never existed.
  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence,
         case when l.concept_id = wrong_concept then 'deprecated' else l.status end,
         l.external_ref
    from ontology.concept_labels l
   where l.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e
   where e.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.motif_rules (id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id, evidence_predicate_key, output_predicate_key, rule_kind, minimum_independence_groups, minimum_strength, configuration, status)
  select extensions.gen_random_uuid(), new_version_id, m.rule_key, m.evidence_target_concept_id, m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key, m.rule_kind, m.minimum_independence_groups, m.minimum_strength, m.configuration, m.status
    from ontology.motif_rules m
   where m.ontology_version_id = old_version_id
  on conflict do nothing;

  -- The work, keyed on the same Apple id the creator was keyed on: it is the
  -- same catalogue entry, read correctly.
  insert into ontology.concepts (id, concept_key)
  values (extensions.gen_random_uuid(), 'work:apple_1849120613')
  on conflict (concept_key) do nothing;
  select id into game_concept
    from ontology.concepts where concept_key = 'work:apple_1849120613';

  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, game_concept, r.preferred_label, 'work', null, 'ordinary', 'inferable', 'active',
         jsonb_build_object('provider', 'apple_music_catalog', 'external_id', '1849120613',
                            'basis', 'album_names_the_game')
    from ontology.concept_revisions r
   where r.ontology_version_id = old_version_id and r.concept_id = wrong_concept
  on conflict do nothing;

  -- **The labels are copied from the creator rather than retyped**, so the
  -- normalised form is the one `normalize_text` produced. A hand-written fold is
  -- how `0096` minted 35 concepts that could never resolve.
  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, game_concept, l.label, l.normalized_label, l.locale, l.label_type, 'external', 1.0, 'active', l.external_ref
    from ontology.concept_labels l
   where l.ontology_version_id = old_version_id and l.concept_id = wrong_concept
  on conflict do nothing;
  get diagnostics labels_copied = row_count;

  insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
  values (new_version_id, game_concept, 'broader', hub_concept, 1.0, 'provider',
          jsonb_build_object('source', 'mint_vocabulary', 'provider', 'apple_music_catalog',
                             'basis', 'album_names_the_game'),
          'active')
  on conflict do nothing;

  insert into ontology.external_concept_links (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, game_concept, e.id, 'same_as', 1.0, 'active'
    from ontology.external_entities e
   where e.provider = 'apple_music_catalog' and e.entity_kind = 'artist'
     and e.external_id = '1849120613'
  on conflict do nothing;

  update semantic_private.user_assertions
     set machine_state = 'inactive'
   where concept_id = wrong_concept and machine_state <> 'inactive';
  get diagnostics retired = row_count;

  -- 3. What must be true before this is published.
  select count(*) into copied_edges
    from ontology.concept_edges where ontology_version_id = new_version_id;
  if copied_edges <> source_edges + 1 then
    raise exception '0180: expected % edges (% carried forward plus the game''s parent), found %',
      source_edges + 1, source_edges, copied_edges;
  end if;

  select count(*) into withheld
    from ontology.concept_labels
   where ontology_version_id = new_version_id and concept_id = wrong_concept
     and status = 'active';
  if withheld <> 0 then
    raise exception '0180: % label(s) of the deprecated creator are still active', withheld;
  end if;

  if labels_copied = 0 then
    raise exception '0180: the work was minted with no label, which cannot resolve';
  end if;

  if not exists (
    select 1 from ontology.concept_edges
     where ontology_version_id = new_version_id
       and subject_concept_id = game_concept and predicate_key = 'broader'
       and object_concept_id = hub_concept
  ) then
    raise exception '0180: the game has no parent and would land under Other';
  end if;

  perform ontology.publish_version(new_version_id);

  select version into published_now from ontology.versions where status = 'published';
  if published_now is distinct from next_version then
    raise exception '0180: expected % published, found %', next_version, published_now;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': Where Winds Meet is a work, not a creator'
         ) into enqueued;

  raise notice '0180: % published, % label(s) withheld, % assertion(s) retired, % recompute job(s)',
    next_version, labels_copied, retired, enqueued;
end;
$$;

commit;
