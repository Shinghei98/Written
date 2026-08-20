-- 0268 — the review surface orders by what the lane is for, not only by when
-- the row was built.
--
-- `0263` made `rank` an epoch-wide position and put model-proposed
-- provisionals — open-vocabulary discovery, the only reason the model lane
-- exists — above known-concept candidates. It could only do that for rows
-- built afterwards. The 59 items built before it are all stranded at rank 0,
-- 56 of them music and 3 from the discovery lane, and `begin_calibration`
-- orders by `(rank, id)` — so the owner faces seven batches of the old
-- collision before reaching a single properly-ranked row, on an account whose
-- YouTube extraction is complete: 285 mentions, 154 correctly-ranked review
-- items, none of them reachable.
--
-- `review_items` is append-only by trigger — deliberately, because a feedback
-- label is uninterpretable without the arrangement it was given in — so the
-- old ranks cannot be rewritten and should not be. The ordering intent
-- belongs in the read instead, where it holds for every row whenever it was
-- built: **discovery first, then rank, then id.** For anything built after
-- `0263` this is redundant, which is the point — a read that states the rule
-- cannot disagree with a builder that encodes it.
--
-- `0264`'s deterministic-order assertion is preserved and extended: the sort
-- is still total, and `(rank, id)` still breaks every tie the first key
-- leaves.

create or replace function api.begin_calibration(batch_size integer default 8)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  me      uuid := (select auth.uid());
  epoch   integer;
  pending integer;
  result  jsonb;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  perform semantic_private.assert_surface_allowed('calibration');
  if batch_size is null or batch_size < 1 or batch_size > 25 then
    raise exception 'batch_size must be between 1 and 25';
  end if;

  select semantic_private.current_review_epoch(me) into epoch;
  if not exists (select 1 from semantic_private.review_items ri
                  where ri.user_id = me and ri.review_epoch = epoch) then
    return jsonb_build_object('epoch', null, 'items', '[]'::jsonb);
  end if;

  -- A new batch only when the current one is answered.
  select count(*) into pending
    from semantic_private.review_items ri
   where ri.user_id = me and ri.review_epoch = epoch
     and exists (select 1 from semantic_private.review_exposures x
                  where x.review_item_id = ri.id and x.user_id = me)
     and not exists (
       select 1 from semantic_private.review_events e
        where e.review_item_id = ri.id and e.user_id = me
          and e.action in ('keep', 'confirm', 'edit', 'strike_off', 'finish_review')
          and not exists (
            select 1 from semantic_private.review_events r2
             where r2.review_item_id = ri.id and r2.user_id = me
               and r2.action = 'restore' and r2.created_at > e.created_at));

  if pending = 0 then
    -- **Discovery first, then rank, then id** — the same key `0263` builds
    -- into new ranks, stated here so it also holds for rows built before it.
    -- Excluded before limited, or the same batch is served forever.
    insert into semantic_private.review_exposures
      (user_id, review_item_id, position, presentation_variant)
    select me, ri.id, ri.rank, 'calibration_v1'
      from semantic_private.review_items ri
      join semantic_private.user_term_candidates utc
        on utc.id = ri.candidate_id and utc.user_id = ri.user_id
     where ri.user_id = me and ri.review_epoch = epoch
       and not exists (
         select 1 from semantic_private.review_exposures x
          where x.review_item_id = ri.id and x.user_id = me)
     order by (utc.provisional_entity_id is not null) desc, ri.rank, ri.id
     limit batch_size;
  end if;

  select jsonb_build_object(
    'epoch', epoch,
    'items', coalesce(jsonb_agg(jsonb_build_object(
        'review_item_id', ri.id,
        'concept_id', utc.concept_id,
        'provisional_entity_id', utc.provisional_entity_id,
        'label', coalesce(cr.preferred_label, pe.canonical_label),
        'predicate', utc.user_facing_predicate,
        'confidence_tier', ri.confidence_tier,
        'rank', ri.rank,
        'struck', exists (
          select 1 from semantic_private.review_events e
           where e.review_item_id = ri.id and e.user_id = me
             and e.action = 'strike_off'
             and not exists (
               select 1 from semantic_private.review_events r2
                where r2.review_item_id = ri.id and r2.user_id = me
                  and r2.action = 'restore' and r2.created_at > e.created_at)))
      order by (utc.provisional_entity_id is not null) desc, ri.rank, ri.id),
      '[]'::jsonb))
    into result
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
    left join ontology.concept_revisions cr
      on cr.concept_id = utc.concept_id
     and cr.ontology_version_id = (select id from ontology.versions where status = 'published')
    left join semantic_private.provisional_entities pe
      on pe.id = utc.provisional_entity_id
   where ri.user_id = me and ri.review_epoch = epoch
     and exists (select 1 from semantic_private.review_exposures x
                  where x.review_item_id = ri.id and x.user_id = me)
     and not exists (
       select 1 from semantic_private.review_events f
        where f.review_item_id = ri.id and f.user_id = me
          and f.action = 'finish_review');

  return result;
end;
$function$;

do $$
declare
  body text;
begin
  body := regexp_replace(
            pg_get_functiondef('api.begin_calibration(integer)'::regprocedure),
            '--[^\n]*', '', 'g');
  -- Both the exposure batch and the returned page carry the same total order.
  if (length(body) - length(replace(body,
        '(utc.provisional_entity_id is not null) desc, ri.rank, ri.id', '')))
     / length('(utc.provisional_entity_id is not null) desc, ri.rank, ri.id') <> 2 then
    raise exception '0268: the two orderings do not agree';
  end if;
  -- `0264`'s properties survive: finished items still leave the page.
  if position('finish_review' in body) = 0 then
    raise exception '0268: begin_calibration no longer excludes finished items';
  end if;
end;
$$;
