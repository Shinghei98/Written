-- 0190 — a term reads as its genre.
--
-- ## The two things the owner asked for, and why neither worked
--
-- **"Taylor Swift should be POP."** She already reaches `genre:pop`; the graph
-- was never wrong. `concept_block` returns the nearest of thirteen *authored*
-- blocks and `genre:pop` is not one of them, so she fell past all thirteen to
-- the `hub:music` fallback and read MUSIC.
--
-- **"ONE OK ROCK should be its genre."** It had no genre parent at all.
-- `creator:one_ok_rock` is a seed concept parented to `hub:music`, and the
-- catalogue mint *linked* it rather than minting it — and the mint wrote a
-- `broader` edge only for `disposition = 'mint'`. One mint linked 550 concepts
-- for a single account; every one kept whatever parent it was born with, and
-- Apple's stated genres for them were discarded.
--
-- Apple calls ONE OK ROCK **Rock**, at artist level and on all twenty songs
-- sampled — not J-Pop. The owner settled it: *"rock is fine"*. That also matches
-- what our genre concepts already claim about themselves — *"as stated by the
-- provider; never inferred"* — so no override layer exists.
--
-- ## Three changes
--
-- **1. `concept_block` gains a tier rather than losing its list.** The first
-- draft of this replaced the thirteen authored blocks with "nearest genre", and
-- that is wrong: priority beats depth there deliberately, so an anime singer
-- reaching both `genre:anime` (priority 1) and `genre:j_pop` (nearer) reads
-- ANIME. `0154` and `0157` chose those thirteen and their order, and depth-first
-- would overturn every one of those judgements silently. So the order is now:
-- authored block, then **nearest `genre:*` ancestor**, then the hub fallback.
-- The new tier needs no maintenance as Apple's tree grows, which is the point —
-- `0188` just added 37 genres and the next library will name more.
--
-- `genre:asian_music` is excluded from the new tier: `0164` calls it *"a
-- concept at 0.942 that is a container in all but name"*, parent of four genres
-- it is scored alongside, and a heading reading ASIAN MUSIC over a K-pop artist
-- is the coarseness `0162` already had to repair once.
--
-- **2. The mint parents a linked concept.** Two bugs in one statement: it
-- joined `ontology.concepts` on `creator:apple_<id>`, a key that is never
-- created for a link, and it filtered `disposition = 'mint'`. Now it resolves
-- the linked concept's own id and offers the catalogue's genres to any concept
-- that reaches **no genre at all** — never to one somebody already parented,
-- because our `genre:j_pop` under both `genre:pop` and `genre:asian_music` is a
-- judgement Apple's flat answer would dilute.
--
-- **3. The same repair, applied to what is already there.** The mint only runs
-- when somebody distils, and every linked concept in the vocabulary is missing
-- its parent today. That backfill needs no network: the catalogue rows are
-- already in `ontology.external_entities`, so this is a set operation over data
-- the database holds.

begin;

-- 1. The block, with a genre tier between the authored list and the hub.
create or replace function semantic_private.concept_block(
  target_concept_id uuid, target_version_id uuid)
returns text
language sql
stable
set search_path to ''
as $function$
  with recursive blocks(block_key, priority) as (
    values
      ('genre:anime', 1), ('genre:classical', 2), ('genre:musicals', 3),
      ('genre:k_pop', 4), ('genre:j_pop', 5), ('genre:mandopop', 6),
      ('genre:cantopop', 7), ('genre:video_game', 8), ('subject:science', 9),
      ('subject:language_learning', 10), ('hub:news_current_affairs', 11),
      ('subject:travel', 12), ('subject:content_creators', 13)
  ),
  climb(concept_id, depth) as (
    select target_concept_id, 0
    union all
    select edge.object_concept_id, climb.depth + 1
    from climb
    join ontology.concept_edges edge
      on edge.subject_concept_id = climb.concept_id
     and edge.predicate_key = 'broader'
     and edge.ontology_version_id = target_version_id
     and edge.status = 'active'
    where climb.depth < 8
  )
  select coalesce(
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
       join blocks b on b.block_key = c.concept_key
      order by b.priority, climb.depth, c.concept_key
      limit 1),
    -- The new tier: nearest genre by depth, containers excluded.
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
      where c.concept_key like 'genre:%'
        and c.concept_key <> 'genre:asian_music'
      order by climb.depth, c.concept_key
      limit 1),
    (select c.concept_key
       from climb
       join ontology.concepts c on c.id = climb.concept_id
      where c.concept_key like 'hub:%'
      order by climb.depth, c.concept_key
      limit 1)
  );
$function$;

-- 2. The mint, parenting linked concepts. Generated from the deployed `0180`
--    definition so everything this does not change is byte-identical.
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
  select distinct new_version_id, subject.id, 'broader', g.concept_id, 1.0, 'provider',
         jsonb_build_object('source', 'mint_vocabulary', 'provider', 'apple_music_catalog'),
         'active'
    from mint_plan p
    -- **The linked concept's own id, not one derived from a key that does not
    -- exist.** A `link` keeps our concept, so `creator:apple_<id>` was never
    -- created for it and the old join found nothing — which is one half of why
    -- a linked concept never gained a parent.
    join lateral (
      select coalesce(
               p.existing_concept_id,
               (select id from ontology.concepts where concept_key = p.concept_key)
             ) as id
    ) as subject on true
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
   where p.disposition in ('mint', 'link')
     and not p.is_game
     and subject.id is not null
     and subject.id <> g.concept_id
     -- **A concept somebody already parented keeps its parents.** Ours put
     -- `genre:j_pop` under both `genre:pop` and `genre:asian_music`, which is a
     -- judgement Apple's flat answer would dilute. So the catalogue's genres are
     -- offered only to a concept that reaches no genre at all — which is what
     -- `ONE OK ROCK` was: a seed concept parented to `hub:music` and nothing
     -- else, linked by every mint and given a parent by none of them.
     and not exists (
       select 1
         from ontology.concept_edges prior
         join ontology.concepts parent on parent.id = prior.object_concept_id
        where prior.subject_concept_id = subject.id
          and prior.ontology_version_id = new_version_id
          and prior.predicate_key = 'broader'
          and prior.status = 'active'
          and parent.concept_key like 'genre:%'
     )
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

-- 3. The backfill: every creator already linked to a catalogue artist, with no
--    genre parent, gains the genres Apple states for it.
do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  source_edges    integer;
  added           integer;
  enqueued        integer;
  block_taylor    text;
  block_oor       text;
  block_bach      text;
  block_kripp     text;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  select count(*) into source_edges
    from ontology.concept_edges where ontology_version_id = old_version_id;

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Linked creators gain the genres the catalogue states for them.');
  select id into new_version_id from ontology.versions where version = next_version;

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

  -- **Every link this ontology has ever held, not only the current version's.**
  -- `external_concept_links` is the record of which concept a catalogue entity
  -- became, and it is *not* carried by a copy-forward unless the migration says
  -- so — `0179` did not, and `0180` did not, so 0.22.2's **550** links became
  -- **1** at 0.23.0 and the provenance of every minted and linked artist was
  -- destroyed. Nothing raised: a copy-forward that drops a table simply produces
  -- a version where it is empty.
  --
  -- So this takes the union across every version, deduplicated by the natural
  -- key, which restores the 550 and makes the current version the complete one.
  -- The backfill below then has something to join to; without it, this migration
  -- matched nothing and said so, which is how the loss was found.
  insert into ontology.external_concept_links (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select distinct on (x.concept_id, x.external_entity_id, x.link_type)
         new_version_id, x.concept_id, x.external_entity_id, x.link_type, x.confidence, x.status
    from ontology.external_concept_links x
    join ontology.versions v on v.id = x.ontology_version_id
   order by x.concept_id, x.external_entity_id, x.link_type, v.created_at desc
  on conflict do nothing;

  -- The repair itself. `external_concept_links` is what says which concept a
  -- catalogue artist became — for a linked concept that is the only record of
  -- the connection, since its key carries no Apple id.
  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select distinct new_version_id, link.concept_id, 'broader', g.concept_id, 1.0, 'provider',
         jsonb_build_object('source', 'mint_vocabulary',
                            'provider', 'apple_music_catalog',
                            'basis', 'backfill_0190'),
         'active'
    from ontology.external_concept_links link
    join ontology.external_entities entity
      on entity.id = link.external_entity_id
     and entity.provider = 'apple_music_catalog'
     and entity.entity_kind = 'artist'
    join ontology.concept_revisions subject
      on subject.concept_id = link.concept_id
     and subject.ontology_version_id = new_version_id
     and subject.status = 'active'
     and subject.concept_kind in ('creator', 'organization')
   cross join lateral jsonb_array_elements_text(
      coalesce(entity.raw_payload -> 'genres_normalized', '[]'::jsonb)) as stated(genre)
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
   where link.ontology_version_id = new_version_id
     and link.concept_id <> g.concept_id
     and not exists (
       select 1
         from ontology.concept_edges prior
         join ontology.concepts parent on parent.id = prior.object_concept_id
        where prior.subject_concept_id = link.concept_id
          and prior.ontology_version_id = new_version_id
          and prior.predicate_key = 'broader'
          and prior.status = 'active'
          and parent.concept_key like 'genre:%'
     )
  on conflict do nothing;
  get diagnostics added = row_count;

  if added = 0 then
    raise exception '0190: no linked creator gained a parent, which is not the measured state';
  end if;

  perform ontology.publish_version(new_version_id);

  -- 4. What must be true, read through the function itself rather than by
  --    inspecting edges — the heading is what was complained about.
  select semantic_private.concept_block(c.id, new_version_id) into block_taylor
    from ontology.concepts c where c.concept_key = 'creator:apple_159260351';
  select semantic_private.concept_block(c.id, new_version_id) into block_oor
    from ontology.concepts c where c.concept_key = 'creator:one_ok_rock';

  if block_taylor is distinct from 'genre:pop' then
    raise exception '0190: Taylor Swift blocks as %, expected genre:pop', block_taylor;
  end if;
  if block_oor is distinct from 'genre:rock' then
    raise exception '0190: ONE OK ROCK blocks as %, expected genre:rock', block_oor;
  end if;

  -- **And the judgements the authored list exists to protect still hold.**
  -- These are `0154`'s own assertions, re-run because a new tier beneath them is
  -- exactly the change that could quietly outrank them.
  select semantic_private.concept_block(c.id, new_version_id) into block_bach
    from ontology.concepts c where c.concept_key = 'creator:johann_sebastian_bach';
  if block_bach is not null and block_bach is distinct from 'genre:classical' then
    raise exception '0190: Bach blocks as %, expected genre:classical', block_bach;
  end if;

  select semantic_private.concept_block(c.id, new_version_id) into block_kripp
    from ontology.concepts c where c.concept_key = 'creator:kripparrian';
  if block_kripp is not null and block_kripp is distinct from 'subject:content_creators' then
    raise exception '0190: Kripparrian blocks as %, expected subject:content_creators',
      block_kripp;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': linked creators reach their genre'
         ) into enqueued;

  raise notice '0190: % published, % parent edge(s) added, Taylor=%, ONE OK ROCK=%, % recompute job(s)',
    next_version, added, block_taylor, block_oor, enqueued;
end;
$$;

commit;
