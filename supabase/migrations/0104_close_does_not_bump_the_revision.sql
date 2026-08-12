-- 0104 — closing an unpromotable run must not invalidate every score.
--
-- **`0100` made the Memories surface return nothing, and the probe is what
-- found it.** `-probe-surface` on a real device reported *"flags on:
-- memories_reads / list_assertions: reached, and returned nothing"* while 65
-- active assertions existed. Not a client fault and not an empty profile:
-- `api.list_assertions` requires, for every inferred assertion,
--
--     score_run.input_revision = coalesce(user_state.revision, 0)
--
-- so a score computed against a library that has since changed is withheld
-- rather than shown. That guard is right — it is the difference between a claim
-- about somebody and a claim about who they used to be.
--
-- **What moved the revision was closing the zombie runs.**
-- `ingestion_run_update_bump_semantic_revision` fires on *any* update to
-- `ingestion_runs`, so `0100`'s twelve closes bumped David's revision nine
-- times, from 18 to 27, and every score computed at 18 fell out of the surface
-- at once.
--
-- **The exemption already existed and my close was outside it.**
-- `bump_user_state_revision` returns early when
-- `written.finalize_ingestion_v031` is set: the finalizer manages the revision
-- itself, bumping only when `changed_count > 0`. `close_unpromotable_ingestion_run`
-- raises `written.close_unpromotable_v031` instead — a separate flag, chosen in
-- `0100` so the guard could name both authorised closes rather than have one
-- impersonate the other, which was right — and nothing taught this trigger about
-- it.
--
-- So the close bumped a revision while writing a receipt that says
-- `state_changed: false, changed_item_count: 0` in the same statement. **A
-- migration that changes no current state must not invalidate every score
-- derived from it**, and the two halves of that sentence were three lines apart.
--
-- The revision is not walked back. It is monotonic by design, an earlier value
-- would be a lie about what has happened, and `0105` re-scores at the current
-- one instead.

begin;

create or replace function semantic_private.bump_user_state_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- **Both authorised closes, for the same reason.** The finalizer bumps the
  -- revision itself and only when something changed; the unpromotable close
  -- changes nothing and must bump nothing. A third close would have to appear
  -- here too, which is the argument for these being named flags rather than one
  -- shared one — a path that forgot to name itself would silently invalidate
  -- every score its user has, and that is exactly what happened once.
  if coalesce(
       current_setting('written.finalize_ingestion_v031', true), '0'
     ) = '1'
     or coalesce(
       current_setting('written.close_unpromotable_v031', true), '0'
     ) = '1' then
    return new;
  end if;
  insert into semantic_private.user_state_versions (user_id, revision)
  values (new.user_id, 1)
  on conflict (user_id) do update
  set revision = semantic_private.user_state_versions.revision + 1,
      updated_at = now();
  return new;
end;
$$;

do $$
declare
  before_revision integer;
  after_revision integer;
  subject uuid;
  run uuid;
begin
  -- **Proven by closing a run rather than by reading the source.** `0102`
  -- asserted that a guard *mentioned* a function and this file has twice
  -- shipped a check that passed while measuring nothing. So: make a run, close
  -- it, and see whether the revision moved.
  select user_id into subject
    from semantic_private.user_state_versions
   order by revision desc limit 1;
  if subject is null then
    raise notice 'no user state to test against; skipping the behavioural check';
    return;
  end if;

  select revision into before_revision
    from semantic_private.user_state_versions where user_id = subject;

  run := gen_random_uuid();
  insert into semantic_private.ingestion_runs (
    id, user_id, source_code, connector_source_code, connector_version,
    input_hash, status, run_kind
  ) values (
    run, subject, 'user', 'user', 'probe-0104',
    encode(sha256(gen_random_uuid()::text::bytea), 'hex'), 'running', 'connector'
  );

  -- The insert trigger bumps, which is correct and not what this is about.
  select revision into before_revision
    from semantic_private.user_state_versions where user_id = subject;

  perform semantic_private.close_unpromotable_ingestion_run(run);

  select revision into after_revision
    from semantic_private.user_state_versions where user_id = subject;

  if after_revision <> before_revision then
    raise exception
      'closing an unpromotable run still bumped the revision (% -> %)',
      before_revision, after_revision;
  end if;

  raise notice 'close left the revision at %, as it must', after_revision;
end
$$;

commit;
