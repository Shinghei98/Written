-- 0081 — `0080` would have raised on every run.
--
-- **`guard_observation_immutable` refuses exactly what `0080` did.** Its list of
-- frozen columns includes `normalized_payload`, so the sweep's second statement
--
--     update semantic_private.observations set normalized_payload = '{}'::jsonb
--
-- raises *"observation evidence is append-only"* — every night, and because the
-- statements share a function, the rollback would take the `raw_source_records`
-- redaction with it. The obligation would have gone unmet while a scheduled job
-- appeared to exist to meet it, which is worse than having written nothing.
--
-- plpgsql only syntax-checks a body at creation. A guard that refuses an update
-- is a runtime fact, and `0080` was applied without one ever running.
--
-- **Read as intent rather than as an obstacle, the guard settles the design.**
-- An observation is append-only evidence; its projection is not a place raw text
-- may be stored and later scrubbed. So the projection must never contain a
-- YouTube title or channel name in the first place, and then there is nothing in
-- it to redact — which is exactly the posture Calendar and HealthKit already
-- have, where the endpoint sends no `normalized_payload` at all because
-- `private_observation_projection_is_valid_v03` demands a classifier's output
-- rather than a transcription.
--
-- That makes the rule a **requirement on the YouTube projection**, enforced
-- where it belongs, rather than a nightly scrub: the projection may carry
-- provider topics, uploader tags, category ids and channel ids — labels and
-- identifiers — and must not carry titles, channel names or descriptions.
-- `raw_source_records` keeps the full payload, encrypted, and *that* is what
-- expires at 30 days.
--
-- Marking observations `deleted` was also considered and dropped. It is
-- permitted — `lifecycle_state` is not in the immutable list — but it would
-- remove an item from current state for no compliance reason, and
-- `observation_lifecycle_bump_semantic_revision` fires on the update, so a
-- nightly sweep would bump every affected user's state revision and mark any
-- in-flight semantic run stale. Cost with no obligation behind it.

begin;

-- **Dropped, not replaced.** The return type loses a column — two counts become
-- one — and `create or replace` cannot change a return type: it fails outright
-- with *"cannot change return type of existing function"*. This is `0026`/`0027`'s
-- lesson with the signature swapped for the result: changing a function's shape
-- means naming the old one in a `drop`. `cron.job` stores its command as text
-- and holds no dependency, so the schedule survives the drop and binds to the
-- new function by name.
drop function if exists public.sweep_youtube_vault_retention();

create function public.sweep_youtube_vault_retention()
returns table (records_redacted bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
    redacted_records bigint;
begin
    -- **One store, and it is the one that holds the text.**
    -- `raw_source_records_payload_location_check` refuses `lifecycle_state =
    -- 'deleted'` unless both `encrypted_payload` and `raw_blob_ref` are null, so
    -- the state and the redaction cannot disagree — there is no way to mark a
    -- row deleted while its payload survives.
    --
    -- `guard_raw_source_record_update` permits this exact transition and blocks
    -- the ones that would be wrong: identity, source, purpose and provenance are
    -- immutable, a deleted row is terminal, and retention may be shortened but
    -- never extended in place.
    --
    -- Rows are not deleted. `observation_mappings` cascades from `observations`
    -- and `ingestion_run_items` references both `on delete no action`, so a row
    -- delete would either destroy derived evidence the policy permits keeping or
    -- fail on a foreign key.
    with expired as (
        update semantic_private.raw_source_records
        set lifecycle_state   = 'deleted',
            deleted_at        = now(),
            encrypted_payload = null,
            raw_blob_ref      = null
        where source_code = 'youtube'
          and lifecycle_state <> 'deleted'
          and coalesce(retained_until, created_at + interval '30 days') <= now()
        returning 1
    )
    select count(*) into redacted_records from expired;

    return query select redacted_records;
end;
$$;

revoke all on function public.sweep_youtube_vault_retention() from public;
revoke all on function public.sweep_youtube_vault_retention() from anon, authenticated;

-- `0080`'s index on `observations` is dropped with the statement that used it.
-- An index maintained for a predicate nothing runs is a cost with no reader.
drop index if exists semantic_private.observations_youtube_expiry_idx;

commit;
