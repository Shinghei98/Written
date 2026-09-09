-- 0480 — a franchise the grammar defines is a franchise.
--
-- 0476 let a franchise keep its category only when two categorised works
-- already pointed into it — a defence written against the pre-v7 habit of
-- calling everything a person belonged to a franchise. The owner (2026-09-08),
-- shown Persona 5, Sword Art Online and Barbie hidden as other: "they are
-- supposed to be franchise; they are work -> franchise." Under v7 the word
-- is defined (an integrated media IP spanning many works), the duplicate
-- screen drops the reflex answers, and the v24 corpus says franchise of
-- exactly those titles. The spanning rule was the wrong test for a defined
-- category, and it stood between the model's right answer and the page.
--
-- The rule now: a work standing as other becomes a franchise when a
-- franchise-family dictionary row under its name was seen by a v7-era
-- corpus — the threshold is derived, the moment the first row of a family
-- only v7 can say (song, movie, reality_show, podcast_show) entered the
-- dictionary — unless the same name is more strongly seen as an album or a
-- song (Midnights, Brat: the model's residual reflex, caught only within
-- one item by the screen) or is a genre the catalogue already holds
-- (Canto-pop). The classical containers the model also calls franchises
-- (Bach Cantatas, Beethoven Symphonies) become franchises here and stay
-- off the page by the reader's own music rule: a work whose composer
-- resolves is the composer's line. Measured before writing: 107 works,
-- 25 page rows across three users return.
begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  v7_since        timestamptz;
  n_back          integer := 0;
  n_album         integer := 0;
  n_genre         integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise notice '0480: no published version; nothing to re-sort';
    return;
  end if;

  -- The moment v7 vocabulary first entered the dictionary.
  select min(first_seen_at) into v7_since
    from semantic_private.presumed_terms
   where family in ('song', 'movie', 'reality_show', 'podcast_show');
  if v7_since is null then
    raise notice '0480: no v7-era corpus in the dictionary; nothing to read';
    return;
  end if;

  create temporary table _plan on commit drop as
  with others as (
    select r.concept_id, r.preferred_label,
           array(select distinct nl from (
                   select t.normalized_label as nl from semantic_private.presumed_terms t
                    where t.promoted_concept_id = r.concept_id
                   union select lower(btrim(r.preferred_label))
                   union select btrim(regexp_replace(lower(r.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g'))
                 ) x) as names
      from ontology.concept_revisions r
      join ontology.concepts c on c.id = r.concept_id and c.retired_at is null
     where r.ontology_version_id = old_version_id and r.status = 'active'
       and r.concept_kind = 'work' and r.metadata ->> 'work_type' = 'other'),
  judged as (
    select o.concept_id, o.preferred_label,
           (select max(coalesce(t.mention_support, 0) + coalesce(t.entry_support, 0))
              from semantic_private.presumed_terms t
             where t.normalized_label = any(o.names) and t.family = 'franchise'
               and t.last_seen_at >= v7_since) as franchise_support,
           (select max(coalesce(t.mention_support, 0) + coalesce(t.entry_support, 0))
              from semantic_private.presumed_terms t
             where t.normalized_label = any(o.names)
               and t.family in ('album', 'song', 'music_work', 'music_recording')) as recording_support,
           exists (select 1 from ontology.concept_revisions g
                     join ontology.concepts gc on gc.id = g.concept_id
                    where g.ontology_version_id = old_version_id and g.status = 'active'
                      and g.concept_kind = 'genre'
                      and btrim(regexp_replace(lower(g.preferred_label), '[^a-z0-9À-￿]+', ' ', 'g'))
                          = any(o.names)) as is_genre
      from others o)
  select concept_id, preferred_label, franchise_support, recording_support, is_genre,
         (franchise_support is not null
          and not is_genre
          and coalesce(recording_support, 0) <= franchise_support) as becomes_franchise
    from judged
   where franchise_support is not null;

  select count(*) filter (where becomes_franchise),
         count(*) filter (where not is_genre and coalesce(recording_support, 0) > franchise_support),
         count(*) filter (where is_genre)
    into n_back, n_album, n_genre from _plan;
  raise notice '0480: % become franchise; % stay other as recordings; % stay other as genres', n_back, n_album, n_genre;

  if n_back = 0 then
    raise notice '0480: nothing returns; no version published';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'A franchise the grammar defines is a franchise: v7-era franchise sightings count.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  update ontology.concept_revisions r
     set metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('work_type', 'franchise',
                                          'work_type_source', '0480_v7_franchise_sighting',
                                          'work_type_before', 'other')
    from _plan p
   where r.ontology_version_id = new_version_id and r.status = 'active'
     and r.concept_id = p.concept_id and p.becomes_franchise;

  if exists (
    select 1 from ontology.concept_revisions r join _plan p on p.concept_id = r.concept_id
     where r.ontology_version_id = new_version_id and r.status = 'active'
       and p.becomes_franchise and r.metadata ->> 'work_type' <> 'franchise')
  then
    raise exception '0480: a franchise the corpus named still stands as other';
  end if;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || n_back || ' franchise(s) the v7 corpus named return from other');
  raise notice '0480: % published — % franchise(s) returned', next_version, n_back;
end $$;

commit;
