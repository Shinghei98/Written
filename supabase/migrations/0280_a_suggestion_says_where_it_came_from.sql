-- 0280 — a suggestion says which source it came from.
--
-- The card reads "Found in your listening" under every row, written as a
-- literal when the only lane feeding it was music. The owner opened a term the
-- model read off a YouTube subscription and the card told him it came from his
-- listening. Not a rendering slip: **the surface was asserting provenance it
-- had never been given**, and provenance is the one thing a review card exists
-- to carry — a person judging a proposed term is judging it against where it
-- came from.
--
-- So `begin_calibration` returns the sources behind each item, read from the
-- evidence rather than assumed, and the client says what it is told. One
-- literal leaves the app; nothing replaces it there but a rendering of this
-- value.
--
-- Patched from the deployed body, the rule this week has paid for five times.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);

  patched := replace(body,
    E'        ''rank'', ri.rank,',
    E'        ''rank'', ri.rank,\n'
    || E'        -- Where the evidence actually came from, distinct and ordered so\n'
    || E'        -- the same item reads the same way twice.\n'
    || E'        ''sources'', coalesce((\n'
    || E'          select jsonb_agg(distinct s.source_code order by s.source_code)\n'
    || E'            from semantic_private.candidate_support_links sl\n'
    || E'            join semantic_private.observations s on s.id = sl.observation_id\n'
    || E'           where sl.candidate_id = ri.candidate_id), ''[]''::jsonb),');
  if patched = body then
    raise exception '0280: the item payload is not the one 0264 built';
  end if;
  execute patched;
end;
$$;

do $$
begin
  if position('''sources''' in
              pg_get_functiondef('api.begin_calibration(integer)'::regprocedure)) = 0 then
    raise exception '0280: a suggestion still cannot say where it came from';
  end if;
end;
$$;
