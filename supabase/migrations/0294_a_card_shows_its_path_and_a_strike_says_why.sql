-- 0294 — a review card shows what kind of thing it is, and a strike says why.
--
-- Cardinal specification §11: a provisional is reviewable only when a human
-- can understand the term, its placement and the evidence — a debug row is
-- not a review product. And §6.3: a strike carries a reason code, because
-- "not interested" and "wrong thing" are different supervision and one tap
-- that cannot say which poisons identity calibration with taste.
--
-- Two server changes; the app renders what it is told:
--   * `begin_calibration` returns `cardinal_root` and `breadcrumb` per item —
--     the root from the overlay (concepts) or the provisional's own column,
--     the breadcrumb climbed from `broader` edges at the published version,
--     root-first, at most six steps, matching the spec's depth cap.
--   * `strike_calibration_item` accepts an optional reason from the closed
--     vocabulary; absent stays `ambiguous_rejection`, the honest reading of a
--     bare tap. The reason then prices its own labels through 0292's table —
--     `wrong_entity` penalizes the resolver route, `not_interested` the
--     affinity, and neither poisons the other.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);

  patched := replace(body,
    E'        ''rank'', ri.rank,',
    E'        ''rank'', ri.rank,\n'
    || E'        ''cardinal_root'', coalesce(\n'
    || E'          (select r.root_id from ontology.concept_cardinal_roots r\n'
    || E'            where r.concept_id = utc.concept_id),\n'
    || E'          pe.cardinal_root_id),\n'
    || E'        ''breadcrumb'', case when utc.concept_id is not null then (\n'
    || E'          with recursive climb(concept_id, depth) as (\n'
    || E'            select utc.concept_id, 0\n'
    || E'            union all\n'
    || E'            select e.object_concept_id, climb.depth + 1\n'
    || E'              from climb\n'
    || E'              join ontology.concept_edges e\n'
    || E'                on e.subject_concept_id = climb.concept_id\n'
    || E'               and e.predicate_key = ''broader'' and e.status = ''active''\n'
    || E'               and e.ontology_version_id =\n'
    || E'                   (select id from ontology.versions where status = ''published'')\n'
    || E'             where climb.depth < 6)\n'
    || E'          select jsonb_agg(bl.preferred_label order by c.depth desc)\n'
    || E'            from climb c\n'
    || E'            join ontology.concept_revisions bl\n'
    || E'              on bl.concept_id = c.concept_id\n'
    || E'             and bl.ontology_version_id =\n'
    || E'                 (select id from ontology.versions where status = ''published'')\n'
    || E'           where c.depth > 0\n'
    || E'        ) else ''[]''::jsonb end,');
  if patched = body then
    raise exception '0294: the item payload is not the one 0280 built';
  end if;
  execute patched;
end;
$$;

-- The strike gains its reason. Redefined rather than patched: the signature
-- changes, and create-or-replace would overload — the 42725 lesson.
do $$
declare
  body text;
begin
  body := pg_get_functiondef('api.strike_calibration_item(uuid)'::regprocedure);
  body := replace(body,
    'FUNCTION api.strike_calibration_item(item uuid)',
    'FUNCTION api.strike_calibration_item(item uuid, p_reason text default null)');
  body := replace(body,
    E'''strike_off'', ''ambiguous_rejection'',',
    E'''strike_off'',\n'
    || E'         case when p_reason in (''not_interested'', ''wrong_entity'',\n'
    || E'                                ''wrong_type'', ''wrong_parent'',\n'
    || E'                                ''wrong_predicate'', ''not_representative'',\n'
    || E'                                ''too_private'', ''duplicate'', ''outdated'')\n'
    || E'              then p_reason else ''ambiguous_rejection'' end,');
  if position('p_reason' in body) = 0 then
    raise exception '0294: the strike did not gain its reason';
  end if;
  drop function api.strike_calibration_item(uuid);
  execute body;
end;
$$;

revoke all on function api.strike_calibration_item(uuid, text) from public, anon;
grant execute on function api.strike_calibration_item(uuid, text) to authenticated;

do $$
declare
  fn text;
  n integer;
begin
  select count(*) into n from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'api' and p.proname = 'strike_calibration_item';
  if n <> 1 then
    raise exception '0294: % strike functions; an overload raises 42725 at tap time', n;
  end if;

  fn := regexp_replace(
          pg_get_functiondef('api.begin_calibration(integer)'::regprocedure),
          '--[^\n]*', '', 'g');
  if position('cardinal_root' in fn) = 0 or position('breadcrumb' in fn) = 0 then
    raise exception '0294: a card still cannot say what kind of thing it shows';
  end if;
  -- An unrecognised reason degrades to the honest default rather than raising
  -- at the tap.
  fn := pg_get_functiondef('api.strike_calibration_item(uuid, text)'::regprocedure);
  if position('ambiguous_rejection' in fn) = 0 then
    raise exception '0294: the bare tap lost its honest default';
  end if;
end;
$$;
