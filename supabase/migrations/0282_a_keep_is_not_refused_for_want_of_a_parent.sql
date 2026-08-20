-- 0282 — a keep is not refused for want of a parent.
--
-- `0272` made the mint assert that nothing it minted reaches no block, copying
-- the rule every other minting path uses. On an import that is right: the
-- import can be fixed and re-run. **On a keep it is not.** The assertion
-- raised, the whole batch rolled back, and a person's decision about their own
-- term was refused because this system could not name a parent for it — which
-- is the wrong thing to weigh against the wrong thing. Two YouTube keeps
-- blocked every keep behind them.
--
-- The guard's purpose was to stop a term floating *silently*. It still does:
-- the count is raised as a notice and the concept is minted, `0273`'s armer
-- keeps seeing any concept that reaches no block, and
-- `attach_kept_concept_parents` keeps trying — so a term the vocabulary cannot
-- place today is placed the moment it can be, without anybody re-deciding
-- anything. Nothing silent, nothing lost, and nobody's keep refused.
--
-- The YouTube route that made those two placeable ships with this: the lane
-- reads `topics`, which is the source's own label and the same act as reading
-- a genre.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.mint_from_kept_requests(jsonb)'::regprocedure);

  patched := replace(body,
    E'    if unparented > 0 then\n'
    || E'      raise exception\n'
    || E'        ''mint_from_kept_requests: % kept concept(s) reach no block and would land under Other'',\n'
    || E'        unparented;\n'
    || E'    end if;',
    E'    if unparented > 0 then\n'
    || E'      raise notice\n'
    || E'        ''mint_from_kept_requests: % kept concept(s) reach no block yet; the repair will place them'',\n'
    || E'        unparented;\n'
    || E'    end if;');
  if patched = body then
    raise exception '0282: the mint does not raise the assertion 0272 added';
  end if;
  execute patched;
end;
$$;

do $$
declare
  body text;
begin
  body := pg_get_functiondef(
    'semantic_private.mint_from_kept_requests(jsonb)'::regprocedure);
  if position('reach no block yet' in body) = 0 then
    raise exception '0282: the mint still refuses a keep it cannot place';
  end if;
  if position('raise exception' || E'\n' || '        ''mint_from_kept_requests: %' in body) > 0 then
    raise exception '0282: the fatal assertion survives';
  end if;
  -- The armer still sees an unplaced concept, which is what makes the notice
  -- honest rather than a shrug.
  if position('concept_block' in
              pg_get_functiondef(
                'semantic_private.arm_pending_mint_requests()'::regprocedure)) = 0 then
    raise exception '0282: nothing would ever look at an unplaced term again';
  end if;
end;
$$;
