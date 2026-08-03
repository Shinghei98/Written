-- Somebody telling us about somebody else.
--
-- **Blocking is not here, and does not need to be.** `public.bans` already
-- carries `(user_id, kind, value)` with `kind` a plain text column, so a
-- `person` row is a legal insert today — and it inherits the local cache, the
-- push in `SyncService.pushBans` and the restore, which is the whole of the
-- machinery an unmatch needs. This table exists only for the *words* somebody
-- writes in the report sheet, which have nowhere else to live.

create table if not exists public.reports (
    id           uuid primary key default gen_random_uuid(),
    reporter_id  uuid not null references public.users (id) on delete cascade,
    -- **Not a foreign key**, deliberately, unlike every other user reference in
    -- this schema. `on delete cascade` would erase a report the moment the
    -- reported account went away, which is exactly the account most likely to
    -- go away and exactly the report most worth keeping. The id is stored raw so
    -- the row outlives the person.
    reported_id  uuid not null,
    -- Denormalised for the same reason `likes.liker_name` is: whoever reads
    -- these cannot look a name up, because `public.users` is `auth.uid() = id`.
    reported_name text,
    body         text not null check (length(btrim(body)) > 0),
    created_at   timestamptz not null default now()
);

create index if not exists reports_reported_idx on public.reports (reported_id, created_at desc);

alter table public.reports enable row level security;

-- Insert your own, read your own, change nothing. There is no update policy and
-- no delete policy: a report is a statement somebody made at a moment, and one
-- that can be edited afterwards is worth less than one that cannot.
create policy "own reports" on public.reports
    for select using (auth.uid() = reporter_id);

create policy "report as yourself" on public.reports
    for insert with check (auth.uid() = reporter_id);

-- Nothing in the app reads this table. It is read by a person, out of band,
-- which is what the sheet's "every report is read by a person" promises — and
-- that promise is a commitment to a process, not to a query.
