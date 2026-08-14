-- The erasure redacts rather than deletes, and is exercised over real rows
--
-- **`0166` shipped a YouTube branch that could not run.** It deleted from nine
-- tables in foreign-key order, and the first statement raised
-- *"ingestion run membership is append-only"* — `guard_ingestion_run_item_v031`
-- refuses every operation that is not an `INSERT`, with no escape hatch of any
-- kind. So the FK order was right, the reasoning about `no action` was right,
-- and the whole branch was dead on the first press of *Disconnect all*: the
-- legacy half would have committed, the vault half would have raised, and the
-- person would have been told their terms were still there with no way to make
-- them go.
--
-- **Found by exercising it, not by reading it**, which is the only reason it is
-- being fixed here rather than by a user. A deletion cannot be checked by
-- inspection.
--
-- **The mechanism already existed and I invented a worse one.**
-- `public.sweep_youtube_vault_retention` states it outright in its own comment:
-- *"Rows are not deleted. `observation_mappings` cascades from `observations`
-- and `ingestion_run_items` references both `on delete no action`, so a row
-- delete would either destroy derived evidence the policy permits keeping or
-- fail on a foreign key."* What it does instead is **redact** — mark the row
-- `deleted` and null `encrypted_payload` and `raw_blob_ref` in one statement.
-- `invalidate_healthkit_use_on_revocation` does exactly the same three columns
-- when a Health grant is withdrawn, so redaction-on-revocation is a settled
-- pattern here with two precedents, and this is the third.
--
-- **The redaction cannot come apart from the state.**
-- `raw_source_records_payload_location_check` refuses `lifecycle_state =
-- 'deleted'` unless both payload columns are null, so there is no way to mark a
-- row deleted while its content survives — and `guard_raw_source_record_update`
-- permits this exact transition while refusing the ones that would be wrong.
-- Nothing here needs a new guard, a new flag, or an exemption.
--
-- **Why it is immediate rather than on the 30-day clock.** The sweep would
-- reach these rows within 30 days anyway; the Developer Policies allow 7 for a
-- revocation *made in the client*, and *Disconnect all* is that revocation. So
-- this does what the sweep does, now, for one person, and the two agree about
-- what erasure means.
--
-- **What is left standing, deliberately.** The observations, which carry
-- topics, tags, a category id and a channel id and **no title, channel name or
-- description** — the projection excludes them by construction, which is the
-- reason the 30-day sweep does not touch this table either. The privacy page
-- has said for as long as it has existed that what outlives is *"counts, and
-- the subjects Written worked out while the data was there"*. Retiring the
-- assertions is what makes those subjects stop being shown or counted.

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
  redacted integer := 0;
begin
  -- **No parameter for whose.** Every function in this schema is scoped to
  -- `auth.uid()`, so a caller cannot act on anybody but themselves.
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;

  -- 1. The claims. Inferred only: an `explicit_addition` is what the person
  --    typed in Memories, which is the same fact as a `source = 'user'` row in
  --    the legacy path, and `deleteEverything` keeps those for the same reason.
  --    Retirement is `inactive` rather than deletion, so reconnecting and
  --    distilling revives the term — `score.py`'s `UPDATE_ASSERTION` writes
  --    whichever state a run computes.
  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where user_id = me
     and assertion_origin = 'inferred'
     and machine_state <> 'inactive';
  get diagnostics retired = row_count;

  -- 2. YouTube's captured payloads, redacted the way the sweep redacts them.
  update semantic_private.raw_source_records
     set lifecycle_state   = 'deleted',
         deleted_at        = now(),
         encrypted_payload = null,
         raw_blob_ref      = null
   where user_id = me
     and source_code = 'youtube'
     and lifecycle_state <> 'deleted';
  get diagnostics redacted = row_count;

  -- 3. The vault's own connection rows, for every source.
  delete from semantic_private.source_connections
   where user_id = me;

  -- **A receipt, because the caller must not have to guess.** An erasure
  -- answering `void` would make "the terms are still there" and "the call never
  -- ran" the same observation from the client's side.
  return jsonb_build_object(
    'assertions_retired', retired,
    'youtube_records_redacted', redacted
  );
end;
$$;

revoke all on function api.forget_distillation() from public, anon;
grant execute on function api.forget_distillation() to authenticated;

commit;

-- The exercise, in its own transaction so a failure here cannot leave the
-- function half-replaced.
--
-- **A `begin … exception` block is a savepoint**, and PL/pgSQL variables are
-- memory rather than table rows, so they survive the rollback the exception
-- performs. Run the work over the real vault, keep the counts, raise
-- deliberately, and let the subtransaction undo every row.
--
-- **`walked` is what tells our own exception from a real one.** Without it the
-- handler would swallow a genuine guard violation and this would pass by
-- catching the failure it exists to detect — which is precisely how `0166`'s
-- branch would have been declared fine. So the flag is set on the last line of
-- the block, and anything raised before it is re-raised untouched.

begin;

do $$
declare
  subject uuid;
  redacted integer := -1;
  survivors_payload integer := -1;
  walked boolean := false;
  retired integer := -1;
  hand_added_before integer := -1;
  hand_added_after integer := -1;
  retirement_walked boolean := false;
  refused boolean := false;
begin
  -- 1. **The refusal, first.** The function takes no user id and reads
  --    `auth.uid()`; a migration has none, so it must refuse rather than act on
  --    whatever null resolves to. A deletion that treats "nobody" as a caller
  --    is the one bug here that would be both silent and enormous.
  begin
    perform api.forget_distillation();
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception '0167: forget_distillation acted for a caller with no identity';
  end if;
  raise notice '0167: an unidentified caller is refused';

  select user_id into subject
    from semantic_private.raw_source_records
   where source_code = 'youtube' and lifecycle_state <> 'deleted'
   group by user_id
   order by count(*) desc
   limit 1;

  if subject is null then
    raise notice '0167: no live YouTube records here; redaction unexercised';
  else
    begin
      update semantic_private.raw_source_records
         set lifecycle_state   = 'deleted',
             deleted_at        = now(),
             encrypted_payload = null,
             raw_blob_ref      = null
       where user_id = subject
         and source_code = 'youtube'
         and lifecycle_state <> 'deleted';
      get diagnostics redacted = row_count;

      -- **The claim worth checking is that nothing readable survives**, not
      -- that an update ran. The check constraint should make this impossible;
      -- asserting it is how we find out it still does.
      select count(*) into survivors_payload
        from semantic_private.raw_source_records
       where user_id = subject
         and source_code = 'youtube'
         and (encrypted_payload is not null or raw_blob_ref is not null);

      walked := true;
      raise exception '0167 dry run' using errcode = '22000';
    exception when others then
      if not walked then raise; end if;
    end;

    if redacted <= 0 then
      raise exception '0167: redaction touched nothing for a user who has live records';
    end if;
    if survivors_payload <> 0 then
      raise exception '0167: % YouTube records kept a payload through redaction',
        survivors_payload;
    end if;
    raise notice
      '0167: redaction clears % YouTube payloads leaving none readable, and is rolled back',
      redacted;
  end if;

  -- 2. The retirement, likewise rolled back — and the line it draws.
  --
  -- **`explicit_addition` surviving is the assertion worth making**, because it
  -- is the one a later reader is most likely to simplify away.
  select count(*) into hand_added_before
    from semantic_private.user_assertions
   where assertion_origin = 'explicit_addition' and machine_state <> 'inactive';

  begin
    update semantic_private.user_assertions
       set machine_state = 'inactive', updated_at = now()
     where assertion_origin = 'inferred'
       and machine_state <> 'inactive';
    get diagnostics retired = row_count;

    select count(*) into hand_added_after
      from semantic_private.user_assertions
     where assertion_origin = 'explicit_addition' and machine_state <> 'inactive';

    retirement_walked := true;
    raise exception '0167 dry run' using errcode = '22000';
  exception when others then
    if not retirement_walked then raise; end if;
  end;

  if hand_added_after <> hand_added_before then
    raise exception '0167: retiring inferred claims took % hand-added assertions with it',
      hand_added_before - hand_added_after;
  end if;
  raise notice
    '0167: retirement clears % inferred claims and leaves % hand-added, and is rolled back',
    retired, hand_added_after;
end;
$$;

-- **Proof the rollback held**, rather than a comment claiming it did. Had
-- either subtransaction committed, this migration would be the thing that
-- erased a person's vault.
do $$
declare
  live_youtube integer;
  live_assertions integer;
begin
  select count(*) into live_youtube
    from semantic_private.raw_source_records
   where source_code = 'youtube' and lifecycle_state <> 'deleted';
  select count(*) into live_assertions
    from semantic_private.user_assertions
   where assertion_origin = 'inferred' and machine_state <> 'inactive';

  if live_youtube = 0 or live_assertions = 0 then
    raise exception '0167: the exercise did not roll back — % live records, % live claims',
      live_youtube, live_assertions;
  end if;
  raise notice '0167: after the exercise, % YouTube records and % inferred claims stand',
    live_youtube, live_assertions;
end;
$$;

commit;
