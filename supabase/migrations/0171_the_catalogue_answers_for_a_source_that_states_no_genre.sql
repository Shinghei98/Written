-- 0171 — the catalogue answers for a source that states no genre.
--
-- ## What was measured
--
-- 2026-08-14, a 593-row Spotify library on the demo account: **1,522 terms
-- extracted, 6 accepted mappings, 0 eligible assertions.** The six were four
-- creators at one mapping each and two `era:*` concepts, which are in
-- `NEVER_ASSERTED_KEY_PREFIXES` and can never surface. The page said it was
-- still working out what the person was about.
--
-- The distillation was fine. The payloads are the difference:
--
-- | | rows | carry `genres` | carry `release_date` |
-- |---|---|---|---|
-- | apple_music | library_song 641, playlist_item 455, recently_played 359 | **all** | all |
-- | spotify | top_track 500, top_artist 60, followed_artist 20 | **0** | 0 |
--
-- **A genre is the root of everything a person can see.** `artist_spheres`
-- reads nothing else; `artist_scenes` needs a sphere; `takes_decades` gates the
-- era. Spotify's API states no genre at track level at all, so a Spotify row
-- reaches a bare `genre:` concept at best and usually nothing — and only 18 of
-- that library's 294 distinct performers exist in the creator vocabulary,
-- because that vocabulary was minted from one Apple Music library.
--
-- ## Why Apple's catalogue, keyed on ISRC
--
-- **Every Spotify track carries an ISRC — 500 of 500, measured** — and it is
-- the one identifier the two catalogues share. `semantic_private.sources`
-- already records `spotify.online_resolution_policy = 'catalog_ids_only'`, the
-- same value `apple_music` carries, so resolving a row against a catalogue *by
-- identifier* is what this source was already registered to permit.
--
-- **And Apple returns Apple's vocabulary, which is the deciding argument.**
-- `sphere`, `scene` and `era` are exact, case-sensitive dict lookups over
-- Apple's own strings in `tools/music_dictionary.py` — verified by running
-- them, `'J-Pop'` resolves and `'j-pop'` does not. Any other catalogue would
-- need a translation table authored and kept in step, which is a second
-- vocabulary and the drift `0134` was written about.
--
-- ## The shape
--
-- `tools/apple_catalog.py` looks the ISRCs up offline with a MusicKit developer
-- token and emits the answers as a migration into `ontology.external_entities`
-- — a table that has existed and been empty since the schema was written, and
-- is exactly a third-party catalogue cache. No credential goes near the Lambda
-- and no network call sits inside the scoring path.
--
-- `resolve.py` joins at read time: `with_catalogue_genres` fills a genre where
-- the row states none and names an ISRC, **before `library_facts`** — after it
-- the genre would reach `genre:*` and neither sphere nor scene, which is
-- everything a person actually sees. The condition is the gap rather than a
-- list of the sources that have it, so a later source with the same shortage
-- benefits without anybody remembering to add it.
--
-- **Nothing is written into the vault.** `guard_observation_immutable` freezes
-- `normalized_payload`, and rightly: a catalogue is not the person's evidence.
-- The join lives exactly as long as the run.
--
-- ## The grant, which is the part that would have taken the whole thing down
--
-- `semantic_worker` could not read `ontology.external_entities` — checked with
-- `has_table_privilege` rather than assumed, and the answer was false. The
-- worker's grants are enumerated per table precisely because `on all tables`
-- binds at execution time, so a table added by an earlier migration has none.
-- Without this the new query raises `42501` and kills the run for **every**
-- source, not just Spotify, with an error naming a genre table.
--
-- Read-only, and only this role. `semantic_ingestor` gets nothing: it holds
-- zero table privileges by design, and leaked it writes vault rows and reads
-- none back.

begin;

grant select on ontology.external_entities to semantic_worker;

-- **Resolver 0.9.0 — a behaviour change needs a model version.** A run's
-- identity is `(user, revision, ontology version, resolver, scorer)` and the
-- code version is not in it, so deploying the Lambda re-scores nothing. The
-- parameter is recorded on the row because that is where a later reader looks,
-- rather than in a commit message.
update ontology.model_versions set status = 'retired'
 where model_key = 'ontology_first_resolver' and status = 'active';

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select gen_random_uuid(), 'ontology_first_resolver', '0.9.0', 'resolver', null,
       old.parameters || jsonb_build_object(
         'catalogue_genre_fill',
         'a row stating no genre and naming an ISRC takes the genre Apple''s '
         || 'catalogue states for that recording, from '
         || 'ontology.external_entities where provider = apple_music_catalog. '
         || 'Merged before library_facts, so it reaches sphere, scene and era '
         || 'rather than only genre. The source always outranks the catalogue: '
         || 'a stated genre is never overwritten. Nothing is written back — '
         || 'normalized_payload is frozen and a catalogue is not the person''s '
         || 'evidence.'
       ),
       'active'
  from ontology.model_versions old
 where old.model_key = 'ontology_first_resolver' and old.version = '0.8.0';

do $$
declare
  granted boolean;
  actives integer;
  enqueued integer;
begin
  -- **Asked of the catalog, not assumed from the statement above.**
  -- `information_schema.table_privileges` shows only what the *querying* role
  -- can see and answers empty for `ontology`, which is how a missing grant
  -- stays invisible until a run dies.
  select has_table_privilege('semantic_worker', 'ontology.external_entities', 'select')
    into granted;
  if not granted then
    raise exception '0171: semantic_worker still cannot read the catalogue';
  end if;

  -- And the identity it must *not* have gained.
  select has_table_privilege('semantic_ingestor', 'ontology.external_entities', 'select')
    into granted;
  if granted then
    raise exception '0171: semantic_ingestor was granted a read it must not have';
  end if;

  select count(*) into actives
    from ontology.model_versions
   where model_key = 'ontology_first_resolver' and status = 'active';
  if actives <> 1 then
    raise exception '0171: expected one active resolver, found %', actives;
  end if;

  -- The last statement, and the only thing that makes any of this run.
  select semantic_private.enqueue_recompute_on_analysis_change(
           'resolver 0.9.0: a catalogue answers for a source that states no genre'
         ) into enqueued;
  raise notice '0171: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
