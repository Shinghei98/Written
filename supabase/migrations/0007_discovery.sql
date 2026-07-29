-- ---------------------------------------------------------------------------
-- Discovery: the first thing in this schema one user may read about another
-- ---------------------------------------------------------------------------
--
-- Every policy written before this one is `auth.uid() = user_id`. That is the
-- whole authorisation layer, and it means a feed of other people's profiles was
-- not merely unbuilt but impossible — a signed-in user could not read a single
-- row belonging to anyone else.
--
-- This opens exactly one table, and the shape of that table is the security
-- argument. It is not a view over `distilled_records` and must never become
-- one: it carries what a *card* shows and nothing that could reconstruct a
-- distillation. No item ids, no track or video or event titles, no timestamps,
-- no counts. A domain and a subject are what `Ontology.line(for:subject:)`
-- needs to write a line, so a domain and a subject are what this holds.
--
-- The raw tables keep the policies they have. Nothing below alters them.

create table public.discovery_cards (
    user_id      uuid primary key references public.users (id) on delete cascade,

    -- What the card prints. `display_name` rather than a join to
    -- `public.users`: that table is `auth.uid() = id` and must stay that way, so
    -- the readable copy of the name lives here where the policy is deliberate.
    display_name text        not null,
    age          integer,
    district     text,

    -- Six seeds for the placeholder portraits, in order. Seeds rather than
    -- files because the portraits are generated today; when real photographs
    -- exist this becomes their storage paths and the feed does not change.
    photo_seeds  integer[]   not null default '{}',

    -- `[{"domain": "...", "subject": "..."}]`. Derived subjects only — the
    -- thing a line is *about*, never the row it was inferred from.
    interests    jsonb       not null default '[]'::jsonb,

    updated_at   timestamptz not null default now()
);

alter table public.discovery_cards enable row level security;

-- Readable by anyone signed in. This is the deliberate exception, and it is
-- split from the write policy on purpose: the two are different questions and
-- a single `for all` policy would have made "who may read a card" and "who may
-- change one" the same answer.
create policy "signed in may read" on public.discovery_cards
    for select using (auth.role() = 'authenticated');

-- Writing is still only ever your own row, exactly as everywhere else.
create policy "own row" on public.discovery_cards
    for insert with check (auth.uid() = user_id);

create policy "own row update" on public.discovery_cards
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own row delete" on public.discovery_cards
    for delete using (auth.uid() = user_id);

-- The feed pages through people; ordering by something stable keeps a page
-- boundary from showing the same person twice.
create index discovery_cards_updated_idx on public.discovery_cards (updated_at desc, user_id);
