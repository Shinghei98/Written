-- 0113 — no feedback action stales the scores, including an addition.
--
-- **`0111` was half right and the other half was found in minutes.** It stopped
-- confirm, suppress and restore from bumping the state revision, and kept the
-- bump for `explicit_add` on the grounds that adding a term is genuinely new
-- state. That is true about state and wrong about consequence: the owner added
-- *My Chemical Romance* and it became **the only row on the page**.
--
-- The mechanism is the one `0111` describes and did not follow far enough.
-- `api.list_assertions` requires a current score for every *inferred*
-- assertion and exempts the rest —
--
--     assertion.assertion_origin <> 'inferred' or (score is current …)
--
-- — so bumping the revision withheld all 36 inferred rows while the one
-- user-declared row, exempt by construction, stayed. Adding a term deleted the
-- page and left the term.
--
-- **The rule the revision actually encodes is about evidence, not about state.**
-- It answers *"which version of the inputs were these scores computed
-- against"*. A declared assertion has no observations and no mappings; the
-- scorer never sees it, and a re-score would produce byte-identical numbers for
-- everything else. So none of the four feedback actions is an input, and the
-- trigger has no correct firing condition — which is why it goes rather than
-- narrowing again.
--
-- Evidence still moves the revision: `finalize_ingestion_run_v031` bumps it
-- when a distillation changes current items, which is the only place it should
-- ever have come from. `0104` removed the other spurious source — closing an
-- unpromotable ingestion run — and this removes the last one.
--
-- **Twice now a trigger has fired on something that looked like a change and
-- was not**, and both times the cost was every score a person had. The
-- distinction worth carrying: a write that changes what somebody *said* is not
-- a write that changes what their data *shows*.

begin;

drop trigger if exists feedback_event_bump_semantic_revision
  on semantic_private.feedback_events;

do $$
declare
  remaining text;
begin
  if exists (
    select 1 from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
     where not t.tgisinternal
       and c.relname = 'feedback_events'
       and t.tgname = 'feedback_event_bump_semantic_revision'
  ) then
    raise exception 'the feedback revision trigger is still installed';
  end if;

  -- **The bump survives where it belongs.** Dropping the wrong caller must not
  -- read as dropping the mechanism: `bump_user_state_revision` still fires for
  -- the tables that carry evidence, and `finalize_ingestion_run_v031` still
  -- manages the revision itself for a distillation that changed something.
  select string_agg(c.relname, ', ' order by c.relname) into remaining
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
   where not t.tgisinternal and p.proname = 'bump_user_state_revision';
  if remaining is null then
    raise exception 'no table bumps the revision any more';
  end if;
  raise notice 'the revision still moves for: %', remaining;
end
$$;

commit;
