-- Somebody taken out of one person's discovery stack, without an accusation.
--
-- **This deliberately does not reuse `public.bans`**, and the trade is worth
-- writing down because the other choice was cheaper. A `kind = 'removed'` row
-- there would have inherited the whole pipeline free — the local cache that
-- makes a removal instant, the push in `SyncService.pushBans`, the restore, and
-- the filtering the feed already does — and it was rejected on purpose: a
-- removal and a report are different statements about a person, and a table
-- that has to be filtered by `kind` to tell them apart is a table where the
-- next query forgets to.
--
-- So the cost is accepted knowingly: its own service, its own restore leg, its
-- own place in the hiding set. What it buys is that "who has this person been
-- removed by" is a question with a one-line answer, forever.
--
-- `0014_reports.sql` argues the opposite way about blocking, and both are right
-- for what they are: blocking after a *report* is the same act as unmatching,
-- and belongs with it.

create table if not exists public.remove_list (
    id          uuid primary key default gen_random_uuid(),
    -- Whose stack this person was taken out of.
    remover_id  uuid not null references public.users (id) on delete cascade,
    -- **Not a foreign key**, for the reason `reports.reported_id` gives: a
    -- cascade would erase the removal the moment the removed account went away,
    -- and an account that goes away is exactly the one whose removals matter.
    -- The removal is also a fact about the *remover*, and outlives the other
    -- party either way.
    removed_id  uuid not null,
    created_at  timestamptz not null default now(),

    -- Removing somebody twice is the same removal. Nothing in the app should be
    -- able to make a second row, and if it tries, the upsert says so quietly
    -- rather than growing the table — see `ignore-duplicates` in the service.
    unique (remover_id, removed_id)
);

-- The only question asked of this table by the app: "who have I removed?",
-- every launch, for the feed's exclusion set.
create index if not exists remove_list_remover_idx
    on public.remove_list (remover_id, created_at desc);

alter table public.remove_list enable row level security;

-- Your own rows, and no more. **Deliberately not readable by the person
-- removed** — being able to ask "who has removed me" is a feature nobody wants
-- built, and a policy is the only place it can be prevented for good.
create policy "own removals" on public.remove_list
    for select using (auth.uid() = remover_id);

create policy "remove as yourself" on public.remove_list
    for insert with check (auth.uid() = remover_id);

-- **A delete policy, unlike `reports`.** A report is a statement somebody made
-- at a moment and is worth more for being unretractable; a removal is a
-- preference, and a preference somebody cannot change is a bug waiting to be
-- filed. Nothing in the app calls it yet — "undo remove" is unbuilt — but the
-- permission belongs with the fact rather than with the feature.
create policy "undo your own removal" on public.remove_list
    for delete using (auth.uid() = remover_id);
