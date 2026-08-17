-- 0181 — resolver 0.10.0: a game is credited as an artist.
--
-- ## Why a version, when the code is what changed
--
-- A run's identity is `(user, revision, ontology version, resolver, scorer)` and
-- the code version is not in it, so deploying the Lambda re-scores nothing. The
-- behaviour below changes which *role* a credit is emitted under, which changes
-- every mapping it produces — so it needs a version, and the version is what
-- makes `enqueue_recompute_on_analysis_change` at the foot find work to do.
--
-- ## What changed
--
-- Apple lists a game soundtrack under an "artist" named after the game, so
-- `Where Winds Meet` arrives in a music payload exactly as `Taylor Swift` does.
-- `0180` routes the concept to `work:apple_…`; this routes the *term*.
--
-- **Both halves are needed and neither works alone**, which is the measurement
-- worth keeping: with the concept a work and the term still typed `creator`, the
-- mapper's `_type_compatible` refuses the pairing and the game scored **0.055
-- against a 0.25 bar** — minted, correct, parented, and invisible on the page.
-- A term routed to a concept that does not exist would fail the other way.
--
-- The flag is `ontology.external_entities.is_game`, computed once at fetch time
-- from the album title that names the game (`apple_catalog.game_titles_in`), so
-- the resolver reads a stored catalogue answer rather than re-deciding per row.
-- **Not the artist's stated genre**: Apple answers `Video Game` for the game,
-- for the person who composed it and for the studio that published it, so that
-- field cannot separate them and using it would have turned a songwriter into a
-- video game.

begin;

update ontology.model_versions set status = 'retired'
 where model_key = 'ontology_first_resolver' and status = 'active';

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select gen_random_uuid(), 'ontology_first_resolver', '0.10.0', 'resolver', null,
       old.parameters || jsonb_build_object(
         'catalogue_game_credits',
         'a credit whose catalogue entry carries is_game is emitted as a '
         || 'source_work term with a work type hint rather than as a creator. '
         || 'The flag is set at fetch time from the album title naming the game '
         || '(Original Game Soundtrack and its variants), never from the '
         || 'artist genre, which Apple states as Video Game for the game, its '
         || 'composer and its studio alike. Every other credit on the same row '
         || 'is unaffected, so the composer of a game soundtrack stays a '
         || 'creator.'
       ),
       'active'
  from ontology.model_versions old
 where old.model_key = 'ontology_first_resolver' and old.version = '0.9.0'
-- **`0174` mints this same version, and the two collide.** Both insert
-- `ontology_first_resolver` 0.10.0 from 0.9.0, so on any database where `0174`
-- ran this statement raises `duplicate key`. Production never noticed because
-- `0174` was never applied there — it is marked applied in the ledger and its
-- `spotify_top_items` parameter is absent from the live 0.10.0 row, which is
-- how the collision stayed hidden until the chain was first replayed from
-- empty. The package half of `0174` shipped independently and works (12,787 of
-- 12,803 `top_track` observations are mapped); what was lost is the parameter
-- describing it, and `0205` puts that back.
--
-- Merging rather than inserting is what makes the two composable: whichever
-- runs second adds its parameter to the row instead of fighting for it, and a
-- replay ends with both keys present, which is what the deployed resolver
-- actually implements.
on conflict (model_key, version) do update
   set parameters = ontology.model_versions.parameters || excluded.parameters,
       model_role = excluded.model_role,
       status     = 'active';

do $$
declare
  actives  integer;
  enqueued integer;
begin
  select count(*) into actives
    from ontology.model_versions
   where model_key = 'ontology_first_resolver' and status = 'active';
  if actives <> 1 then
    raise exception '0181: expected one active resolver, found %', actives;
  end if;

  if not exists (
    select 1 from ontology.model_versions
     where model_key = 'ontology_first_resolver' and version = '0.10.0'
       and status = 'active'
       and parameters ? 'catalogue_game_credits'
  ) then
    raise exception '0181: 0.10.0 is not the active resolver, or lost its parameter';
  end if;

  -- The last statement, and the only thing that makes any of this run.
  select semantic_private.enqueue_recompute_on_analysis_change(
           'resolver 0.10.0: a game credited as an artist is a work'
         ) into enqueued;
  raise notice '0181: enqueued % recompute job(s)', enqueued;
end;
$$;

commit;
