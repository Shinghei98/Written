-- 0481 — a song is a term, minted in its performer's context.
--
-- **The owner's design (2026-09-09):** songs are terms — not terms shown on
-- Memories, but terms that evidence contributes to directly: an Apple Music
-- play, a Spotify save, a video of the song. The difficulty is identity: songs
-- share names, so a song is recognised in the context of its performer or
-- composer — extract the accurate person first, then match or mint the song
-- within that person.
--
-- **What stood in the way, each by design and each kept:** 0221 unminted the
-- 560 ISRC recordings because owning a track is not a trait (true, and the
-- page still hides a song's line under its singer's, 0437); the resolver
-- matches a title exactly, so "DISTANCE (Live Version)" never met "Distance"
-- (measured: 208 of David's 1,561 rows carry a decoration); the ISRC route
-- maps a row to a concept with no string matching at all and found nothing
-- for 724 of his 725 ISRCs, because nothing was linked. The pieces existed;
-- this connects them.
--
-- **The identity is (performer concept, bare title).** For every active music
-- row that names a title, the first credited performer is resolved to exactly
-- one creator concept by label (0173's disposition: an ambiguous name refuses).
-- The title is stripped of its decoration — `(From "…")`, `(feat. …)`,
-- `(Live Version)`, `- Single` — and the pair names one song, however many
-- ISRCs, live versions or remasters it arrives as. A song that already stands
-- (a work carrying a `performed_by` edge to that performer under that label,
-- or one already linked to one of the ISRCs) is matched; otherwise it is
-- minted: kind `work`, `work_type = song`, a `performed_by` edge to the
-- performer at provider provenance (it conducts, so the song's plays reach the
-- singer), a `composed_by` edge where the catalogue's composer credit resolves
-- to one person, and a `same_as` link to every ISRC entity — which is what
-- turns the resolver's ISRC route from an empty answer into a mapping.
--
-- Measured before writing: 1,696 rows resolve one performer, 911 distinct
-- songs among them, 830 ISRCs. 2,075 rows resolve no performer at all —
-- Spotify artists the catalogue mint never minted, name-order variants
-- (`Sawano Hiroyuki`) — and those rows mint nothing here, by the rule: no
-- person, no song. That gap is the performer's, and is the next thing owed.
--
-- The function is a standing route, run here once and callable again after
-- any distillation. Nothing is deleted; a version publishes; the recompute is
-- enqueued.
begin;

-- A slug the key rule can spell, for every script. `mint_slug` strips what is
-- not ASCII, so a Chinese or Japanese title slugs to nothing and every such
-- song by one performer collapsed into one key in the first dry run (357
-- ISRCs under `work:__jay_chou`). Where the slug is empty the key carries a
-- stable digest of the normalized text instead — legible as "a title the
-- slug cannot spell", never a collision.
create or replace function semantic_private.song_key_slug(p_text text)
returns text
language sql
immutable
set search_path = ''
as $function$
  select case when length(ontology.mint_slug(p_text)) >= 2 then ontology.mint_slug(p_text)
              else 'x' || left(md5(btrim(regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9À-￿]+', ' ', 'g'))), 12) end;
$function$;

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
           btrim(split_part(split_part(split_part(split_part(
             coalesce(o.normalized_payload ->> 'primary_performer', ''),
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
         (select (array_agg(distinct l.concept_id))[1]
            from ontology.concept_labels l
            join ontology.concept_revisions r
              on r.concept_id = l.concept_id and r.ontology_version_id = old_version_id
             and r.status = 'active' and r.concept_kind = 'creator'
           where l.ontology_version_id = old_version_id and l.status = 'active'
             and l.normalized_label = k.performer_norm) as performer_id,
         (select array_agg(distinct l.concept_id)
            from ontology.concept_labels l
            join ontology.concept_revisions r
              on r.concept_id = l.concept_id and r.ontology_version_id = old_version_id
             and r.status = 'active' and r.concept_kind = 'creator'
           where l.ontology_version_id = old_version_id and l.status = 'active'
             and l.normalized_label = k.performer_norm) as performers
    from keyed k
   where k.title_norm <> '';

  select count(*) into n_rows from _song_rows where cardinality(performers) = 1;

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
   where cardinality(s.performers) = 1
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
    raise exception 'mint_songs: a song stands without its performer';
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
  raise notice '0481: %', result;
end $$;

commit;
