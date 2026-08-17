-- 0220 — resolver 0.12.0: a recording is evidence for a genre.
--
-- ## The finding this is built on
--
-- `0214` minted 560 recordings and `0217` got the ISRC route running; 731
-- observations now carry an accepted `provider_id` mapping to the recording
-- their ISRC identifies. **And not one of them can ever be asserted.** A
-- recording averages 1.31 observations, the strongest reaching `strength` 0.148
-- against a 0.25 bar — which is correct rather than a shortfall. Owning a track
-- is not a trait, and a bar that admitted it would admit everything.
--
-- So the question was what a recording is evidence *for*. Three rollups were
-- measured over both live accounts:
--
--   * **creator — nothing.** 99 (user, creator) pairs reached, 34 already above
--     the bar by the lexical route, **0 new crossings.** The catalogue names the
--     artists the library already named; the evidence is redundant.
--   * **album — weak.** 19 of 254 reach two distinct recordings.
--   * **genre — this migration.** Four new crossings across two accounts:
--     `baroque` at 0.71, `oratorio` at 0.68, and `dance` on both sides at 0.65
--     and 0.45.
--
-- **Genre is the one that is not redundant, and the reason is structural.**
-- Apple states a genre on the *recording*, and the artist-level mint never saw
-- it: `0202` found nine stated artist genre strings and resolved none. Recording
-- genres yield 83 distinct strings of which **61 resolve to exactly one concept**
-- — vocabulary that was already published and had no evidence reaching it.
-- (Counted through `normalize_text`, which is what produced `normalized_label`:
-- a plain `lower(btrim(...))` answers 52, because it never matches the punctuated
-- strings — `hip-hop/rap` is stored as `hip hop rap`.)
--
-- ## One mapping per genre per artist, and why the artist
--
-- The artist is the independence unit. **Forty baroque tracks by one ensemble
-- are one opinion about baroque; two ensembles agreeing are two.** A dict keyed
-- on `(genre, artist)` is the whole of the damping — a second track by an artist
-- already seen finds the key present and adds nothing — so a boxed set cannot
-- look like a conviction.
--
-- **No second threshold is applied — the existing curve decides.** That is worth
-- keeping and it is worth *not* quoting a number for, which this migration had
-- to learn twice:
--
--   * The bar is **0.35, not 0.25**. `ELIGIBLE_STRENGTH_BY_KIND` holds the 0.25
--     relief for `work` alone, and a genre concept's kind is `genre`. Reaching
--     0.35 on `w/(w+6)` needs `w >= 3.23`.
--   * **`w` is not the artist count.** Each mapping contributes
--     `evidence_weight * recency_weight * default_reliability * action_weight`,
--     averaging about **0.6** per artist over both live libraries — so the real
--     requirement is nearer six artists than four, and recency damping pushes it
--     out further still.
--
-- Counting artists rather than weighing them predicted ~20 crossings where four
-- survive. **The number of artists that clears the bar is a consequence of
-- weights set in `score.py`, not a constant this route may state**, which is
-- what `test_genre_rollup_threshold.py` pins.
--
-- It also disposes of the container worry on its own: `genre:apple_19`
-- ("Worldwide", the one real catalogue bucket here) reaches four artists and
-- **does not cross**.
--
-- `mapping_method` is **`provider_metadata`** — in the column's allowlist since
-- the schema was written and never used until now. Apple states this genre
-- *about* the recording; it is not an identifier *for* the genre, which is what
-- `provider_id` means and what the recording mapping itself is.
--
-- ## The silencing rule that was written, measured, and removed
--
-- This shipped a container rule first: skip a genre where the account also has
-- evidence for something beneath it. The worry was real — `genre:apple_19` is
-- **"Worldwide"**, a catalogue drawer rather than a taste, and child count cannot
-- separate it from `genre:baroque`, which has 45 children and is a perfectly good
-- thing to say about somebody.
--
-- Run against both accounts it was **wrong in both directions.** It let
-- "Worldwide" through, neither account holding any of its four children — the one
-- case it existed for. And it struck out `genre:pop` at **227 independent
-- artists** because five of them were also indie pop, and `genre:classical` at 98
-- because some were baroque. Those parents are not drawers, and the edge from
-- mandopop to pop is ordinary taxonomy rather than evidence that the parent was a
-- container.
--
-- What settled it: the opaque-looking keys are not containers either.
-- `genre:apple_1004` is Indie Rock, `apple_1185` Indian Pop, `apple_1263`
-- Bollywood. **Only `apple_19` is a bucket**, and it is the same defect already
-- recorded against `genre:asian_music` — *a container in all but name, and the
-- hub rule cannot catch it because its kind is `genre`.* **That is a vocabulary
-- problem and belongs in the ontology**, where one correction serves every
-- reader. Fixing it inside the resolver would have been a deny-list, and the
-- failure mode of a deny-list is silence.
--
-- ## Why a migration at all
--
-- **Deploying resolver code re-scores nothing.** A run's identity is
-- `(user, revision, ontology version, resolver, scorer)` and carries no code
-- version, so the rollup would sit in the Lambda writing nothing until somebody
-- distilled. The model version is the honest lever, and it must move with the
-- behaviour or `semantic_runs` states something untrue — which is exactly what
-- `0217` had to repair.

begin;

-- **Insert first, retire second, and inherit from whichever version is latest
-- rather than naming one** — `0217`'s lesson. Retiring before a successor is
-- known to exist turns a precondition failure into an outage with no active
-- resolver at all.
insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select extensions.gen_random_uuid(), 'ontology_first_resolver', '0.12.0', 'resolver', null,
       old.parameters || jsonb_build_object(
         'genre_rollup_from_recordings',
         'An observation mapped to a recording by ISRC also contributes one '
         || 'mapping to each genre Apple states for that recording, with '
         || 'mapping_method = provider_metadata. Exactly one mapping is written '
         || 'per (genre, artist) per run: the artist is the independence unit, '
         || 'because forty tracks by one ensemble are one opinion about a genre '
         || 'and two ensembles agreeing are two. No separate threshold is '
         || 'applied: one mapping per artist, and the existing saturation curve '
         || 'decides. How many artists that takes is a consequence of weights '
         || 'set in score.py rather than a number this route may state — a genre '
         || 'concept is scored against ELIGIBLE_STRENGTH 0.35, the 0.25 relief '
         || 'being for concept_kind = work alone, and each mapping contributes '
         || 'evidence_weight * recency_weight * default_reliability * '
         || 'action_weight, which averages about 0.6 per artist on real '
         || 'libraries. Counting artists rather than weighing them predicted '
         || 'twenty crossings where four survive. '
         || 'Evidence weight is 1.0, the observation''s own. A genre string is '
         || 'read only where it resolves to exactly one published genre concept; '
         || 'an ambiguous string resolves to nothing rather than to a guess. '
         || 'Deliberately not done: no parent genre is silenced by a child. That '
         || 'rule was written and measured against both live accounts, where it '
         || 'let genre:apple_19 (Worldwide, the one real catalogue bucket) '
         || 'through and struck out genre:pop at 227 independent artists and '
         || 'genre:classical at 98. Container genres are a vocabulary problem to '
         || 'fix in the ontology, not a deny-list to keep in the resolver.'
       ),
       'active'
  from (
    select * from ontology.model_versions
     where model_key = 'ontology_first_resolver'
     order by string_to_array(version, '.')::integer[] desc
     limit 1
  ) old
on conflict (model_key, version) do update
   set parameters = ontology.model_versions.parameters || excluded.parameters,
       status = 'active';

update ontology.model_versions set status = 'retired'
 where model_key = 'ontology_first_resolver'
   and status = 'active'
   and version <> '0.12.0';

do $$
declare
  actives      integer;
  enqueued     integer;
  resolvable   integer;
  with_genres  integer;
begin
  select count(*) into actives
    from ontology.model_versions
   where model_key = 'ontology_first_resolver' and status = 'active';
  if actives <> 1 then
    raise exception '0220: expected one active resolver, found %', actives;
  end if;

  -- **`provider_metadata` must be a method this table accepts.** The route
  -- writes it and nothing else in the system ever has, so the allowlist has
  -- never been exercised for it — and a check constraint discovered at runtime
  -- fails the job rather than the migration.
  if not exists (
    select 1 from pg_constraint con
     join pg_class rel on rel.oid = con.conrelid
     join pg_namespace n on n.oid = rel.relnamespace
    where n.nspname = 'semantic_private' and rel.relname = 'observation_mappings'
      and pg_get_constraintdef(con.oid) like '%''provider_metadata''%') then
    raise exception '0220: observation_mappings does not accept provider_metadata';
  end if;

  -- How many distinct genre strings the catalogue states, and how many reach
  -- exactly one published concept. **Stated as a pair**: a high count of strings
  -- with a low count of matches is the shape that means the vocabulary is
  -- missing, and one number alone cannot show it.
  --
  -- **The normalization has to be the resolver's, not `lower(btrim(...))`.**
  -- `normalized_label` is written by `normalize_text`, which folds punctuation to
  -- spaces — `Hip-Hop/Rap` is stored as `hip hop rap` — so a plain lowercase
  -- comparison silently misses every punctuated string and answers 52 where the
  -- truth is 61. The regexp below is that folding for the ASCII strings Apple
  -- returns; it is an approximation of `normalize_text` and not a second
  -- implementation of it, which is why nothing but this sanity check uses it.
  select count(distinct btrim(regexp_replace(lower(g), '[^a-z0-9]+', ' ', 'g'))) into with_genres
    from ontology.external_entities e
    cross join lateral jsonb_array_elements_text(e.raw_payload -> 'genreNames') g
   where e.provider = 'apple_music_catalog' and e.entity_kind = 'song'
     and e.raw_payload ? 'genreNames';

  select count(*) into resolvable
    from (
      select l.normalized_label
        from ontology.concept_labels l
        join ontology.concept_revisions cr
          on cr.concept_id = l.concept_id
         and cr.ontology_version_id = l.ontology_version_id
        join ontology.versions v on v.id = l.ontology_version_id
       where v.status = 'published' and l.status = 'active' and cr.status = 'active'
         and cr.concept_kind = 'genre'
       group by l.normalized_label
      having count(distinct l.concept_id) = 1
    ) unambiguous
   where unambiguous.normalized_label in (
     select distinct btrim(regexp_replace(lower(g), '[^a-z0-9]+', ' ', 'g'))
       from ontology.external_entities e
       cross join lateral jsonb_array_elements_text(e.raw_payload -> 'genreNames') g
      where e.provider = 'apple_music_catalog' and e.entity_kind = 'song'
        and e.raw_payload ? 'genreNames');

  -- **Conditional on the input, as `0215` and `0217` had to be taught.** A
  -- replay from empty has no catalogue, and a migration that demanded production
  -- state would fail the replay lane. The rule is that a database holding
  -- catalogued genre strings must be able to resolve some of them; one holding
  -- none must not be required to.
  if with_genres > 0 and resolvable = 0 then
    raise exception
      '0220: % stated genre string(s) and not one resolves to a published concept',
      with_genres;
  end if;
  if with_genres = 0 then
    raise notice '0220: no catalogued genre strings; the rollup will find none';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'resolver 0.12.0: recordings roll up to the genres their catalogue states'
         ) into enqueued;

  raise notice '0220: % stated genre string(s), % resolvable, % recompute job(s) enqueued',
    with_genres, resolvable, enqueued;
end;
$$;

commit;
