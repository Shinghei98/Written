-- 0401 — a song is not an anime, and an episode is not a term.
--
-- **The owner's two rulings, 2026-08-26:**
--
-- 1. **The Anime card holds works and franchises only.** A song's
--    anime-ness is a relation, not a home: Aqua Timez's "Niji" is a
--    J-Pop song that an anime used, and it files through its performer.
--    Mechanically: a work carrying an active `performed_by` to a music
--    creator must not carry `broader` into a content genre (anime or
--    the screen genres) — those edges came from the dictionary bridge
--    promoting the source's "Anime" shelf-label wholesale. Each such
--    edge is rejected; where the work also states a franchise/work tie
--    (`part_of_franchise` to an anime-blocked work), the tie is restated
--    as `soundtrack_of` — the predicate the registry already carries for
--    exactly this fact (λ 0.25) — so the anime connection survives as a
--    relation while the filing follows the performer.
--
-- 2. **An episode number is not a durable subject.** "Episode 25" minted
--    as a work from a liked variety-show video, wearing two guessed
--    genres. The grammar's own answer is `no_durable_subject`; the
--    repair is 0379's shadow retirement: the concept's revision retires
--    at the new version, so the kind lookup fails the page's allowlist
--    and the row leaves every surface while evidence and history stand
--    untouched. Scoped by shape, not by name: a work whose whole title
--    is an episode marker (EP/Episode + digits, latin or CJK forms) and
--    which carries no work_in_collection/soundtrack_of identity of its
--    own.
--
-- Ends with the recompute enqueue (0396's rule).

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  songs_ungenred integer := 0;
  ties_restated integer := 0;
  fragments_retired integer := 0;
  guesses_superseded integer := 0;
  reads_placed integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- The performed works wearing content genres.
  create temporary table _songs on commit drop as
  select distinct c.id as concept_id, c.concept_key
    from ontology.concepts c
   where exists (
       select 1 from ontology.concept_edges pe
        where pe.subject_concept_id = c.id
          and pe.ontology_version_id = old_version_id
          and pe.status = 'active' and pe.predicate_key = 'performed_by')
     and exists (
       select 1 from ontology.concept_edges ge
         join ontology.concepts g on g.id = ge.object_concept_id
        where ge.subject_concept_id = c.id
          and ge.ontology_version_id = old_version_id
          and ge.status = 'active' and ge.predicate_key = 'broader'
          and (g.concept_key = 'genre:anime'
               or g.concept_key ~ '^genre:.*(film|television|procedural)'));

  -- The episode fragments.
  create temporary table _fragments on commit drop as
  select c.id as concept_id, c.concept_key, r.preferred_label
    from ontology.concepts c
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = old_version_id
     and r.status = 'active'
   where c.retired_at is null
     and r.concept_kind = 'work'
     and btrim(r.preferred_label) ~* '^(ep\.?|episode|第)\s*[0-9]+\s*(話|화|集)?$'
     and not exists (
       select 1 from ontology.concept_edges e
        where e.subject_concept_id = c.id
          and e.ontology_version_id = old_version_id
          and e.status = 'active'
          and e.predicate_key in ('work_in_collection', 'soundtrack_of'));

  if not exists (select 1 from _songs)
     and not exists (select 1 from _fragments) then
    raise notice '0401: nothing stands to repair; the rules wait';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Songs file through performers; episode fragments retire.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- 1a. The content-genre edges come off the songs.
  update ontology.concept_edges ge
     set status = 'rejected'
    from _songs s, ontology.concepts g
   where ge.subject_concept_id = s.concept_id
     and ge.ontology_version_id = new_version_id
     and ge.status = 'active' and ge.predicate_key = 'broader'
     and g.id = ge.object_concept_id
     and (g.concept_key = 'genre:anime'
          or g.concept_key ~ '^genre:.*(film|television|procedural)');
  get diagnostics songs_ungenred = row_count;

  -- 1b. The anime tie survives as soundtrack_of where a franchise/work
  -- target is already stated and itself files under anime.
  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key,
    object_concept_id, confidence, provenance_type, provenance, status)
  select distinct new_version_id, s.concept_id, 'soundtrack_of',
         fe.object_concept_id, 0.8, 'learned',
         jsonb_build_object('rule', '0401 tie restated'), 'active'
    from _songs s
    join ontology.concept_edges fe
      on fe.subject_concept_id = s.concept_id
     and fe.ontology_version_id = new_version_id
     and fe.status = 'active' and fe.predicate_key = 'part_of_franchise'
   where semantic_private.concept_block(fe.object_concept_id, new_version_id)
         = 'genre:anime'
  on conflict do nothing;
  get diagnostics ties_restated = row_count;

  -- 2. The fragments step down — 'deprecated', the revision vocabulary's
  -- own word (0350's), with the reason on the row.
  update ontology.concept_revisions r
     set status = 'deprecated',
         metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('deprecated_by', '0401',
                                          'reason', 'episode_fragment')
    from _fragments f
   where r.concept_id = f.concept_id
     and r.ontology_version_id = new_version_id and r.status = 'active';
  get diagnostics fragments_retired = row_count;


  -- 3. **The re-placement: a read supersedes a guess.** Thirteen screen
  -- works answered uniquely on Wikidata (exact label, screen class on
  -- P31, one candidate binds / two refuse — tools/ris_screen_replace.py,
  -- run 2026-08-26; 18 refused ambiguous and 24 absent keep their
  -- standing edges). Genres arrive id-to-id through our vocabulary's own
  -- stored QIDs, never by name. The bridge's guessed screen edges on
  -- these works retire in favour of the read.
  create temporary table _replacements (
    concept_key text, genre_key text, qid text) on commit drop;
  insert into _replacements values
    ('work:the_greatest_showman', 'genre:biographical_film', 'Q27942936'),
    ('work:the_greatest_showman', 'genre:musical_film', 'Q27942936'),
    ('work:the_greatest_showman', 'genre:romance_film', 'Q27942936'),
    ('work:aashiqui_2', 'genre:musical_film', 'Q4662712'),
    ('work:aashiqui_2', 'genre:romance_film', 'Q4662712'),
    ('work:the_hunger_games', 'genre:action_film', 'Q212965'),
    ('work:the_hunger_games', 'genre:adventure_film', 'Q212965'),
    ('work:the_hunger_games', 'genre:fantasy_film', 'Q212965'),
    ('work:the_hunger_games', 'genre:science_fiction_film', 'Q212965'),
    ('work:chungking_express', 'genre:crime_film', 'Q766263'),
    ('work:chungking_express', 'genre:romance_film', 'Q766263'),
    ('work:chungking_express', 'genre:tragicomedy', 'Q766263'),
    ('creator:kept_d4f80560ea3b868f', 'genre:police_procedural', 'Q19520525'),
    ('creator:kept_d4f80560ea3b868f', 'genre:tragicomedy', 'Q19520525'),
    ('work:veere_di_wedding', 'genre:comedy_film', 'Q28841910'),
    ('work:cloud_atlas', 'genre:fantasy_film', 'Q28936'),
    ('work:cloud_atlas', 'genre:mystery_film', 'Q28936'),
    ('work:cloud_atlas', 'genre:science_fiction_film', 'Q28936'),
    ('work:young_sheldon', 'genre:sitcom', 'Q30014613'),
    ('work:interstellar', 'genre:adventure_film', 'Q13417189'),
    ('work:interstellar', 'genre:science_fiction_film', 'Q13417189'),
    ('work:interstellar', 'genre:thriller_film', 'Q13417189'),
    ('work:twilight', 'genre:action_film', 'Q160071'),
    ('work:twilight', 'genre:fantasy_film', 'Q160071'),
    ('work:twilight', 'genre:romance_film', 'Q160071'),
    ('work:twilight', 'genre:teen_film', 'Q160071'),
    ('work:la_la_land', 'genre:comedy_film', 'Q20856802'),
    ('work:la_la_land', 'genre:dance_film', 'Q20856802'),
    ('work:la_la_land', 'genre:musical_film', 'Q20856802'),
    ('work:la_la_land', 'genre:romance_film', 'Q20856802'),
    ('work:la_la_land', 'genre:tragicomedy', 'Q20856802'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:adventure_film', 'Q641315'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:family_film', 'Q641315'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:musical_film', 'Q641315'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:teen_film', 'Q641315'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:western_film', 'Q641315'),
    ('work:august_rush', 'genre:action_film', 'Q695297'),
    ('work:august_rush', 'genre:musical_film', 'Q695297'),
    ('work:august_rush', 'genre:romance_film', 'Q695297');

  update ontology.concept_edges ge
     set status = 'rejected'
    from ontology.concepts c, ontology.concepts g
   where c.concept_key in (select distinct concept_key from _replacements)
     and ge.subject_concept_id = c.id
     and ge.ontology_version_id = new_version_id
     and ge.status = 'active' and ge.predicate_key = 'broader'
     and g.id = ge.object_concept_id
     and (g.concept_key = 'genre:anime'
          or g.concept_key ~ '^genre:.*(film|television|procedural|thriller|fiction|drama$|sitcom)')
     and g.concept_key not in (
       select genre_key from _replacements rp
        where rp.concept_key = c.concept_key);
  get diagnostics guesses_superseded = row_count;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key,
    object_concept_id, confidence, provenance_type, provenance, status)
  -- 'curated', not 'external' — 0179's precedent: an external edge must
  -- resolve to a registered external_entities row, and the honest
  -- alternative is a curated edge that names its source in provenance.
  select new_version_id, c.id, 'broader', g.id, 0.9, 'curated',
         jsonb_build_object('rule', '0401 wikidata re-placement',
                            'provider', 'wikidata', 'external_id', rp.qid),
         'active'
    from _replacements rp
    join ontology.concepts c on c.concept_key = rp.concept_key
    join ontology.concepts g on g.concept_key = rp.genre_key
  on conflict do nothing;
  get diagnostics reads_placed = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || songs_ungenred
    || ' content-genre edge(s) off performed works, ' || ties_restated
    || ' tie(s) restated as soundtrack_of, ' || fragments_retired
    || ' episode fragment(s) retired, ' || guesses_superseded
    || ' guess(es) superseded, ' || reads_placed || ' read(s) placed');
  raise notice '0401: % published — % ungenred, % restated, % retired',
    next_version, songs_ungenred, ties_restated, fragments_retired;
end;
$$;

commit;
