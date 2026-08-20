-- 0279 — a decided suggestion leaves the list, and the lane's own discoveries
-- come first.
--
-- ## The list that could not be cleared
--
-- `0264` excluded from the returned page only items carrying a
-- `finish_review` event. Nothing writes one except `api.finish_calibration`,
-- which the app calls only once every visible row has been judged — and the
-- rows never left, because keep and strike write `keep` and `strike_off`, not
-- `finish_review`. Measured on the owner's account: **90 decisions, zero
-- finish events, 64 exposed items still being served.** Every refresh handed
-- back the same page he had just answered, and the one call that would have
-- closed it could never fire. The batch gate `0264` added computes exactly the
-- right predicate two statements earlier and the page did not use it.
--
-- So the page now excludes any item carrying a decisive event — keep, edit,
-- strike_off or finish_review — that no later `restore` has reopened. The same
-- predicate the gate uses, written once.
--
-- ## And why YouTube was invisible
--
-- 1,010 undecided items, of which 383 are the model lane's own proposals and
-- 161 are YouTube-backed. Ordered by rank alone at eight a batch, the terms
-- the lane exists to find sat behind hundreds of projections of vocabulary the
-- deterministic resolver had already matched. **The central rule is that the
-- only reason Qwen exists here is open-vocabulary discovery**, so the page
-- orders by what the lane produced: model-proposed first, then the discovery
-- lane, then the existing rank. Read from `extraction_method` and the
-- observation's source — no label, no term and no category is named.
--
-- Patched from the deployed body, which is the rule this week has paid for
-- five times.

do $$
declare
  body text;
  patched text;
  decisive constant text :=
    E'and not exists (\n'
    || E'       select 1 from semantic_private.review_events e2\n'
    || E'        where e2.review_item_id = ri.id and e2.user_id = me\n'
    || E'          and e2.action in (''keep'', ''edit'', ''strike_off'', ''finish_review'')\n'
    || E'          and not exists (\n'
    || E'            select 1 from semantic_private.review_events r3\n'
    || E'             where r3.review_item_id = ri.id and r3.user_id = me\n'
    || E'               and r3.action = ''restore'' and r3.created_at > e2.created_at))';
  ordering constant text :=
    E'order by exists (\n'
    || E'           select 1 from semantic_private.candidate_support_links dl\n'
    || E'             join semantic_private.mention_resolutions dr on dr.id = dl.mention_resolution_id\n'
    || E'             join semantic_private.observation_mentions dm on dm.id = dr.mention_id\n'
    || E'            where dl.candidate_id = ri.candidate_id\n'
    || E'              and dm.extraction_method = ''model_proposed'') desc,\n'
    || E'         exists (\n'
    || E'           select 1 from semantic_private.candidate_support_links yl\n'
    || E'             join semantic_private.observations yo on yo.id = yl.observation_id\n'
    || E'            where yl.candidate_id = ri.candidate_id\n'
    || E'              and yo.source_code = ''youtube'') desc,\n'
    || E'         (utc.provisional_entity_id is not null) desc, ri.rank, ri.id';
begin
  body := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);

  -- 1. A decided item leaves the page.
  patched := replace(body,
    E'and not exists (\n'
    || E'       select 1 from semantic_private.review_events f\n'
    || E'        where f.review_item_id = ri.id and f.user_id = me\n'
    || E'          and f.action = ''finish_review'')',
    decisive);
  if patched = body then
    raise exception '0279: the page does not filter on finish_review as 0264 wrote it';
  end if;
  body := patched;

  -- 2. Both orderings become the lane's, and there are exactly two.
  if (length(body) - length(replace(body,
        '(utc.provisional_entity_id is not null) desc, ri.rank, ri.id', '')))
     / length('(utc.provisional_entity_id is not null) desc, ri.rank, ri.id') <> 2 then
    raise exception '0279: expected the two orderings 0268 wrote';
  end if;
  body := replace(body,
    'order by (utc.provisional_entity_id is not null) desc, ri.rank, ri.id',
    ordering);
  body := replace(body,
    E'order by (utc.provisional_entity_id is not null) desc,\n'
    || E'            ri.rank, ri.id',
    ordering);

  execute body;
end;
$$;

do $$
declare
  body text;
begin
  body := regexp_replace(
            pg_get_functiondef('api.begin_calibration(integer)'::regprocedure),
            '--[^\n]*', '', 'g');
  if position('''keep'', ''edit'', ''strike_off'', ''finish_review''' in body) = 0 then
    raise exception '0279: a decided suggestion still comes back';
  end if;
  if position('model_proposed'' ) desc' in replace(body, E'\n', '')) = 0
     and position('model_proposed' in body) = 0 then
    raise exception '0279: the page does not order by what the lane proposed';
  end if;
  -- The batch gate is untouched: a new page is still handed out only when the
  -- current one is answered, which is what stops a refresh spending the queue.
  if position('pending = 0' in body) = 0 then
    raise exception '0279: the batch gate was lost';
  end if;
end;
$$;
