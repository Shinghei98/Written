-- Where to send a notification.
--
-- One row per device per account. Somebody with a phone and an iPad has two;
-- somebody who reinstalls gets a new token and leaves a dead one behind, which
-- is what the `410` sweep in `functions/push` exists to clear.
--
-- **`environment` is not bookkeeping.** APNs has two hosts with two separate
-- token namespaces: a token minted by a build signed with a development profile
-- is a *sandbox* token and answers `BadDeviceToken` at
-- `api.push.apple.com`, and a TestFlight or App Store token fails the same way
-- at the sandbox host. Both kinds exist on this project *at once* — every day
-- here involves an Xcode install and a TestFlight build of the same app — so
-- the row has to say which host it belongs to. Guessing, or trying both, turns
-- a delivery failure into a silent one.

create table if not exists public.device_tokens (
    user_id     uuid not null references public.users (id) on delete cascade,
    -- The hex string APNs gave the app. Not a uuid: it is 64 hex characters and
    -- has no dashes.
    token       text not null,
    environment text not null default 'production'
                    check (environment in ('sandbox', 'production')),
    updated_at  timestamptz not null default now(),

    -- The same device re-registering is the same row. Tokens are re-uploaded on
    -- every launch — they change without warning and a stale one is a
    -- notification nobody receives — so this is written far more often than it
    -- is inserted.
    primary key (user_id, token)
);

-- The only question the function asks: "where does this person's phone live?"
create index if not exists device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

-- **Insert, update and delete your own — and no select policy at all.**
--
-- The app never reads tokens back: it knows its own, and re-uploads it rather
-- than checking whether it is already there. Only `functions/push` reads this,
-- with the service key, which bypasses RLS entirely. A table nobody can select
-- from is one fewer place a token can leak, and a device token is enough to
-- send somebody a notification if it ever escaped alongside the APNs key.
create policy "register your own device" on public.device_tokens
    for insert with check (auth.uid() = user_id);

create policy "refresh your own device" on public.device_tokens
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Signing out should take the token with it, or the next notification for this
-- account arrives on a phone somebody else is now holding.
create policy "forget your own device" on public.device_tokens
    for delete using (auth.uid() = user_id);
