-- 0283 — review shows who and what, not which track.
--
-- Measured on the outstanding queue: 5,764 of roughly 5,900 undecided review
-- items are `work`, `album` or `music_work` — individual songs and records.
-- The owner's instruction is that the review surface must not be that
-- granular: **never a song, the singer or the composer; never a character or
-- an installment, the franchise.** A person judging proposed vocabulary should
-- be judging the things a profile is actually about.
--
-- This is the half that is a filter. The families a term can carry are already
-- the contract's — `person`, `group`, `organization`, `franchise`, `anime`,
-- `game`, `sport`, `activity`, `idea`, `culture`, `event`, `tour` against
-- `work`, `album`, `music_work` — so the rule is written against that
-- vocabulary and names no term, no artist and no title. Concept-backed
-- candidates are filtered the same way by `concept_kind`, less `work`.
--
-- **What this does not do**, and what remains owed: the model still proposes
-- songs, characters and installments, and this hides them rather than
-- stopping them. Proposing the singer instead of the track, the franchise
-- instead of the character, and an English name beside the original is an
-- extraction change — prompt, schema and a release — not a filter. Nothing
-- here is deleted: every hidden candidate keeps its evidence and returns the
-- moment a coarser rule replaces this one.

-- The rule, named once so the batch and the page cannot drift apart, and so
-- the granularity policy has somewhere to live when it is replaced by the
-- extraction change rather than being spelled out twice inside one function.
create or replace function semantic_private.review_item_is_coarse(p_candidate_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((
    select case
             when pe.family is not null
               then pe.family not in ('work', 'album', 'music_work')
             when utc.concept_id is not null
               then exists (
                 select 1 from ontology.concept_revisions kcr
                  where kcr.concept_id = utc.concept_id
                    and kcr.ontology_version_id =
                        (select id from ontology.versions where status = 'published')
                    and kcr.concept_kind <> 'work')
             else false
           end
      from semantic_private.user_term_candidates utc
      left join semantic_private.provisional_entities pe
        on pe.id = utc.provisional_entity_id
     where utc.id = p_candidate_id), false)
$$;

revoke all on function semantic_private.review_item_is_coarse(uuid) from public;
grant execute on function semantic_private.review_item_is_coarse(uuid)
  to authenticated, semantic_worker;

-- The rule, named once so the batch and the page cannot drift apart, and so
-- the granularity policy has somewhere to live when it is replaced by the
-- extraction change rather than being spelled out twice inside one function.
create or replace function semantic_private.review_item_is_coarse(p_candidate_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((
    select case
             when pe.family is not null
               then pe.family not in ('work', 'album', 'music_work')
             when utc.concept_id is not null
               then exists (
                 select 1 from ontology.concept_revisions kcr
                  where kcr.concept_id = utc.concept_id
                    and kcr.ontology_version_id =
                        (select id from ontology.versions where status = 'published')
                    and kcr.concept_kind <> 'work')
             else false
           end
      from semantic_private.user_term_candidates utc
      left join semantic_private.provisional_entities pe
        on pe.id = utc.provisional_entity_id
     where utc.id = p_candidate_id), false)
$$;

revoke all on function semantic_private.review_item_is_coarse(uuid) from public;
grant execute on function semantic_private.review_item_is_coarse(uuid)
  to authenticated, semantic_worker;

do $$
declare
  fn text;
  patched text;
begin
  fn := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);

  -- The exposure batch. Anchored on `calibration_v1`, which appears once.
  patched := replace(fn,
    E'     where ri.user_id = me and ri.review_epoch = epoch\n'
    || E'       and not exists (\n'
    || E'         select 1 from semantic_private.review_exposures x\n'
    || E'          where x.review_item_id = ri.id and x.user_id = me)\n',
    E'     where ri.user_id = me and ri.review_epoch = epoch\n'
    || E'       and not exists (\n'
    || E'         select 1 from semantic_private.review_exposures x\n'
    || E'          where x.review_item_id = ri.id and x.user_id = me)\n'
    || E'       and semantic_private.review_item_is_coarse(ri.candidate_id)\n');
  if patched = fn then
    raise exception '0283: the exposure batch is not the one 0268 wrote';
  end if;
  fn := patched;

  -- The returned page. Anchored on the decisive-event filter `0279` added,
  -- whose `e2` alias appears nowhere else.
  patched := replace(fn,
    E'   where ri.user_id = me and ri.review_epoch = epoch\n'
    || E'     and exists (select 1 from semantic_private.review_exposures x\n'
    || E'                  where x.review_item_id = ri.id and x.user_id = me)\n'
    || E'     and not exists (\n'
    || E'       select 1 from semantic_private.review_events e2\n',
    E'   where ri.user_id = me and ri.review_epoch = epoch\n'
    || E'     and exists (select 1 from semantic_private.review_exposures x\n'
    || E'                  where x.review_item_id = ri.id and x.user_id = me)\n'
    || E'     and semantic_private.review_item_is_coarse(ri.candidate_id)\n'
    || E'     and not exists (\n'
    || E'       select 1 from semantic_private.review_events e2\n');
  if patched = fn then
    raise exception '0283: the returned page is not the one 0279 wrote';
  end if;

  execute patched;
end;
$$;

do $$
declare
  fn text;
  hits integer;
  granular uuid;
  coarse uuid;
begin
  fn := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);
  hits := (length(fn) - length(replace(fn, 'review_item_is_coarse', '')))
          / length('review_item_is_coarse');
  if hits <> 2 then
    raise exception '0283: expected the rule in both the batch and the page, found %', hits;
  end if;

  -- **The predicate answers both ways over what this database holds**, or it
  -- is a rule nobody has watched work.
  select utc.id into granular
    from semantic_private.user_term_candidates utc
    join semantic_private.provisional_entities pe on pe.id = utc.provisional_entity_id
   where pe.family in ('work', 'album', 'music_work') limit 1;
  select utc.id into coarse
    from semantic_private.user_term_candidates utc
    join semantic_private.provisional_entities pe on pe.id = utc.provisional_entity_id
   where pe.family not in ('work', 'album', 'music_work') limit 1;

  if granular is not null and semantic_private.review_item_is_coarse(granular) then
    raise exception '0283: a song-level term is still offered for review';
  end if;
  if coarse is not null and not semantic_private.review_item_is_coarse(coarse) then
    raise exception '0283: a person-level term is no longer offered for review';
  end if;
end;
$$;
