-- 0476 — every standing work into the eleven, or other.
--
-- The re-sort 0472 deliberately left for after the v7 corpus. The order
-- was the point: the dictionary had filed Persona 5, Barbie and Bleach as
-- "franchise" because that was all the old prompt could say, and reading
-- it back before v24 entered (0474) would have darkened 477 of 837 works.
-- With v24 in, 26 of those find their category — Chungking Express and
-- Wicked are movies, Sword Art Online and Attack on Titan are anime — and
-- the rest are what the owner's definition says they are: titled things
-- that fit none of the eleven, kept as evidence, never shown.
--
-- The reading, per work, in order: a wikidata-typed category stands
-- (recording and music_work become song, film becomes movie, tv_show
-- becomes reality_show; tv_series, anime, album, documentary, book,
-- podcast_show and game stand); else the dictionary's most-supported
-- category under the work's name (0469's reading: the promoted rows plus
-- both normalizations); else, for a franchise mint, the spanning rule —
-- at least two distinct categorised works with `part_of_franchise` into
-- it, which today one concept satisfies (One Piece, nine works in); else
-- other. Measured in a rolled-back run against 0.41.34 with v24 in, and
-- approved by the owner on 2026-09-08 with the list in front of them:
-- 448 of 837 works become other; 39 inferred assertions across three
-- users leave the page (Bleach, Fate/Zero, Solo Leveling, Persona 5 and
-- the two Bach passions among David's fourteen), because the model, even
-- under v7, called each a franchise and no work points into them. They
-- return the moment a corpus names their category or their own works
-- point in. The MCU concept falls to other on the same rule.
--
-- The page reads a work's type at the version its score was computed at,
-- so the rows go dark on each person's next recompute, which this
-- enqueues. Nothing is deleted and no score's inputs move.
begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  bucket          record;
  n_total         integer := 0;
  n_other         integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise notice '0476: no published version; nothing to re-sort';
    return;
  end if;

  -- What the dictionary saw under each work's name (0469's reading: the
  -- rows promoted to it plus both normalizations), mapped onto the eleven.
  -- A wikidata-typed category stands first; the dictionary's most-supported
  -- category next; the spanning rule for franchise; else other.
  create temporary table _works on commit drop as
  select r.concept_id, r.preferred_label, r.metadata ->> 'work_type' as before,
         array(select distinct nl from (
                 select t.normalized_label as nl from semantic_private.presumed_terms t
                  where t.promoted_concept_id = r.concept_id
                 union select lower(btrim(r.preferred_label))
                 union select btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g'))
               ) x) as names
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id and c.retired_at is null
   where r.ontology_version_id = old_version_id and r.status = 'active'
     and r.concept_kind = 'work';

  create temporary table _plan on commit drop as
  with seen as (
    select w.concept_id,
           case t.family
             when 'music_work' then 'song' when 'song' then 'song'
             when 'movie' then 'movie'
             when 'tv_show' then 'reality_show' when 'reality_show' then 'reality_show'
             when 'tv_series' then 'tv_series' when 'anime' then 'anime'
             when 'album' then 'album' when 'documentary' then 'documentary'
             when 'book' then 'book' when 'podcast_show' then 'podcast_show'
             when 'game' then 'game'
           end as category,
           coalesce(t.mention_support, 0) + coalesce(t.entry_support, 0) as support
      from _works w
      join semantic_private.presumed_terms t on t.normalized_label = any(w.names)),
  dictionary as (
    select distinct on (concept_id) concept_id, category
      from seen where category is not null and support > 0
     order by concept_id, support desc,
              array_position(array['anime','game','book','album','song','movie','tv_series',
                                   'reality_show','documentary','podcast_show'], category)),
  spanning as (
    select w.concept_id
      from _works w
     where w.before = 'franchise'
       and (select count(distinct e.subject_concept_id)
              from ontology.concept_edges e
              join ontology.concept_revisions s
                on s.concept_id = e.subject_concept_id
               and s.ontology_version_id = old_version_id and s.status = 'active'
               and s.concept_kind = 'work'
               and s.metadata ->> 'work_type' in ('recording', 'music_work', 'song', 'film', 'movie',
                                                  'tv_series', 'anime', 'album', 'tv_show',
                                                  'reality_show', 'documentary', 'book',
                                                  'podcast_show', 'game')
             where e.ontology_version_id = old_version_id and e.status = 'active'
               and e.predicate_key = 'part_of_franchise'
               and e.object_concept_id = w.concept_id) >= 2)
  select w.concept_id, w.preferred_label, w.before,
         case
           when w.before in ('recording', 'music_work', 'song') then 'song'
           when w.before in ('film', 'movie') then 'movie'
           when w.before in ('tv_show', 'reality_show') then 'reality_show'
           when w.before in ('tv_series', 'anime', 'album', 'documentary',
                             'book', 'podcast_show', 'game') then w.before
           when d.category is not null then d.category
           when sp.concept_id is not null then 'franchise'
           else 'other'
         end as after
    from _works w
    left join dictionary d on d.concept_id = w.concept_id
    left join spanning sp on sp.concept_id = w.concept_id;

  for bucket in
    select coalesce(before, '(none)') as before, after, count(*) as n
      from _plan group by 1, 2 order by 3 desc
  loop
    raise notice '0476: % -> % : %', bucket.before, bucket.after, bucket.n;
  end loop;

  if not exists (select 1 from _plan where before is distinct from after) then
    raise notice '0476: every work already carries a closed category; no version published';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'The categories of work are closed: eleven, or other.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  update ontology.concept_revisions r
     set metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('work_type', p.after,
                                          'work_type_source', '0476_closed_categories',
                                          'work_type_before', coalesce(p.before, 'none'))
    from _plan p
   where r.ontology_version_id = new_version_id and r.status = 'active'
     and r.concept_id = p.concept_id
     and p.before is distinct from p.after;

  select count(*), count(*) filter (where after = 'other') into n_total, n_other from _plan;

  if exists (
    select 1 from ontology.concept_revisions r
     where r.ontology_version_id = new_version_id and r.status = 'active'
       and r.concept_kind = 'work'
       and coalesce(r.metadata ->> 'work_type', '') not in
           ('song', 'movie', 'tv_series', 'anime', 'album', 'reality_show', 'documentary',
            'book', 'podcast_show', 'game', 'franchise', 'other'))
  then
    raise exception '0476: a work still stands outside the closed categories';
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': the categories of work are closed — '
    || n_total || ' work(s) sorted, ' || n_other || ' now other and hidden');
  raise notice '0476: % published — % work(s) sorted, % other', next_version, n_total, n_other;
end $$;


commit;
