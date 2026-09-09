-- 0482 — a performer the provider credits is a performer.
--
-- **0481 stopped at the person.** A song is minted in its performer's
-- context, so a row whose performer resolves to nobody mints nothing — and
-- 2,075 of David's rows resolved nobody. Measured before writing: the
-- streaming source's first credit resolved to one creator for 317 names and
-- to none for 170, two of those names being works (a game's music released
-- under the game's name) and one carrying a stylised spelling the label
-- table held twice. The catalogue mint (0173) only ever minted the artists
-- the Apple catalogue named, so an act that arrives from the other source
-- alone — the indie names, the Mandarin and Cantonese acts the catalogue
-- fetch never saw — stood in the dictionary as an unpromoted person and
-- nowhere else.
--
-- **The credit is the provider's statement, and this mints from it.** Every
-- streaming row carries the credited artists as a list, first credit first;
-- the artist rows carry the provider's own artist identifier. The first
-- credit is read as stated ("Tyler, The Creator", which the split-on-comma
-- of 0481 had reduced to "Tyler") and resolved by one route, held in
-- `resolve_performer` and used from now on by the song mint as well:
--
--   1. exactly one active creator label under that spelling;
--   2. else exactly one creator the dictionary's person or group term
--      under that spelling is promoted to — "浅水ShallowEnd" promoted to
--      ShallowEnd, "ꉈꀧ꒒꒒ꁄꍈꍈꀧ꒦ꉈ ꉣꅔꎡꅔꁕꁄ" to Sheena Ringo, which the labels
--      alone could not settle;
--   3. else, for a two-word name, exactly one creator under the words in
--      the other order — "Leehom Wang" is Wang Leehom, "Sawano Hiroyuki"
--      is Hiroyuki Sawano.
--
-- A credit no route resolves is minted as a creator at provider
-- provenance, keyed on the provider's artist identifier where an artist
-- row states one and on the slug otherwise, with a `same_as` link to the
-- provider's entity. A credit that names a standing work is refused
-- (`would_collide`); a credit that is a placeholder — "Various Artists" —
-- is refused (`placeholder`); a spelling two creators share is refused
-- (`ambiguous`). The spelling the credit arrived under becomes an alternate
-- label wherever the label route did not already answer, so the resolver
-- answers by label next time; the dictionary's person and group terms under
-- that spelling are promoted to the concept, which is what the person
-- category pass (0477) and the reader read.
--
-- **The dictionary's name-order pairs fold.** Four unpromoted person terms
-- stood beside their own reversal (`miyawaki sakura` / `sakura miyawaki`).
-- The variant folds into the survivor — the promoted one, else the one a
-- creator label spells, else the earlier — through `canonical_term_id`, the
-- pointer every prior fold used. Nothing is deleted.
--
-- Then the song mint runs again under the new resolver, so the songs those
-- performers sang are minted in their context; that function publishes its
-- own version and enqueues its own recompute. Both routes are standing
-- functions, callable after any distillation. Replayable: every step
-- asserts its transformation and answers the same on an empty database.
begin;

-- ---------------------------------------------------------------------------
-- 1. One resolver for a performer credit.
-- ---------------------------------------------------------------------------
create or replace function semantic_private.resolve_performer(p_text text, p_version uuid)
returns uuid
language sql
stable
set search_path = ''
as $function$
  with n as (
    select btrim(regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9À-￿]+', ' ', 'g')) as pn),
  by_label as (
    select array_agg(distinct l.concept_id) as ids
      from n, ontology.concept_labels l
      join ontology.concept_revisions r
        on r.concept_id = l.concept_id and r.ontology_version_id = l.ontology_version_id
       and r.status = 'active' and r.concept_kind = 'creator'
     where l.ontology_version_id = p_version and l.status = 'active'
       and n.pn <> '' and l.normalized_label = n.pn),
  by_dict as (
    select array_agg(distinct pt.promoted_concept_id) as ids
      from n, semantic_private.presumed_terms pt
      join ontology.concept_revisions r
        on r.concept_id = pt.promoted_concept_id and r.ontology_version_id = p_version
       and r.status = 'active' and r.concept_kind = 'creator'
     where pt.family in ('person', 'group') and n.pn <> '' and pt.normalized_label = n.pn),
  by_reversed as (
    select array_agg(distinct l.concept_id) as ids
      from n, ontology.concept_labels l
      join ontology.concept_revisions r
        on r.concept_id = l.concept_id and r.ontology_version_id = l.ontology_version_id
       and r.status = 'active' and r.concept_kind = 'creator'
     where l.ontology_version_id = p_version and l.status = 'active'
       and array_length(string_to_array(n.pn, ' '), 1) = 2
       and l.normalized_label = split_part(n.pn, ' ', 2) || ' ' || split_part(n.pn, ' ', 1))
  select coalesce(
           case when cardinality(bl.ids) = 1 then bl.ids[1] end,
           case when cardinality(bd.ids) = 1 then bd.ids[1] end,
           case when cardinality(br.ids) = 1 then br.ids[1] end)
    from by_label bl, by_dict bd, by_reversed br;
$function$;

-- ---------------------------------------------------------------------------
-- 2. The performer mint, a standing route.
-- ---------------------------------------------------------------------------
create or replace function semantic_private.mint_performers_from_provider_credits()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  n_credits   integer := 0;
  n_link      integer := 0;
  n_mint      integer := 0;
  n_refused   integer := 0;
  n_labels    integer := 0;
  n_entities  integer := 0;
  n_promoted  integer := 0;
  refused     jsonb;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise exception 'mint_performers: no published ontology version';
  end if;

  -- 2a. Every distinct first credit the streaming source states, as stated.
  create temporary table _credits on commit drop as
  with credit as (
    -- The first credit, less a featured credit and anything after a pipe:
    -- "LiSA feat. Felix" is LiSA's record, and a joint credit is not a person.
    select btrim(split_part(regexp_replace(
             coalesce(o.normalized_payload -> 'credited_artists' ->> 0,
                      o.normalized_payload ->> 'primary_performer', ''),
             '\s+(feat|ft)\.?\s.*$', '', 'i'), '|', 1)) as text,
           o.user_id,
           nullif(btrim(o.normalized_payload ->> 'isrc'), '') as isrc
      from semantic_private.observations o
     where o.lifecycle_state = 'active' and o.source_code = 'spotify'),
  grouped as (
    select c.text, count(*) as support, count(distinct c.user_id) as users,
           array_remove(array_agg(distinct c.isrc), null) as isrcs
      from credit c where c.text <> '' group by c.text),
  keyed as (
    select g.*, btrim(regexp_replace(lower(g.text), '[^a-z0-9À-￿]+', ' ', 'g')) as pn
      from grouped g)
  select k.text, k.pn, k.support, k.users,
         -- The three label routes, then the recording: a credit whose ISRCs
         -- all name songs one standing creator performs is that creator
         -- under another spelling ("等一下就回家" is Deng1xiajiuhuijia).
         coalesce(semantic_private.resolve_performer(k.text, old_version_id),
                  (select case when count(distinct e.object_concept_id) = 1
                               then min(e.object_concept_id::text)::uuid end
                     from unnest(k.isrcs) as i
                     join ontology.external_entities ee
                       on ee.provider = 'apple_music_catalog' and ee.entity_kind = 'song' and ee.external_id = i
                     join ontology.external_concept_links x
                       on x.external_entity_id = ee.id and x.ontology_version_id = old_version_id and x.status = 'active'
                     join ontology.concept_edges e
                       on e.subject_concept_id = x.concept_id and e.ontology_version_id = old_version_id
                      and e.status = 'active' and e.predicate_key = 'performed_by'
                     join ontology.concept_revisions r
                       on r.concept_id = e.object_concept_id and r.ontology_version_id = old_version_id
                      and r.status = 'active' and r.concept_kind = 'creator')) as concept_id,
         (select array_agg(distinct d.item_id)
            from public.distilled_records d
           where d.source = 'spotify' and d.data_type in ('top_artist', 'followed_artist')
             and d.name = k.text and nullif(btrim(d.item_id), '') is not null) as provider_ids,
         (select string_agg(distinct r.concept_kind || coalesce('/' || (r.metadata ->> 'work_type'), ''), ',')
            from ontology.concept_labels l
            join ontology.concept_revisions r
              on r.concept_id = l.concept_id and r.ontology_version_id = old_version_id
             and r.status = 'active' and r.concept_kind <> 'creator'
           where l.ontology_version_id = old_version_id and l.status = 'active'
             and l.normalized_label = k.pn) as other_kinds,
         (select count(distinct l.concept_id)
            from ontology.concept_labels l
            join ontology.concept_revisions r
              on r.concept_id = l.concept_id and r.ontology_version_id = old_version_id
             and r.status = 'active' and r.concept_kind = 'creator'
           where l.ontology_version_id = old_version_id and l.status = 'active'
             and l.normalized_label = k.pn) as n_creator_labels,
         null::text as disposition
    from keyed k
   where k.pn <> '';

  update _credits set disposition =
    case
      when pn in ('various artists', 'unknown artist', 'unknown', 'anonymous',
                  'soundtrack', 'original soundtrack', 'traditional') then 'placeholder'
      when concept_id is not null then 'link'
      when n_creator_labels > 1 then 'ambiguous'
      when other_kinds is not null then 'would_collide'
      else 'mint'
    end;
  select count(*) into n_credits from _credits;
  select count(*) into n_link from _credits where disposition = 'link';
  select count(*) into n_refused from _credits where disposition in ('placeholder', 'ambiguous', 'would_collide');
  select coalesce(jsonb_agg(jsonb_build_object('credit', text, 'why', disposition, 'kinds', other_kinds)
                            order by support desc), '[]'::jsonb)
    into refused
    from _credits where disposition in ('ambiguous', 'would_collide');

  if not exists (select 1 from _credits where disposition = 'mint')
     and not exists (
       -- a linked credit whose spelling the label route does not yet answer
       select 1 from _credits c where c.disposition = 'link' and c.n_creator_labels <> 1)
     and not exists (
       select 1 from _credits c, unnest(c.provider_ids) as pid
        where c.disposition = 'link'
          and not exists (
            select 1 from ontology.external_concept_links x
            join ontology.external_entities e on e.id = x.external_entity_id
           where x.ontology_version_id = old_version_id and x.status = 'active'
             and x.concept_id = c.concept_id and e.provider = 'spotify' and e.external_id = pid))
  then
    -- Nothing to mint, label or link; only the dictionary may still owe a promotion.
    update semantic_private.presumed_terms pt
       set promoted_concept_id = c.concept_id, promoted_at = now()
      from _credits c
     where c.disposition = 'link' and pt.family in ('person', 'group')
       and pt.normalized_label = c.pn and pt.promoted_concept_id is null
       and pt.canonical_term_id is null;
    get diagnostics n_promoted = row_count;
    return jsonb_build_object('credits', n_credits, 'linked', n_link, 'minted', 0,
                              'refused', n_refused, 'dictionary_promoted', n_promoted,
                              'refusals', refused,
                              'note', 'every credit stands; no version published');
  end if;

  -- 2b. A new version.
  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Performers minted from the provider''s credits, linked to the provider''s artist ids.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- 2c. Mint. The key carries the provider's identifier where one is stated.
  insert into ontology.concepts (id, concept_key, created_at)
  select extensions.gen_random_uuid(),
         case when cardinality(c.provider_ids) = 1 then 'creator:spotify_' || c.provider_ids[1]
              else 'creator:' || semantic_private.song_key_slug(c.text) end,
         now()
    from _credits c
   where c.disposition = 'mint'
  on conflict (concept_key) do nothing;

  update _credits c
     set concept_id = k.id
    from ontology.concepts k
   where c.disposition = 'mint'
     and k.concept_key = case when cardinality(c.provider_ids) = 1 then 'creator:spotify_' || c.provider_ids[1]
                              else 'creator:' || semantic_private.song_key_slug(c.text) end;

  -- A key already carrying a revision at this version belongs to somebody
  -- else; two spellings that slug alike are one concept and only the first
  -- by support writes the revision.
  if exists (
    select 1 from _credits c
     where c.disposition = 'mint'
       and exists (select 1 from ontology.concept_revisions r
                    where r.concept_id = c.concept_id and r.ontology_version_id = new_version_id))
  then
    raise exception 'mint_performers: a credit''s key is already taken at the new version';
  end if;

  insert into ontology.concept_revisions
    (ontology_version_id, concept_id, preferred_label, concept_kind, definition,
     sensitivity, inference_policy, status, metadata)
  select distinct on (c.concept_id)
         new_version_id, c.concept_id, c.text, 'creator', null, 'ordinary', 'inferable', 'active',
         jsonb_build_object('origin', 'performer_mint_0482', 'provider', 'spotify',
                            'credit_basis', 'credited_artists',
                            'external_id', case when cardinality(c.provider_ids) = 1 then c.provider_ids[1] end,
                            'support', c.support, 'users', c.users)
    from _credits c
   where c.disposition = 'mint'
   order by c.concept_id, c.support desc, c.text;
  get diagnostics n_mint = row_count;

  -- 2d. Labels: the preferred one for a mint; the credit's spelling as an
  --     alternate wherever the label route did not answer it.
  insert into ontology.concept_labels
    (ontology_version_id, concept_id, label, normalized_label, locale, label_type,
     provenance_type, confidence, status)
  select new_version_id, c.concept_id, c.text, c.pn,
         case when c.text ~ '[^\x00-\x7F]' then 'und' else 'en' end,
         case when c.disposition = 'mint' then 'preferred' else 'alternate' end,
         'provider', 1.0, 'active'
    from _credits c
   where c.disposition in ('mint', 'link')
     and not exists (select 1 from ontology.concept_labels l
                      where l.ontology_version_id = new_version_id and l.status = 'active'
                        and l.concept_id = c.concept_id and l.normalized_label = c.pn)
  on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type) do nothing;
  get diagnostics n_labels = row_count;

  -- 2e. The provider's artist identity, as an external entity, linked.
  insert into ontology.external_entities
    (provider, external_id, label, entity_kind, raw_payload, payload_hash, license_code, retrieved_at)
  select 'spotify', pid, c.text, 'artist',
         jsonb_build_object('name', c.text, 'normalized', c.pn),
         md5(jsonb_build_object('name', c.text, 'normalized', c.pn)::text),
         'spotify_developer_terms', now()
    from _credits c, unnest(c.provider_ids) as pid
   where c.disposition in ('mint', 'link')
  on conflict (provider, external_id, payload_hash) do nothing;
  get diagnostics n_entities = row_count;

  insert into ontology.external_concept_links
    (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select distinct new_version_id, c.concept_id, e.id, 'same_as', 1.0, 'active'
    from _credits c, unnest(c.provider_ids) as pid
    join ontology.external_entities e on e.provider = 'spotify' and e.entity_kind = 'artist' and e.external_id = pid
   where c.disposition in ('mint', 'link')
  on conflict (ontology_version_id, concept_id, external_entity_id, link_type) do nothing;

  -- The transformation, asserted: every minted or linked credit resolves by
  -- label at the new version, to the concept it was given.
  if exists (
    select 1 from _credits c
     where c.disposition in ('mint', 'link')
       and (c.concept_id is null
            or not exists (
              select 1 from ontology.concept_labels l
              join ontology.concept_revisions r
                on r.concept_id = l.concept_id and r.ontology_version_id = new_version_id
               and r.status = 'active' and r.concept_kind = 'creator'
             where l.ontology_version_id = new_version_id and l.status = 'active'
               and l.concept_id = c.concept_id and l.normalized_label = c.pn)))
  then
    raise exception 'mint_performers: a credit stands without a creator it resolves to';
  end if;

  perform ontology.publish_version(new_version_id);

  -- 2f. The dictionary's person and group terms under the credit's spelling
  --     are promoted — after the publish, as the guard requires.
  update semantic_private.presumed_terms pt
     set promoted_concept_id = c.concept_id, promoted_at = now()
    from _credits c
   where c.disposition in ('mint', 'link') and pt.family in ('person', 'group')
     and pt.normalized_label = c.pn and pt.promoted_concept_id is null
     and pt.canonical_term_id is null;
  get diagnostics n_promoted = row_count;

  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || n_mint || ' performer(s) minted from the provider''s credits, '
    || n_link || ' linked, ' || n_labels || ' label(s), ' || n_entities || ' provider identit(ies), '
    || n_refused || ' refused');
  return jsonb_build_object('version', next_version, 'credits', n_credits, 'linked', n_link,
                            'minted', n_mint, 'labels', n_labels, 'provider_entities', n_entities,
                            'refused', n_refused, 'dictionary_promoted', n_promoted,
                            'refusals', refused);
end;
$function$;

do $$
declare result jsonb;
begin
  result := semantic_private.mint_performers_from_provider_credits();
  raise notice '0482 performers: %', result;
end $$;

-- ---------------------------------------------------------------------------
-- 3. The dictionary's name-order pairs fold.
-- ---------------------------------------------------------------------------
do $$
declare
  published uuid;
  folded integer;
begin
  select id into published from ontology.versions where status = 'published';

  create temporary table _pairs on commit drop as
  with pair as (
    select a.id as a_id, b.id as b_id,
           a.promoted_concept_id as a_p, b.promoted_concept_id as b_p,
           exists (select 1 from ontology.concept_labels l
                    join ontology.concept_revisions r
                      on r.concept_id = l.concept_id and r.ontology_version_id = published
                     and r.status = 'active' and r.concept_kind = 'creator'
                   where l.ontology_version_id = published and l.status = 'active'
                     and l.label_type = 'preferred' and l.normalized_label = a.normalized_label) as a_named,
           exists (select 1 from ontology.concept_labels l
                    join ontology.concept_revisions r
                      on r.concept_id = l.concept_id and r.ontology_version_id = published
                     and r.status = 'active' and r.concept_kind = 'creator'
                   where l.ontology_version_id = published and l.status = 'active'
                     and l.label_type = 'preferred' and l.normalized_label = b.normalized_label) as b_named,
           a.first_seen_at as a_seen, b.first_seen_at as b_seen
      from semantic_private.presumed_terms a
      join semantic_private.presumed_terms b
        on b.family = 'person' and b.id <> a.id and b.canonical_term_id is null
       and b.normalized_label = split_part(a.normalized_label, ' ', 2) || ' ' || split_part(a.normalized_label, ' ', 1)
     where a.family = 'person' and a.canonical_term_id is null
       and array_length(string_to_array(a.normalized_label, ' '), 1) = 2
       and a.id < b.id)
  select case when p.a_p is not null and p.b_p is null then p.a_id
              when p.b_p is not null and p.a_p is null then p.b_id
              when p.a_named and not p.b_named then p.a_id
              when p.b_named and not p.a_named then p.b_id
              when p.a_seen <= p.b_seen then p.a_id else p.b_id end as survivor,
         case when p.a_p is not null and p.b_p is null then p.b_id
              when p.b_p is not null and p.a_p is null then p.a_id
              when p.a_named and not p.b_named then p.b_id
              when p.b_named and not p.a_named then p.a_id
              when p.a_seen <= p.b_seen then p.b_id else p.a_id end as variant,
         coalesce(p.a_p, p.b_p) as concept_id
    from pair p
   where p.a_p is null or p.b_p is null or p.a_p = p.b_p;

  update semantic_private.presumed_terms v
     set canonical_term_id = p.survivor
    from _pairs p
   where v.id = p.variant;
  get diagnostics folded = row_count;

  update semantic_private.presumed_terms v
     set promoted_concept_id = p.concept_id, promoted_at = now()
    from _pairs p
   where v.id = p.variant and p.concept_id is not null and v.promoted_concept_id is null;

  -- The transformation, asserted: no unfolded person term is the reversal
  -- of another unfolded person term, unless both are promoted to different
  -- concepts — two people, not one.
  if exists (
    select 1 from semantic_private.presumed_terms a
    join semantic_private.presumed_terms b
      on b.family = 'person' and b.id <> a.id and b.canonical_term_id is null
     and b.normalized_label = split_part(a.normalized_label, ' ', 2) || ' ' || split_part(a.normalized_label, ' ', 1)
   where a.family = 'person' and a.canonical_term_id is null
     and array_length(string_to_array(a.normalized_label, ' '), 1) = 2
     and not (a.promoted_concept_id is not null and b.promoted_concept_id is not null
              and a.promoted_concept_id <> b.promoted_concept_id))
  then
    raise exception '0482: a person term still stands beside its own reversal';
  end if;
  raise notice '0482: % name-order variant(s) folded', folded;
end $$;

-- ---------------------------------------------------------------------------
-- 4. The song mint, under the one resolver; then run.
-- ---------------------------------------------------------------------------
create or replace function semantic_private.mint_songs_in_performer_context()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  n_rows          integer := 0;
  n_songs         integer := 0;
  n_matched       integer := 0;
  n_minted        integer := 0;
  n_links         integer := 0;
  n_composed      integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise exception 'mint_songs: no published ontology version';
  end if;

  -- 1. Every music row that names a title, with its performer resolved.
  create temporary table _song_rows on commit drop as
  with rows as (
    select o.id as observation_id, o.user_id,
           o.normalized_payload ->> 'title' as raw_title,
           nullif(btrim(o.normalized_payload ->> 'isrc'), '') as isrc,
           -- The first credit as the provider states it (0482): the credited
           -- list where the source keeps one, else the joined performer line.
           btrim(split_part(regexp_replace(
             coalesce(o.normalized_payload -> 'credited_artists' ->> 0,
                      o.normalized_payload ->> 'primary_performer', ''),
             '\s+(feat|ft)\.?\s.*$', '', 'i'), '|', 1)) as credit_full,
           btrim(split_part(split_part(split_part(split_part(
             coalesce(o.normalized_payload -> 'credited_artists' ->> 0,
                      o.normalized_payload ->> 'primary_performer', ''),
             '|', 1), ' & ', 1), ', ', 1), ' feat', 1)) as performer_text
      from semantic_private.observations o
     where o.lifecycle_state = 'active'
       and o.source_code in ('apple_music', 'music_library', 'spotify')
       and nullif(btrim(o.normalized_payload ->> 'title'), '') is not null),
  cleaned as (
    select r.*,
           btrim(regexp_replace(regexp_replace(r.raw_title,
             '\s*\((?:from|feat\.?|ft\.?|live|remaster|deluxe|acoustic|version|edit|mix|bonus|radio)[^)]*\)', '', 'gi'),
             '\s-\s(?:single|ep|live version|remastered|live|acoustic|radio edit)$', '', 'i')) as title
      from rows r),
  keyed as (
    select c.*,
           btrim(regexp_replace(lower(c.title), '[^a-z0-9À-￿]+', ' ', 'g')) as title_norm,
           btrim(regexp_replace(lower(c.performer_text), '[^a-z0-9À-￿]+', ' ', 'g')) as performer_norm
      from cleaned c
     where c.title <> '' and c.performer_text <> '')
  select k.*,
         -- The credit as stated first ("Tyler, The Creator"), then the split
         -- ("Tyler"); one resolver for every route (0482).
         coalesce(semantic_private.resolve_performer(k.credit_full, old_version_id),
                  semantic_private.resolve_performer(k.performer_text, old_version_id)) as performer_id
    from keyed k
   where k.title_norm <> '';

  select count(*) into n_rows from _song_rows where performer_id is not null;

  -- 2. One song per (performer, bare title); its display title is the most
  --    common cleaned spelling; its ISRCs are every identity it arrived under.
  create temporary table _songs on commit drop as
  select s.performer_id, s.title_norm,
         (select s2.title from _song_rows s2
           where s2.performer_id = s.performer_id and s2.title_norm = s.title_norm
           group by s2.title order by count(*) desc, s2.title limit 1) as title,
         array_remove(array_agg(distinct s.isrc), null) as isrcs,
         count(*) as support, count(distinct s.user_id) as users,
         null::uuid as concept_id, null::text as outcome
    from _song_rows s
   where s.performer_id is not null
   group by s.performer_id, s.title_norm;
  select count(*) into n_songs from _songs;

  -- 3. Match: a work under this label performed by this performer, or a work
  --    already linked to one of these ISRCs.
  update _songs s
     set concept_id = m.concept_id, outcome = 'matched'
    from (
      select s2.performer_id, s2.title_norm,
             (select l.concept_id
                from ontology.concept_labels l
                join ontology.concept_revisions r
                  on r.concept_id = l.concept_id and r.ontology_version_id = old_version_id
                 and r.status = 'active' and r.concept_kind = 'work'
                join ontology.concept_edges e
                  on e.subject_concept_id = l.concept_id and e.ontology_version_id = old_version_id
                 and e.status = 'active' and e.predicate_key = 'performed_by'
                 and e.object_concept_id = s2.performer_id
               where l.ontology_version_id = old_version_id and l.status = 'active'
                 and l.normalized_label = s2.title_norm
               limit 1) as concept_id
        from _songs s2) m
   where m.performer_id = s.performer_id and m.title_norm = s.title_norm
     and m.concept_id is not null;

  update _songs s
     set concept_id = x.concept_id, outcome = 'matched_isrc'
    from (
      select s2.performer_id, s2.title_norm,
             (select x.concept_id
                from ontology.external_concept_links x
                join ontology.external_entities e on e.id = x.external_entity_id
               where x.ontology_version_id = old_version_id and x.status = 'active'
                 and e.provider = 'apple_music_catalog' and e.entity_kind = 'song'
                 and e.external_id = any(s2.isrcs)
               limit 1) as concept_id
        from _songs s2 where s2.concept_id is null) x
   where x.performer_id = s.performer_id and x.title_norm = s.title_norm
     and x.concept_id is not null;
  select count(*) into n_matched from _songs where concept_id is not null;

  if not exists (select 1 from _songs where concept_id is null)
     and not exists (
       select 1 from _songs s, unnest(s.isrcs) as isrc
        where not exists (
          select 1 from ontology.external_concept_links x
          join ontology.external_entities e on e.id = x.external_entity_id
         where x.ontology_version_id = old_version_id and x.status = 'active'
           and x.concept_id = s.concept_id and e.external_id = isrc))
  then
    return jsonb_build_object('rows', n_rows, 'songs', n_songs, 'matched', n_matched,
                              'minted', 0, 'note', 'every song stands and is linked; no version published');
  end if;

  -- 4. A new version: mint what is missing, link every ISRC.
  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Songs minted in their performer''s context, linked to their ISRCs.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- The key carries the performer, because a title alone is not an identity.
  update _songs s
     set outcome = 'mint'
   where s.concept_id is null;

  insert into ontology.concepts (id, concept_key, created_at)
  select extensions.gen_random_uuid(),
         'work:' || semantic_private.song_key_slug(s.title) || '__' || semantic_private.song_key_slug(pr.preferred_label),
         now()
    from _songs s
    join ontology.concept_revisions pr
      on pr.concept_id = s.performer_id and pr.ontology_version_id = new_version_id and pr.status = 'active'
   where s.outcome = 'mint'
  on conflict (concept_key) do nothing;

  update _songs s
     set concept_id = c.id
    from ontology.concept_revisions pr, ontology.concepts c
   where s.outcome = 'mint'
     and pr.concept_id = s.performer_id and pr.ontology_version_id = new_version_id and pr.status = 'active'
     and c.concept_key = 'work:' || semantic_private.song_key_slug(s.title) || '__' || semantic_private.song_key_slug(pr.preferred_label);

  insert into ontology.concept_revisions
    (ontology_version_id, concept_id, preferred_label, concept_kind, definition,
     sensitivity, inference_policy, status, metadata)
  -- Two spellings that slug alike ("Love Me" / "love me!") share one concept;
  -- the first by support writes the revision and the other rides on it.
  select distinct on (s.concept_id)
         new_version_id, s.concept_id, s.title, 'work', null, 'ordinary', 'inferable', 'active',
         jsonb_build_object('origin', 'song_mint_0481', 'work_type', 'song',
                            'work_type_source', 'performer_context',
                            'performer_concept_id', s.performer_id,
                            'support', s.support, 'users', s.users)
    from _songs s
   where s.outcome = 'mint'
     and not exists (select 1 from ontology.concept_revisions r
                      where r.concept_id = s.concept_id and r.ontology_version_id = new_version_id)
   order by s.concept_id, s.support desc, s.title;
  get diagnostics n_minted = row_count;

  insert into ontology.concept_labels
    (ontology_version_id, concept_id, label, normalized_label, locale, label_type,
     provenance_type, confidence, status)
  select new_version_id, s.concept_id, s.title, s.title_norm,
         case when s.title ~ '[^\x00-\x7F]' then 'und' else 'en' end,
         'preferred', 'provider', 1.0, 'active'
    from _songs s
   where s.outcome = 'mint'
  on conflict (ontology_version_id, concept_id, locale, normalized_label, label_type) do nothing;

  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
     confidence, provenance_type, provenance, status)
  select new_version_id, s.concept_id, 'performed_by', s.performer_id, 0.9, 'provider',
         jsonb_build_object('source', 'song_mint_0481', 'basis', 'primary_performer'), 'active'
    from _songs s
   where s.outcome = 'mint'
  on conflict do nothing;

  -- A recording matched by its ISRC under a first credit it did not carry
  -- before is the same recording with another credited performer: the edge
  -- is recorded (0482), at the confidence of a credit rather than a mint.
  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
     confidence, provenance_type, provenance, status)
  select new_version_id, s.concept_id, 'performed_by', s.performer_id, 0.8, 'provider',
         jsonb_build_object('source', 'song_mint_0481', 'basis', 'isrc_identity'), 'active'
    from _songs s
   where s.outcome = 'matched_isrc'
     and not exists (select 1 from ontology.concept_edges e
                      where e.ontology_version_id = new_version_id and e.status = 'active'
                        and e.subject_concept_id = s.concept_id
                        and e.predicate_key = 'performed_by' and e.object_concept_id = s.performer_id)
  on conflict do nothing;

  -- The composer, where the catalogue's credit resolves to one person.
  insert into ontology.concept_edges
    (ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
     confidence, provenance_type, provenance, status)
  select distinct new_version_id, s.concept_id, 'composed_by', comp.concept_id, 0.8, 'provider',
         jsonb_build_object('source', 'song_mint_0481', 'basis', 'catalogue_composer'), 'active'
    from _songs s
    join lateral (
      select btrim(regexp_replace(lower(btrim(split_part(split_part(e.raw_payload ->> 'composerName', '&', 1), ',', 1))),
                                  '[^a-z0-9À-￿]+', ' ', 'g')) as composer_norm
        from ontology.external_entities e
       where e.provider = 'apple_music_catalog' and e.entity_kind = 'song'
         and e.external_id = any(s.isrcs)
         and nullif(btrim(e.raw_payload ->> 'composerName'), '') is not null
       order by e.retrieved_at desc limit 1) cn on cn.composer_norm <> ''
    join lateral (
      select l.concept_id, count(*) over () as n
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.concept_id = l.concept_id and r.ontology_version_id = new_version_id
         and r.status = 'active' and r.concept_kind = 'creator'
       where l.ontology_version_id = new_version_id and l.status = 'active'
         and l.normalized_label = cn.composer_norm
       limit 2) comp on comp.n = 1 and comp.concept_id <> s.performer_id
   where s.outcome = 'mint'
  on conflict do nothing;
  get diagnostics n_composed = row_count;

  insert into ontology.external_concept_links
    (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select distinct new_version_id, s.concept_id, e.id, 'same_as', 1.0, 'active'
    from _songs s
    join ontology.external_entities e
      on e.provider = 'apple_music_catalog' and e.entity_kind = 'song'
     and e.external_id = any(s.isrcs)
   where s.concept_id is not null
  on conflict (ontology_version_id, concept_id, external_entity_id, link_type) do nothing;
  get diagnostics n_links = row_count;

  -- The transformation, asserted.
  if exists (
    select 1 from _songs s
     where s.concept_id is null
        or not exists (select 1 from ontology.concept_edges e
                        where e.ontology_version_id = new_version_id and e.status = 'active'
                          and e.subject_concept_id = s.concept_id
                          and e.predicate_key = 'performed_by' and e.object_concept_id = s.performer_id))
  then
    raise exception 'mint_songs: a song stands without its performer: %',
      (select jsonb_agg(jsonb_build_object('title', s.title, 'outcome', s.outcome, 'performer', s.performer_id,
                'edges', (select jsonb_agg(pr.preferred_label) from ontology.concept_edges e join ontology.concept_revisions pr on pr.concept_id = e.object_concept_id and pr.ontology_version_id = new_version_id and pr.status='active' where e.ontology_version_id = new_version_id and e.status='active' and e.subject_concept_id = s.concept_id and e.predicate_key='performed_by')))
         from (select * from _songs s
                where s.concept_id is null
                   or not exists (select 1 from ontology.concept_edges e
                                   where e.ontology_version_id = new_version_id and e.status = 'active'
                                     and e.subject_concept_id = s.concept_id
                                     and e.predicate_key = 'performed_by' and e.object_concept_id = s.performer_id)
                limit 5) s);
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || n_minted || ' song(s) minted in their performer''s context, '
    || n_matched || ' matched, ' || n_links || ' ISRC link(s), ' || n_composed || ' composer edge(s)');
  return jsonb_build_object('version', next_version, 'rows', n_rows, 'songs', n_songs,
                            'matched', n_matched, 'minted', n_minted,
                            'isrc_links', n_links, 'composer_edges', n_composed);
end;
$function$;

do $$
declare result jsonb;
begin
  result := semantic_private.mint_songs_in_performer_context();
  raise notice '0482 songs: %', result;
end $$;

commit;
