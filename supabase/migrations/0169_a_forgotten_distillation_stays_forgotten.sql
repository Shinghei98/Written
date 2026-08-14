-- 0169 — a forgotten distillation stays forgotten.
--
-- ## What happened, with the timestamps, because they are the whole argument
--
-- On 2026-08-14 the demo account was disconnected and then, an hour later, its
-- terms came back — not because anybody reconnected anything, but because we
-- deployed a migration.
--
--   17:38:37  Disconnect all runs. `api.forget_distillation` redacts 551
--             YouTube raw records in one statement, empties the vault's
--             `source_connections`, and retires every inferred assertion.
--   17:39     outlook, podcasts and spotify are connected fresh.
--   18:39:11  `0168`'s `enqueue_recompute_on_analysis_change` re-scores the
--             account, and **all 66 assertions are written back to
--             `eligible`** — every one of them carrying that timestamp, from a
--             single statement.
--
-- The control fired and did exactly what it was written to do. What it was
-- written to do was not durable: it retired the *claims* and left the
-- *evidence* `active`, and `score.py` writes whichever state a run computes.
--
-- **The design note anticipated one way that happens and only one.**
-- *"Reconnecting and distilling revives a term rather than needing a repair"*
-- is right, and is about the person choosing to come back. But a run's identity
-- is `(user, revision, ontology version, resolver, scorer)`, and two of those
-- move without the person doing anything at all. Publishing an ontology version
-- was enough. So somebody asked to be forgotten, was told they had been, and a
-- deploy of ours put their terms back on their profile — and, through
-- `matching_terms`, potentially in front of another person.
--
-- ## What changes
--
-- **The evidence goes out of scoring, and that is the load-bearing line.**
-- `resolve.py` selects `o.lifecycle_state = 'active'`, and mappings are made
-- per run rather than reused — `score.py` aggregates `where m.semantic_run_id =
-- %(run)s` — so an observation that is not `active` is never re-mapped and
-- therefore never re-scored. Retirement alone could be undone by any future
-- run; this cannot be undone by anything except the person distilling again,
-- which is the one revival the note actually meant.
--
-- `'deleted'` with `exclusion_code = 'user_deleted'` and a non-null
-- `excluded_at` is the shape the schema already sanctions:
-- `private_observation_projection_is_valid_v03` names those three together for
-- every private-lane source, `user_deleted` is the code already in use, and
-- `guard_observation_immutable` freezes every column except these three. So
-- this is an erasure the schema was built to accept rather than one it has to
-- be talked into.
--
-- **Redaction covers every source, not only YouTube** (owner, 2026-08-14). The
-- old scope followed the retention obligation, which only YouTube has. But the
-- vault's whole argument is that capture may be broad *because* promotion is
-- narrow, and that cuts both ways when somebody withdraws: what they are asking
-- to be rid of is the capture. One Apple Music library was 1,201 raw records
-- against 551 YouTube ones on the account this was found on.
--
-- **`explicit_addition` still survives** (owner, same date). What somebody
-- typed into Memories is the same fact as a `source = 'user'` row in the legacy
-- path — it was not read off their phone, and `deleteEverything` keeps those
-- for the identical reason.
--
-- **Rows are still never deleted.** `ingestion_run_items` references
-- observations and raw records `on delete no action` and refuses every
-- operation that is not an `INSERT`, so a delete would either raise or destroy
-- evidence the policy permits keeping. Erasure is redaction, in both stores.
--
-- ## The check this incident would have failed
--
-- The exercise below asserts, over the real vault and rolled back, that after
-- the erasure **no observation of that user is left `active`**. That is the
-- statement "the terms cannot come back" reduced to something a migration can
-- test, because it is the exact predicate the resolver filters on. `0167`'s
-- exercise asserted that payloads were unreadable and that hand-added claims
-- survived, and both were true on the 14th while the page refilled anyway.

begin;

create or replace function api.forget_distillation()
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  me uuid := auth.uid();
  retired integer := 0;
  excluded_rows integer := 0;
  redacted integer := 0;
begin
  -- **No parameter for whose.** Every function in this schema is scoped to
  -- `auth.uid()`, so a caller cannot act on anybody but themselves.
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;

  -- 1. The claims. Inferred only — see the header on `explicit_addition`.
  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where user_id = me
     and assertion_origin = 'inferred'
     and machine_state <> 'inactive';
  get diagnostics retired = row_count;

  -- 2. **The evidence, out of scoring.** The step `0167` did not have, and the
  --    only one that makes the others durable: `resolve.py` filters
  --    `lifecycle_state = 'active'`, so nothing here is ever mapped again.
  update semantic_private.observations
     set lifecycle_state = 'deleted',
         exclusion_code  = 'user_deleted',
         excluded_at     = now()
   where user_id = me
     and lifecycle_state <> 'deleted';
  get diagnostics excluded_rows = row_count;

  -- 3. The captured payloads, every source. `raw_source_records_payload_location_check`
  --    refuses `lifecycle_state = 'deleted'` unless both columns are null, so
  --    the state and the redaction cannot disagree, and
  --    `guard_raw_source_record_update` permits this exact transition.
  update semantic_private.raw_source_records
     set lifecycle_state   = 'deleted',
         deleted_at        = now(),
         encrypted_payload = null,
         raw_blob_ref      = null
   where user_id = me
     and lifecycle_state <> 'deleted';
  get diagnostics redacted = row_count;

  -- 4. The vault's own connection rows, for every source.
  delete from semantic_private.source_connections
   where user_id = me;

  -- **A receipt, because the caller must not have to guess.** An erasure
  -- answering `void` would make "the terms are still there" and "the call never
  -- ran" the same observation from the client's side. `youtube_records_redacted`
  -- is gone rather than kept at zero: the count no longer means what its name
  -- says, and the app discards the receipt, so nothing reads it into a lie.
  return jsonb_build_object(
    'assertions_retired', retired,
    'observations_excluded', excluded_rows,
    'records_redacted', redacted
  );
end;
$$;

revoke all on function api.forget_distillation() from public, anon;
grant execute on function api.forget_distillation() to authenticated;

commit;

-- The exercise, in its own transaction so a failure here cannot leave the
-- function half-replaced. Same shape as `0167`: run the work over the real
-- vault inside a subtransaction, keep the counts in PL/pgSQL variables — which
-- are memory and survive a rollback — raise deliberately, and let the
-- subtransaction undo every row. `walked` is what tells our own exception from
-- a real one, and is set on the last line of the block.

begin;

do $$
declare
  subject uuid;
  refused boolean := false;
  walked boolean := false;
  excluded_rows integer := -1;
  redacted integer := -1;
  survivors_active integer := -1;
  survivors_payload integer := -1;
  hand_added_before integer := -1;
  hand_added_after integer := -1;
  active_before integer;
  active_after integer;
  payloads_before integer;
  payloads_after integer;
begin
  -- Counted before anything runs and compared after, rather than asserted
  -- non-zero: a check resting on data existing reports the state of the
  -- fixture, which is how `0167`'s first draft passed here and failed on a
  -- clean replay.
  select count(*) into active_before
    from semantic_private.observations where lifecycle_state = 'active';
  select count(*) into payloads_before
    from semantic_private.raw_source_records where lifecycle_state <> 'deleted';
  select count(*) into hand_added_before
    from semantic_private.user_assertions
   where assertion_origin = 'explicit_addition' and machine_state <> 'inactive';

  -- **The refusal, first.** The function takes no user id and reads
  -- `auth.uid()`; a migration has none, so it must refuse rather than act on
  -- whatever null resolves to. A deletion that treats "nobody" as a caller is
  -- the one bug here that would be both silent and enormous.
  begin
    perform api.forget_distillation();
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception '0169: forget_distillation acted for a caller with no identity';
  end if;
  raise notice '0169: an unidentified caller is refused';

  select user_id into subject
    from semantic_private.observations
   where lifecycle_state = 'active'
   group by user_id
   order by count(*) desc
   limit 1;

  if subject is null then
    raise notice '0169: no live observations here; the erasure is unexercised';
  else
    begin
      update semantic_private.observations
         set lifecycle_state = 'deleted',
             exclusion_code  = 'user_deleted',
             excluded_at     = now()
       where user_id = subject and lifecycle_state <> 'deleted';
      get diagnostics excluded_rows = row_count;

      update semantic_private.raw_source_records
         set lifecycle_state   = 'deleted',
             deleted_at        = now(),
             encrypted_payload = null,
             raw_blob_ref      = null
       where user_id = subject and lifecycle_state <> 'deleted';
      get diagnostics redacted = row_count;

      update semantic_private.user_assertions
         set machine_state = 'inactive', updated_at = now()
       where user_id = subject
         and assertion_origin = 'inferred'
         and machine_state <> 'inactive';

      -- **This is the assertion the incident is named after.** Not "the claims
      -- are retired" — they were, on the 14th, and came back an hour later.
      -- The durable statement is that nothing remains for a later run to
      -- resolve, and `lifecycle_state = 'active'` is the exact predicate
      -- `resolve.py` selects on.
      select count(*) into survivors_active
        from semantic_private.observations
       where user_id = subject and lifecycle_state = 'active';

      -- The check constraint should make a readable payload impossible;
      -- asserting it is how we find out it still does.
      select count(*) into survivors_payload
        from semantic_private.raw_source_records
       where user_id = subject
         and (encrypted_payload is not null or raw_blob_ref is not null);

      -- **The line that is most likely to be simplified away by a later
      -- reader**, so it is checked here rather than trusted to the `where`.
      select count(*) into hand_added_after
        from semantic_private.user_assertions
       where assertion_origin = 'explicit_addition' and machine_state <> 'inactive';

      walked := true;
      raise exception '0169 dry run' using errcode = '22000';
    exception when others then
      if not walked then raise; end if;
    end;

    if excluded_rows <= 0 then
      raise exception '0169: the erasure excluded nothing for a user with live observations';
    end if;
    if survivors_active <> 0 then
      raise exception
        '0169: % observations stayed active through the erasure and a re-score would revive them',
        survivors_active;
    end if;
    if survivors_payload <> 0 then
      raise exception '0169: % records kept a payload through redaction', survivors_payload;
    end if;
    if hand_added_after <> hand_added_before then
      raise exception '0169: the erasure took % hand-added assertions with it',
        hand_added_before - hand_added_after;
    end if;
    raise notice
      '0169: the erasure excludes % observations and redacts % records, leaving nothing active, nothing readable and % hand-added claims — and is rolled back',
      excluded_rows, redacted, hand_added_after;
  end if;

  -- **Proof the rollback held**, rather than a comment claiming it did. Had the
  -- subtransaction committed, this migration would be the thing that erased a
  -- person's vault.
  select count(*) into active_after
    from semantic_private.observations where lifecycle_state = 'active';
  select count(*) into payloads_after
    from semantic_private.raw_source_records where lifecycle_state <> 'deleted';

  if active_after <> active_before or payloads_after <> payloads_before then
    raise exception
      '0169: the exercise did not roll back — active observations % to %, payloads % to %',
      active_before, active_after, payloads_before, payloads_after;
  end if;
  raise notice '0169: nothing moved — % active observations and % readable records, as before',
    active_after, payloads_after;
end;
$$;

commit;
