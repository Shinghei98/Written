-- 0080 — the 30-day rule, extended to the vault.
--
-- **`0016` sweeps two stores and the vault is neither.** It deletes YouTube rows
-- from `public.distilled_records` and strips channel names from
-- `discovery_cards.interests`, and it was written before `semantic_private`
-- existed. Capturing YouTube into the vault without this would put video titles
-- and channel names into an **append-only** store whose ingestion identity holds
-- no `Decrypt` — the one mistake this schema makes permanent.
--
-- III.E.4 permits storing Analytics data, Reporting data and *statistics* beyond
-- 30 calendar days. Titles, channel names, descriptions and comment text are
-- "all other Authorized Data" and must be deleted or refreshed within 30. The
-- Content Categorization amendment does **not** relax this: read in full, its
-- 36-month relief covers statistics and derived metrics while *"other data (such
-- as video titles, creator names, descriptions, and comment text) must still
-- follow the 30-day refresh and deletion policy"*.
--
-- **This redacts; it does not delete rows, and that is forced three ways.**
--
--   1. `observation_mappings` is `on delete cascade` from `observations`.
--      Deleting an expired observation would destroy the derived evidence the
--      policy explicitly permits keeping — the opposite of what is being asked.
--   2. `ingestion_run_items` and `current_source_items` reference both tables
--      `on delete no action`, so a row delete fails on a foreign key rather than
--      doing anything.
--   3. The schema already models it. `raw_source_records_payload_location_check`
--      refuses `lifecycle_state = 'deleted'` unless **both** `encrypted_payload`
--      and `raw_blob_ref` are null, so the state and the redaction cannot
--      disagree: there is no way to mark a row deleted while its payload
--      remains. `lifecycle_state` has allowed `'expired'` since `0046`.
--
-- **`current_source_items` is deliberately untouched.** It carries hmacs,
-- fingerprints, identifiers and timestamps — no titles and no names. Sweeping it
-- would remove the record that an item was ever observed while deleting nothing
-- that is owed, and a head that lost an item reads as the item having gone away.

begin;

create or replace function public.sweep_youtube_vault_retention()
returns table (records_redacted bigint, observations_redacted bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
    redacted_records      bigint;
    redacted_observations bigint;
begin
    -- **`retained_until` when it is set, `created_at + 30 days` when it is not.**
    -- The column has existed since `0046` and is null on every one of the 4,739
    -- rows in the vault — nothing populates it and nothing enforced it, which is
    -- this codebase's "a value nobody reads" defect in a column. Honouring it
    -- first means an ingestion path that starts stamping a shorter deadline is
    -- obeyed without touching this function; the fallback is what makes the rule
    -- true today.
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

    -- **The projection too, because it is derived from the titles.**
    -- `normalized_payload` is `not null`, so it is emptied rather than nulled.
    -- The row survives and so do its `observation_mappings`: a mapping is
    -- derived output and may persist, which is the whole shape of `0016`'s
    -- "derive, then delete the raw" and the reason this is not a delete.
    with expired as (
        update semantic_private.observations
        set normalized_payload = '{}'::jsonb,
            lifecycle_state    = 'deleted'
        where source_code = 'youtube'
          and lifecycle_state <> 'deleted'
          and created_at + interval '30 days' <= now()
        returning 1
    )
    select count(*) into redacted_observations from expired;

    return query select redacted_records, redacted_observations;
end;
$$;

-- Same reasoning as `0016`: the sweep runs as a scheduled job with no session
-- behind it, every policy in these schemas denies the client roles outright, and
-- nothing signed in has any business invoking a function that redacts across all
-- accounts.
revoke all on function public.sweep_youtube_vault_retention() from public;
revoke all on function public.sweep_youtube_vault_retention() from anon, authenticated;

-- Ten minutes after `0016`'s sweep rather than alongside it. They are
-- independent obligations over independent stores, and a failure in one should
-- be readable as a failure in that one — `net._http_response` and `cron.job_run_details`
-- both key on the job, so sharing a slot would blur which store went unswept.
select cron.schedule(
    'youtube-vault-retention',
    '27 3 * * *',
    $$select public.sweep_youtube_vault_retention()$$
);

-- The predicate the sweep runs on, so it stays a scan of the expiring tail.
-- Partial on `youtube` and on not-yet-redacted rows: once a row is `deleted` it
-- never matches again, so it should not stay in the index either.
create index if not exists raw_source_records_youtube_expiry_idx
    on semantic_private.raw_source_records (created_at, retained_until)
    where source_code = 'youtube' and lifecycle_state <> 'deleted';

create index if not exists observations_youtube_expiry_idx
    on semantic_private.observations (created_at)
    where source_code = 'youtube' and lifecycle_state <> 'deleted';

commit;
