-- 0185 — disconnecting a source reaches the vault.
--
-- ## The defect, measured 2026-08-15
--
-- David disconnected Spotify. The app's `SyncService.deleteSource` deletes from
-- `public.distilled_records` and `public.source_connections` and stops there, so:
--
-- | | |
-- |---|---|
-- | `source_connections` spotify | 0 — gone |
-- | `public.distilled_records` spotify | 0 — gone |
-- | **vault observations, active** | **580** |
-- | **raw_source_records, active** | **593** |
--
-- The evidence he removed was still being read. Tonight's mint looked up 773
-- ISRCs that Spotify named, and the resolver scored every one of those 580 rows.
-- CLAUDE.md states the rule this breaks in one line — *"a deletion control names
-- both schemas or it is not finished"* — and names `deleteSource` as one of the
-- three deletion exceptions. Only its public half was ever built.
--
-- **`0139` is the precedent and also the proof it recurs.** It excluded the same
-- account's Spotify by hand on 2026-08-13; he distilled Spotify again on the
-- 14th (`ios-1.0+48`, 580 fresh rows) and disconnected after. A hand-written
-- migration is not a control, so this adds the control.
--
-- **And it is a licensing exposure, not only a privacy one.** IV.2.1.a forbids
-- ingesting Spotify Content into a model and IV.2.5 says consent does not cure
-- it; keeping the rows after the person removed the source is the worst version
-- of that.
--
-- ## What `forget_source` does, and what it deliberately does not
--
-- The shape is `0167`'s and `0139`'s: **observations are excluded, raw payloads
-- are redacted, nothing is deleted.** `ingestion_run_items` references
-- observations `on delete no action` and the payload is frozen by trigger, so a
-- delete either raises or destroys evidence the policy permits keeping.
-- `exclusion_code = 'user_deleted'` is the vocabulary already in use for exactly
-- this, 3,205 rows of it.
--
-- **It retires no assertion directly.** The scorer withdraws as well as raises,
-- and a term that loses its only witness is demoted by the next run — which is
-- better than this function guessing, because a concept attested by three
-- sources should survive losing one. The revision bump is what forces that run
-- to happen: a run's identity carries the revision, so without it
-- `enqueue_recompute_on_analysis_change` finds a run already exists and enqueues
-- nothing.
--
-- **One bump, not five hundred and eighty.** `0170` established the flag for
-- this and its reasoning applies unchanged; per-row bumping put `forget_distillation`
-- over `authenticated`'s eight-second `statement_timeout` at 2,709 rows. A
-- fourth named flag rather than reusing the third, because `0170` argues for
-- named flags in the trigger itself: a path that forgot to name itself would
-- silently invalidate every score its user has, and a flag naming the wrong
-- function is the same defect with better manners.

begin;

create or replace function semantic_private.bump_user_state_revision()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if coalesce(
       current_setting('written.finalize_ingestion_v031', true), '0'
     ) = '1'
     or coalesce(
       current_setting('written.close_unpromotable_v031', true), '0'
     ) = '1'
     or coalesce(
       current_setting('written.forget_distillation_v031', true), '0'
     ) = '1'
     -- The fourth: one source leaving, which moves as many rows as an erasure
     -- of that source and is one change to the person's state.
     or coalesce(
       current_setting('written.forget_source_v031', true), '0'
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

create or replace function api.forget_source(p_source text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
set statement_timeout to '60s'
as $$
declare
  me uuid := auth.uid();
  excluded_rows integer := 0;
  redacted integer := 0;
  connections integer := 0;
begin
  -- **No parameter for whose.** Every function in this schema is scoped to
  -- `auth.uid()`, so a caller cannot act on anybody but themselves. The source
  -- is a parameter because that *is* the question; the person is not.
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  if coalesce(p_source, '') = '' then
    raise exception 'a source is required' using errcode = '22023';
  end if;

  perform set_config('written.forget_source_v031', '1', true);

  update semantic_private.observations
     set lifecycle_state = 'excluded',
         exclusion_code  = 'user_deleted',
         excluded_at     = now()
   where user_id = me
     and source_code = p_source
     and lifecycle_state = 'active';
  get diagnostics excluded_rows = row_count;

  -- The ciphertext is destroyed. `raw_source_records_payload_location_check`
  -- refuses the row if the payload survives, so the state and the redaction
  -- cannot come apart.
  update semantic_private.raw_source_records
     set lifecycle_state   = 'deleted',
         deleted_at        = now(),
         encrypted_payload = null,
         raw_blob_ref      = null
   where user_id = me
     and source_code = p_source
     and lifecycle_state <> 'deleted';
  get diagnostics redacted = row_count;

  delete from semantic_private.source_connections
   where user_id = me and source_code = p_source;
  get diagnostics connections = row_count;

  -- The single bump the flag above suppressed, written only when something
  -- actually moved: disconnecting a source that never reached the vault is not
  -- a change to anybody's state.
  if excluded_rows > 0 or redacted > 0 then
    insert into semantic_private.user_state_versions (user_id, revision)
    values (me, 1)
    on conflict (user_id) do update
    set revision = semantic_private.user_state_versions.revision + 1,
        updated_at = now();
  end if;

  -- A receipt, for the same reason `forget_distillation` returns one: an
  -- erasure answering `void` makes "it did nothing" and "it never ran" the same
  -- observation from the client's side.
  return jsonb_build_object(
    'source', p_source,
    'observations_excluded', excluded_rows,
    'raw_records_redacted', redacted,
    'connections_removed', connections
  );
end;
$$;

revoke all on function api.forget_source(text) from public, anon;
grant execute on function api.forget_source(text) to authenticated;

-- ---------------------------------------------------------------------------
-- The repair, named rather than computed — and the first draft of it was wrong.
--
-- **It derived "disconnected" by joining vault `source_code` to
-- `public.source_connections.source`, and those two vocabularies are not the
-- same one.** The vault says `healthkit` where the app says `health`, which is
-- one of the two translation seams CLAUDE.md names and pins with a test, and
-- `semantic_private.sources` carries no app-side code to join on. So the join
-- read HealthKit as disconnected and the repair moved to redact 1,202 raw
-- records nobody had asked to remove. Its own assertion caught that and rolled
-- the whole migration back, which is the argument for writing the assertion
-- before trusting the query.
--
-- Re-deriving a seam that deliberately lives in one place is how it stops
-- having one place. So this names the pair it repairs, the way `0139` did, and
-- the general question — *which sources is this account still connected to* —
-- stays with the app, which knows both vocabularies and passes the vault's code
-- to `api.forget_source`.
--
-- Measured 2026-08-15: `eb769605…`, `spotify`, 580 active observations and 593
-- undeleted raw records, with no `source_connections` row on either side.
-- ---------------------------------------------------------------------------
do $$
declare
  subject uuid := 'eb769605-5e2c-4175-8b9d-e3864ceaafb1';
  excluded_rows integer := 0;
  redacted  integer := 0;
  remaining integer;
  enqueued  integer;
  healthkit_before integer;
begin
  -- **Counted rather than remembered.** The check below used to compare against
  -- 1202, which is what this database held on 2026-08-15 and nothing else ever.
  -- The rule is that disconnecting Spotify moves no HealthKit row, and that is
  -- answerable without knowing the number — the same repair `0092` and `0128`
  -- took when they named production's own contents.
  select count(*) into healthkit_before
    from semantic_private.raw_source_records
   where source_code = 'healthkit' and lifecycle_state <> 'deleted';
  perform set_config('written.forget_source_v031', '1', true);

  -- The state this repairs, asserted before it is repaired: a disconnect that
  -- left the vault untouched. If the connection is back, somebody reconnected
  -- and this migration must not quietly erase a live source.
  if exists (
    select 1 from public.source_connections
     where user_id = subject and source = 'spotify'
  ) then
    raise exception '0185: spotify is connected again — refusing to erase a live source';
  end if;

  update semantic_private.observations
     set lifecycle_state = 'excluded',
         exclusion_code  = 'user_deleted',
         excluded_at     = now()
   where user_id = subject
     and source_code = 'spotify'
     and lifecycle_state = 'active';
  get diagnostics excluded_rows = row_count;

  update semantic_private.raw_source_records
     set lifecycle_state   = 'deleted',
         deleted_at        = now(),
         encrypted_payload = null,
         raw_blob_ref      = null
   where user_id = subject
     and source_code = 'spotify'
     and lifecycle_state <> 'deleted';
  get diagnostics redacted = row_count;

  delete from semantic_private.source_connections
   where user_id = subject and source_code = 'spotify';

  if excluded_rows > 0 or redacted > 0 then
    insert into semantic_private.user_state_versions (user_id, revision)
    values (subject, 1)
    on conflict (user_id) do update
    set revision = semantic_private.user_state_versions.revision + 1,
        updated_at = now();
  end if;

  -- Nothing of that source may still be readable for this account.
  select count(*) into remaining
    from semantic_private.observations
   where user_id = subject and source_code = 'spotify' and lifecycle_state = 'active';
  if remaining <> 0 then
    raise exception '0185: % spotify observation(s) still active', remaining;
  end if;

  select count(*) into remaining
    from semantic_private.raw_source_records
   where user_id = subject and source_code = 'spotify' and lifecycle_state <> 'deleted';
  if remaining <> 0 then
    raise exception '0185: % spotify raw record(s) survive', remaining;
  end if;

  -- **And nothing else moved.** The first draft's failure was collateral, so
  -- the assertion that would have caught it stays: HealthKit is the source the
  -- name join misread, and it must be exactly as it was.
  select count(*) into remaining
    from semantic_private.raw_source_records
   where source_code = 'healthkit' and lifecycle_state <> 'deleted';
  if remaining <> healthkit_before then
    raise exception '0185: healthkit raw records moved — % before, % after',
      healthkit_before, remaining;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           '0185: spotify disconnected without a vault half'
         ) into enqueued;

  raise notice '0185: % observations excluded, % raw records redacted, % recompute job(s)',
    excluded_rows, redacted, enqueued;
end;
$$;

commit;
