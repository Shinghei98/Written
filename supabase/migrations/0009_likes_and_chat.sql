-- ---------------------------------------------------------------------------
-- Likes, and the conversations they authorise
-- ---------------------------------------------------------------------------
--
-- `0007` and `0008` opened two tables for reading across accounts. This opens
-- none: every policy below names the two people a row is *about*, and nobody
-- else can see it. A like is between two users and so is a conversation, which
-- makes `auth.uid() in (…)` the natural shape here rather than the exception
-- those two migrations had to argue for.
--
-- The gate on a conversation is an **accepted** like, checked in the database
-- rather than only in the app: `conversations`' insert policy will not let a row
-- exist for a pair who have not agreed. That subquery reads `public.likes`,
-- which is itself RLS-protected — and that is fine, deliberately. A policy's
-- subquery runs as the querying user, and the accepted like necessarily has that
-- user as its liker or its liked, so their own select policy admits it. Do not
-- "fix" this with `security definer`; the restriction is load-bearing.
--
-- Names and photo seeds are denormalised onto both tables. `public.users` is
-- `auth.uid() = id` and stays that way, and PostgREST cannot embed
-- `discovery_cards` off either table — no foreign key joins them, both only
-- reference `users`. More to the point, `discovery_cards` is written solely by
-- `tools/seed_synthetic.py`, so a *real* user has no card at all and a join
-- would return nothing for exactly the people who matter. This is the same
-- trade `0008` makes for `sharer_name`, with the same cost: a later rename does
-- not reach rows already written.

-- ---------------------------------------------------------------------------
-- Likes
-- ---------------------------------------------------------------------------

create table public.likes (
    liker_id     uuid not null references public.users (id) on delete cascade,
    liked_id     uuid not null references public.users (id) on delete cascade,

    -- 'pending' until the recipient answers. Declining marks the row rather
    -- than removing it, so the same person cannot like again and reappear in an
    -- admirers list that has already been answered. Nothing here is ever
    -- deleted, which is the habit the rest of this schema keeps.
    status       text not null default 'pending'
                     check (status in ('pending', 'accepted', 'declined')),

    -- What the admirers row draws. The seed rather than a file, for the reason
    -- `discovery_cards.photo_seeds` gives: portraits are generated today, and
    -- this becomes a storage path without the UI changing.
    liker_name   text not null,
    liker_photo_seed integer not null default 0,

    created_at   timestamptz not null default now(),
    responded_at timestamptz,

    primary key (liker_id, liked_id),
    -- A second like from the same person is the same row, so this is also what
    -- makes liking idempotent.
    check (liker_id <> liked_id)
);

alter table public.likes enable row level security;

create policy "own like" on public.likes
    for insert with check (auth.uid() = liker_id);

-- Both sides, and the liker's side is not a courtesy: the filled heart in the
-- feed is read back from here, so without it a relaunch or a second device
-- would show every already-liked card as unliked.
create policy "either party may read" on public.likes
    for select using (auth.uid() in (liker_id, liked_id));

-- Only the recipient answers, and only ever their own row.
create policy "recipient may answer" on public.likes
    for update using (auth.uid() = liked_id) with check (auth.uid() = liked_id);

-- RLS alone is not enough here. The policy above lets the recipient write to a
-- row they legitimately hold, and nothing in it stops them rewriting
-- `liker_id` — forging a like from anybody. Column privileges are what confine
-- the update to the answer itself.
revoke update on public.likes from anon, authenticated;
grant update (status, responded_at) on public.likes to authenticated;

-- No delete policy at all, by the same argument as the status column.

-- The admirers query: pending likes pointing at me, newest first.
create index likes_received_idx on public.likes (liked_id, status, created_at desc);

-- ---------------------------------------------------------------------------
-- Conversations
-- ---------------------------------------------------------------------------

create table public.conversations (
    id          uuid primary key default gen_random_uuid(),

    -- Ordered by uuid rather than by who accepted. That is what makes one
    -- conversation per pair fall out of a unique constraint instead of needing
    -- either side to check first: whoever inserts, the pair sorts the same way.
    user_a      uuid not null references public.users (id) on delete cascade,
    user_b      uuid not null references public.users (id) on delete cascade,

    -- Both participants', because either may be the one reading the list.
    user_a_name text not null,
    user_b_name text not null,
    user_a_photo_seed integer not null default 0,
    user_b_photo_seed integer not null default 0,

    -- Denormalised so the chat list is one query. A subquery per thread for its
    -- last message is precisely the uncapped per-item fetch CLAUDE.md calls a
    -- red flag; `source_connections.record_count` is the precedent for carrying
    -- a summary next to the thing it summarises. Maintained by the trigger
    -- below, never by the app.
    last_message      text,
    last_message_at   timestamptz,

    created_at  timestamptz not null default now(),

    check (user_a < user_b),
    unique (user_a, user_b)
);

alter table public.conversations enable row level security;

create policy "participants may read" on public.conversations
    for select using (auth.uid() in (user_a, user_b));

-- The accepted like *is* the authorisation. Either direction counts: the person
-- who liked and the person who accepted may both be the one whose device gets
-- here first.
create policy "participant may open once accepted" on public.conversations
    for insert with check (
        auth.uid() in (user_a, user_b)
        and exists (
            select 1
            from public.likes l
            where l.status = 'accepted'
              and (
                  (l.liker_id = user_a and l.liked_id = user_b)
                  or (l.liker_id = user_b and l.liked_id = user_a)
              )
        )
    );

-- Nobody updates a conversation directly, and there is no policy for it. The
-- hole that closes: an update policy of `auth.uid() in (user_a, user_b)` would
-- have let a participant rewrite the *other* column and land a thread on a
-- third party with no accepted like anywhere. The trigger below is the only
-- writer, and it is `security definer` so it needs no grant here.
revoke update, delete on public.conversations from anon, authenticated;

create index conversations_for_user_idx
    on public.conversations (user_a, last_message_at desc nulls last);
create index conversations_for_partner_idx
    on public.conversations (user_b, last_message_at desc nulls last);

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

create table public.messages (
    id              uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references public.conversations (id) on delete cascade,
    sender_id       uuid not null references public.users (id) on delete cascade,
    body            text not null check (length(btrim(body)) > 0),
    created_at      timestamptz not null default now(),
    read_at         timestamptz
);

alter table public.messages enable row level security;

create policy "participants may read" on public.messages
    for select using (
        exists (
            select 1 from public.conversations c
            where c.id = conversation_id
              and auth.uid() in (c.user_a, c.user_b)
        )
    );

-- Sending is your own message, into a thread you are in. Both halves matter:
-- the first stops writing as somebody else, the second stops writing into a
-- stranger's thread.
create policy "own message in own thread" on public.messages
    for insert with check (
        auth.uid() = sender_id
        and exists (
            select 1 from public.conversations c
            where c.id = conversation_id
              and auth.uid() in (c.user_a, c.user_b)
        )
    );

-- Only the person who received it, and only to mark it read.
create policy "recipient may mark read" on public.messages
    for update using (
        auth.uid() <> sender_id
        and exists (
            select 1 from public.conversations c
            where c.id = conversation_id
              and auth.uid() in (c.user_a, c.user_b)
        )
    ) with check (
        auth.uid() <> sender_id
    );

revoke update on public.messages from anon, authenticated;
grant update (read_at) on public.messages to authenticated;

create index messages_thread_idx on public.messages (conversation_id, created_at desc);

-- ---------------------------------------------------------------------------
-- The chat list's summary
-- ---------------------------------------------------------------------------

-- `security definer` on purpose: `authenticated` has no update privilege on
-- `conversations` at all, which is what stops a participant re-pointing a
-- thread at somebody else. This runs as the owner instead, and writes only the
-- two summary columns.
--
-- `search_path` is pinned because a definer function that resolves names
-- through the caller's path is the classic way one gets hijacked.
create or replace function public.touch_conversation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    update public.conversations
       set last_message    = new.body,
           last_message_at = new.created_at
     where id = new.conversation_id;
    return new;
end;
$$;

create trigger messages_touch_conversation
    after insert on public.messages
    for each row execute function public.touch_conversation();
