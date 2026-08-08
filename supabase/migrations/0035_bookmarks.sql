-- Bookmarks: a private note to yourself about somebody in Explore.
--
-- **Not a like, and the difference is who can see it.** A like is addressed to
-- the other person — it appears in their admirers list, it notifies them, and
-- accepting it opens a conversation. A bookmark is addressed to nobody. The
-- person bookmarked is never told, no trigger fires, and the only reader is the
-- owner. That is the whole design, and the policies below are how it is
-- enforced rather than merely intended.
--
-- Server-side rather than a file under `AccountScope`, for the reason the rest
-- of this schema is: the server is the source of truth and the device keeps a
-- cache. A bookmark that vanished on reinstall would be the one kind of saved
-- thing people expect to survive a new phone.

create table public.bookmarks (
    -- The owner. Every policy below keys off this and nothing else.
    user_id       uuid not null references public.users (id) on delete cascade,
    -- The person bookmarked. Cascades too: `23503` on insert means they deleted
    -- their account between the feed being built and the tap, which is the same
    -- case `likes` already handles by removing them from the feed.
    bookmarked_id uuid not null references public.users (id) on delete cascade,

    created_at    timestamptz not null default now(),

    -- A second bookmark of the same person is the same row, which is what makes
    -- bookmarking idempotent under `on conflict do nothing`.
    primary key (user_id, bookmarked_id),

    -- Bookmarking yourself is not meaningful and the feed already excludes the
    -- viewer, so this only ever catches a bug.
    constraint bookmarks_not_self check (user_id <> bookmarked_id)
);

-- The bookmarks page reads every row for one user, newest first.
create index bookmarks_by_user on public.bookmarks (user_id, created_at desc);

alter table public.bookmarks enable row level security;

-- **All four operations, one condition.** Unlike `likes`, there is no second
-- party with a right to see or answer anything here, so there is no split
-- between who may read and who may write — which also means no column grants to
-- get wrong. Delete is included deliberately: un-bookmarking is a real delete
-- rather than an annotation, because "nothing in Postgres is ever deleted"
-- describes the distillation record, not a list somebody curates.
create policy "own bookmarks" on public.bookmarks
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

comment on table public.bookmarks is
    'Private saved profiles. Visible only to user_id; the bookmarked person is '
    'never notified and cannot read these rows.';
