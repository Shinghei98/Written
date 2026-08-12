-- 0107 — resolver 0.3.0: a scene's decade and sphere come from one row.
--
-- **`scene:1990s_anglophone` meant nothing on a real card, and reading it is
-- what found out.** Asked what the term meant, the answer turned out to be:
-- every one of its nine mappings is Sheena Ringo, tagged `J-Pop`. She has
-- sixteen observations under that genre and two under `Rock` — 2026 releases
-- Apple filed with no language marker — so `artist_spheres` unioned to
-- `{japanese, anglophone}`, and `artist_scenes` crossed her artist-level eras
-- with her artist-level spheres. A 1998 Japanese single reached the anglophone
-- 1990s through two rock tracks recorded twenty-eight years later.
--
-- **0.2.0's own docstring predicted this and then chose the design that has
-- it**: *"deriving one per row and the other per artist would let a single
-- Pop-tagged Cantopop track put an artist in the anglophone scene of a decade
-- computed from everything else"*. `MARKED_SPHERE_GENRES` fixed the case where
-- both genres sit on one row; nothing addressed the case where they sit on
-- different rows, which is the commoner one.
--
-- 0.3.0 pairs them per row: a row's decade comes from its own release date and
-- its sphere from its own genres, so a `Rock` row pairs with anglophone and a
-- `J-Pop` row with japanese and neither borrows the other's decade. A
-- hand-named artist (`ARTIST_ERA`) keeps the artist-level cross, because that
-- table exists precisely for people whose per-row dates are known wrong and
-- there is nothing better to pair with.
--
-- The bare `era:*` term is untouched and stays artist-level — that was the
-- owner's decision and the reason `ARTIST_ERA` and the classical periods live
-- there.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:resolver:v0.3.0'),
  'ontology_first_resolver', '0.3.0', 'resolver', null,
  '{"min_tag_length": 3, "whole_tag_only": true, "fuzzy": false,'
  ' "exact_terms_only": true,'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "composer_periods": true,'
  ' "spheres": ["anglophone", "cantonese", "mandarin", "japanese", "korean"],'
  ' "marked_genre_wins": "a row stating Mandopop|Pop is Mandopop",'
  ' "scene": "decade and sphere must be attested on the same row; a hand-named'
  ' artist keeps the artist-level cross because its per-row dates are wrong"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'resolver' and version = '0.2.0' and status = 'active';

do $$
declare
  active_resolvers integer;
  newest text;
  enqueued integer;
begin
  select count(*) into active_resolvers
  from ontology.model_versions where model_role = 'resolver' and status = 'active';
  if active_resolvers <> 1 then
    raise exception 'expected exactly one active resolver, found %', active_resolvers;
  end if;

  select version into newest
  from ontology.model_versions
  where model_role = 'resolver' and status = 'active'
  order by created_at desc, id
  limit 1;
  if newest <> '0.3.0' then
    raise exception 'finalization would pick resolver %, not 0.3.0', newest;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'resolver 0.3.0: a scene pairs its decade and sphere on one row'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for resolver 0.3.0', enqueued;
end
$$;

commit;
