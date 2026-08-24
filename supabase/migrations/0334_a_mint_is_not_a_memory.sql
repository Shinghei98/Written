-- 0334 — minting a term is not claiming it about somebody, and 0331 half-landed.
--
-- Two defects, both mine, both found by reading the deployed function rather
-- than the migration that was supposed to have changed it.
--
-- ## 1. `0333` would have written a Memory for the person who struck the term
--
-- `0333` let a strike ask for a mint, on the owner's reasoning that *"striking
-- it off only means that the term is not an accurate description of him,
-- doesn't mean it isn't a term."* That part is right and stands.
--
-- What it missed is what happens after the request is drained.
-- `mint_from_kept_requests` loops over every disposition and calls
-- `confirm_kept_memory` unconditionally:
--
--     where k.disposition in ('mint', 'link', 'link_existing')
--     loop
--       if kept.concept_id is not null then
--         perform semantic_private.confirm_kept_memory(...)
--
-- and that writes `user_assertions` with `assertion_origin =
-- 'explicit_addition', machine_state = 'eligible'` plus `display_state =
-- 'confirmed'`. **So a struck term would have appeared on the striker's
-- Memories page as a confirmed claim** — the precise inversion of what the
-- strike means.
--
-- Worse, nothing would have hidden it. The strike writes `user_suppressions`
-- only `if row_item.concept_id is not null`, and a provisional's is null — so
-- the suppression that `list_assertions` reads is never written for exactly the
-- rows `0333` mints.
--
-- This is the false Memory `0260:14-18` forbids: *"they resolve to the same
-- global identity but **receive no affinity without their own evidence and
-- confirmation**."* Minting is a statement about the world; confirming is a
-- statement about a person. **`disposition = 'mint'` must stop implying both.**
--
-- Nothing was minted under the defect: 0 requests with `origin = 'strike_off'`
-- existed when this was written, and the last request of any kind was
-- 2026-08-21.
--
-- ## 2. `0331` replaced five key expressions of eight and said it had finished
--
-- Its guard was `position(':kept_'' || substr(md5' in body) <> 0`, which reads
-- one formatting of the old expression. Three survivors are line-wrapped:
--
--     k.concept_kind || ':kept_'
--             || substr(md5(k.concept_kind || ':' || k.normalized), 1, 16)
--
-- so the guard matched nothing and passed. **A check written against one
-- rendering of a string is not a check on the string** — the same lesson as
-- counting three key expressions when the catalog holds eight, in the same
-- migration, missed twice.
--
-- The consequence was live and quiet: the insert created `culture:brazil` while
-- three lookups still searched for `culture:kept_<hash>`, so a keep would have
-- minted a concept, failed to find it, and confirmed no Memory at all.
--
-- Both replacements below are whitespace-tolerant, and the assertion is a
-- pattern that cannot be satisfied by reformatting.

do $$
declare
  body text;
  before_old integer;
  after_old  integer;
begin
  select pg_get_functiondef(p.oid) into body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private' and p.proname = 'mint_from_kept_requests';
  if body is null then
    raise exception '0334: semantic_private.mint_from_kept_requests does not exist';
  end if;

  select count(*) into before_old
    from regexp_matches(body, ':kept_', 'g');
  if before_old = 0 then
    raise notice '0334: no legacy key expression found; 0331 may already be complete';
  end if;

  -- **Whitespace-tolerant, because the survivors differed only in indentation.**
  body := regexp_replace(
    body,
    'k\.concept_kind \|\| '':kept_''\s*\|\| substr\(md5\(k\.concept_kind \|\| '':'' \|\| k\.normalized\), 1, 16\)',
    'ontology.mint_concept_key(k.requested_family, k.concept_kind, k.normalized, k.english_label)',
    'g');

  -- **The mint stops implying the Memory.** `origin` rides on `kept_plan`
  -- already — the requests CTE selects `r.origin` — so this needs no new join,
  -- only that the loop carry it and consult it.
  body := replace(body,
E'    select k.request_id, k.user_id,
           coalesce(k.link_concept_id,',
E'    select k.request_id, k.user_id, k.origin,
           coalesce(k.link_concept_id,');

  body := replace(body,
E'    if kept.concept_id is not null then
      perform semantic_private.confirm_kept_memory(
        kept.user_id, kept.concept_id, kept.request_id);
      confirmed := confirmed + 1;
    end if;',
E'    -- **A mint is a statement about the world; a Memory is a statement about
    -- a person.** Only a decision that claimed the term may make the second.
    -- A strike mints the vocabulary and asserts nothing, which is the whole of
    -- 0333: the term survives, the person is left alone.
    if kept.concept_id is not null and kept.origin in (''keep'', ''edit'') then
      perform semantic_private.confirm_kept_memory(
        kept.user_id, kept.concept_id, kept.request_id);
      confirmed := confirmed + 1;
    end if;');

  -- ## 3. `0333` opened the door and the minter still refused at the threshold
  --
  -- Widening `mint_requests.origin` let a strike *ask*. `decision_stands` then
  -- threw the request away:
  --
  --     and d.effective_action in ('keep', 'edit')
  --
  -- The latest decision on a strike-originated request is, necessarily,
  -- `strike_off` — so every one would have been refused
  -- `decision_superseded` and marked permanently `refused`, which
  -- `guard_mint_request_transition` then makes immutable. The contract arm
  -- caught it by asserting the concept exists rather than that the request
  -- does; asserting the request alone would have passed while nothing minted.
  --
  -- **What the test means is "the decision that asked for this mint still
  -- stands"**, not "somebody kept it". A keep request stands while the latest
  -- action is a keep or an edit; a strike request stands while the latest is a
  -- strike. A restore invalidates both, which is right — it re-pends the card.
  body := replace(body,
E'             select 1 from semantic_private.calibration_effective_decisions d
              where d.review_item_id = q.review_item_id
                and d.effective_action in (''keep'', ''edit'')',
E'             select 1 from semantic_private.calibration_effective_decisions d
              where d.review_item_id = q.review_item_id
                and (
                  (q.origin in (''keep'', ''edit'')
                     and d.effective_action in (''keep'', ''edit''))
                  or
                  (q.origin = ''strike_off''
                     and d.effective_action = ''strike_off'')
                )');

  if position('q.origin = ''strike_off''' in body) = 0 then
    raise exception '0334: decision_stands still refuses a strike';
  end if;

  -- **A pattern reformatting cannot satisfy.** Any `:kept_` at all, however it
  -- is wrapped, means a legacy key expression survived — which is what the
  -- previous guard could not say.
  select count(*) into after_old from regexp_matches(body, ':kept_', 'g');
  if after_old <> 0 then
    raise exception
      '0334: % legacy key expression(s) survived the replacement', after_old;
  end if;
  if position('kept.origin in (''keep'', ''edit'')' in body) = 0 then
    raise exception '0334: the Memory was not gated on origin';
  end if;
  if position('k.request_id, k.user_id, k.origin,' in body) = 0 then
    raise exception '0334: the loop does not carry origin';
  end if;

  execute body;
  raise notice '0334: replaced % legacy key expression(s); Memory gated on origin',
    before_old;
end;
$$;

-- ---------------------------------------------------------------------------
-- Proven on the deployed function, not on the text above.
-- ---------------------------------------------------------------------------
do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
        lateral regexp_matches(pg_get_functiondef(p.oid), ':kept_', 'g') m
       where n.nspname = 'semantic_private'
         and p.proname = 'mint_from_kept_requests') <> 0 then
    raise exception '0334: a legacy key expression is still deployed';
  end if;

  if (select position('kept.origin in (''keep'', ''edit'')' in pg_get_functiondef(p.oid))
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'semantic_private'
         and p.proname = 'mint_from_kept_requests') = 0 then
    raise exception '0334: the deployed function does not gate the Memory';
  end if;
end;
$$;
