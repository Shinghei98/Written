-- ---------------------------------------------------------------------------
-- Shared videos: the second thing one user may read about another
-- ---------------------------------------------------------------------------
--
-- Someone finds a video, taps Share, picks Written, and says something about
-- it. The feed shows it beside the profiles, attributed to them.
--
-- The same deliberate exception `discovery_cards` makes in 0007, and the same
-- argument for it: a row here is a *post*, not a distillation. It carries a
-- video id and a sentence somebody chose to publish, and nothing that could
-- reconstruct anything they did not.
--
-- The raw tables keep the policies they have. Nothing below alters them.

create table public.shared_posts (
    id          uuid primary key default gen_random_uuid(),
    sharer_id   uuid not null references public.users (id) on delete cascade,

    -- Denormalised for exactly the reason `discovery_cards.display_name` is:
    -- `public.users` is `auth.uid() = id` and must stay that way, so the
    -- readable copy of the name lives here where the policy is deliberate.
    -- Joining would have meant opening that table, which is not a trade worth
    -- making for a byline.
    sharer_name text not null,

    -- 'youtube' today. Instagram needs a Meta app with `oembed_read` behind App
    -- Review, so it is a column value rather than a second table — the provider
    -- changes the URL that is built and nothing else about a row.
    provider    text not null,

    -- The id, not the URL the user pasted. A watch link, a youtu.be link and a
    -- shorts link are three ways of writing one video; storing what was typed
    -- would make them three different posts.
    video_id    text not null,

    -- What the sharer said about it, which becomes the caption.
    message     text,

    created_at  timestamptz not null default now()
);

alter table public.shared_posts enable row level security;

-- Readable by anyone signed in — a post is published by definition. Split from
-- the write policies on purpose: who may read a share and who may create one
-- are different questions, and a single `for all` would make them one answer.
create policy "signed in may read" on public.shared_posts
    for select using (auth.role() = 'authenticated');

create policy "own row" on public.shared_posts
    for insert with check (auth.uid() = sharer_id);

create policy "own row update" on public.shared_posts
    for update using (auth.uid() = sharer_id) with check (auth.uid() = sharer_id);

-- Sharing something is not a commitment. Whoever posted it can take it back.
create policy "own row delete" on public.shared_posts
    for delete using (auth.uid() = sharer_id);

-- The feed reads newest first.
create index shared_posts_recent_idx on public.shared_posts (created_at desc);
