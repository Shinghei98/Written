-- Written — initial schema.
--
-- One row per distilled record, keyed the way the app already thinks about
-- them. Run this in the Supabase SQL editor, or `supabase db push`.
--
-- Two things here are load-bearing rather than stylistic, and both are
-- explained where they happen: the composite primary key on distilled_records,
-- and row-level security on every table. With Supabase the client talks to
-- Postgres directly, so RLS *is* the authorisation layer — a table with it off
-- is a table any signed-in user can read in full.

-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------

-- Mirrors auth.users, which we cannot add columns to. The id is the same uuid,
-- so `auth.uid()` joins straight through and every policy below is one
-- comparison rather than a subquery.
create table public.users (
    id          uuid primary key references auth.users (id) on delete cascade,
    phone       text unique,
    first_name  text,
    last_name   text,
    created_at  timestamptz not null default now()
);

-- Which apps a user has connected, and when they last yielded anything.
-- `record_count` is denormalised on purpose: the garden asks "is this branch
-- grown?" on every render, and that question should not count a table.
create table public.source_connections (
    user_id           uuid not null references public.users (id) on delete cascade,
    source            text not null,          -- spotify | apple_music | youtube | health | location | user
    connected_at      timestamptz not null default now(),
    last_distilled_at timestamptz,
    record_count      integer not null default 0,
    primary key (user_id, source)
);

-- ---------------------------------------------------------------------------
-- The distillation
-- ---------------------------------------------------------------------------

create table public.distilled_records (
    user_id      uuid not null references public.users (id) on delete cascade,
    source       text not null,
    data_type    text not null,
    item_id      text not null,
    name         text not null default '',
    creator      text not null default '',
    detail       text not null default '',

    -- `extra` is `key=value;key=value` on the device — see CLAUDE.md and
    -- DistilledRecord.extraValue. Stored parsed so the ontology stage can ask
    -- `extra->>'genres'` instead of doing string surgery in SQL.
    extra        jsonb not null default '{}'::jsonb,

    collected_at timestamptz not null,

    -- Promoted out of `extra`, where the app currently hides them (BanList.swift
    -- writes removed_at / removed_reason into the string). A struck-off record
    -- is kept and annotated rather than deleted, so these need to be filterable.
    removed_at     timestamptz,
    removed_reason text,

    -- Not a surrogate id. DistilledRecord.id is a locally-generated UUID that
    -- changes on every distill, so it identifies nothing; these four columns
    -- already identify a row uniquely, which is why deduplicatedSongs() dedupes
    -- on item_id today. This key is also what makes re-distilling idempotent.
    primary key (user_id, source, data_type, item_id)
);

create index distilled_records_user_source_idx
    on public.distilled_records (user_id, source);
create index distilled_records_user_type_idx
    on public.distilled_records (user_id, data_type);
-- For the ontology stage, which filters on keys inside `extra`.
create index distilled_records_extra_idx
    on public.distilled_records using gin (extra);

-- ---------------------------------------------------------------------------
-- Health — derived signals only
-- ---------------------------------------------------------------------------
--
-- Raw HealthKit rows (workout, activity_day, activity_hour) are deliberately
-- absent from this database and must never be inserted into distilled_records.
-- Only what LifestyleHighlights computes on-device travels: the chronotype band
-- and sport levels. That keeps the most sensitive category off the server and
-- clear of App Review guideline 5.1.3, and costs the ontology stage nothing it
-- actually consumes.

create table public.health_signals (
    user_id             uuid primary key references public.users (id) on delete cascade,
    chronotype_label    text,                -- "Early riser" | "Morning person" | "Steady starter" | "Late riser"
    median_wake_minutes integer,             -- minutes past midnight
    spread_minutes      integer,             -- median absolute deviation
    days_observed       integer,
    average_daily_steps integer,
    updated_at          timestamptz not null default now()
);

create table public.health_sports (
    user_id  uuid not null references public.users (id) on delete cascade,
    sport    text not null,                  -- as HealthKitDistiller.name(for:) spells it
    sessions integer not null default 0,
    minutes  integer not null default 0,
    primary key (user_id, sport)
);

-- ---------------------------------------------------------------------------
-- What the user struck off
-- ---------------------------------------------------------------------------

create table public.bans (
    user_id uuid not null references public.users (id) on delete cascade,
    kind    text not null,                   -- artist | channel | sport
    value   text not null,
    banned_at timestamptz not null default now(),
    primary key (user_id, kind, value)
);

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.users              enable row level security;
alter table public.source_connections enable row level security;
alter table public.distilled_records  enable row level security;
alter table public.health_signals     enable row level security;
alter table public.health_sports      enable row level security;
alter table public.bans               enable row level security;

create policy "own row" on public.users
    for all using (auth.uid() = id) with check (auth.uid() = id);

create policy "own rows" on public.source_connections
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own rows" on public.distilled_records
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own rows" on public.health_signals
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own rows" on public.health_sports
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own rows" on public.bans
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Replacing one source's records atomically
-- ---------------------------------------------------------------------------
--
-- The app's rule is that re-distilling a source *replaces* that source's rows
-- rather than duplicating them — see DistillViewModel.replaceRecords(from:with:),
-- whose comment notes that distilling YouTube twice must not duplicate rows.
-- Delete-then-insert from the client would leave a source half-written if the
-- connection dropped between the two, so it happens here, in one transaction.
create function public.replace_source_records(
    p_source  text,
    p_records jsonb
) returns integer
language plpgsql
security invoker            -- runs as the caller, so RLS still applies
as $$
declare
    inserted integer;
begin
    delete from public.distilled_records
     where user_id = auth.uid() and source = p_source;

    insert into public.distilled_records
        (user_id, source, data_type, item_id, name, creator, detail,
         extra, collected_at, removed_at, removed_reason)
    select
        auth.uid(),
        p_source,
        r ->> 'data_type',
        r ->> 'item_id',
        coalesce(r ->> 'name', ''),
        coalesce(r ->> 'creator', ''),
        coalesce(r ->> 'detail', ''),
        coalesce(r -> 'extra', '{}'::jsonb),
        (r ->> 'collected_at')::timestamptz,
        (r ->> 'removed_at')::timestamptz,
        r ->> 'removed_reason'
    from jsonb_array_elements(p_records) as r
    -- A source can hand back the same item twice across endpoints (a song that
    -- is both a top track and in a playlist). The composite key would reject
    -- the batch; keeping the first occurrence matches what the device does.
    on conflict (user_id, source, data_type, item_id) do nothing;

    get diagnostics inserted = row_count;

    insert into public.source_connections (user_id, source, last_distilled_at, record_count)
    values (auth.uid(), p_source, now(), inserted)
    on conflict (user_id, source) do update
        set last_distilled_at = now(), record_count = excluded.record_count;

    return inserted;
end;
$$;
