-- Three notifications: a new like, a match, a new message.
--
-- Sent from the database rather than from a phone, because in all three cases
-- the person to be told is by definition not the person making the request —
-- and their session is the only thing that could reach their own devices under
-- RLS. `functions/push` holds the APNs key; this is what calls it.
--
-- **`pg_net` is fire-and-forget, and that is the point.** `net.http_post`
-- queues the request and returns immediately, so a slow or dead APNs cannot
-- make a like fail. The cost is that a failure is invisible from SQL — it lands
-- in `net._http_response` and in the function's logs, not in an error the app
-- would ever see. That trade is the right way round here: not being notified is
-- a disappointment, not being able to like somebody is a broken app.

create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- Where to call, and the secret to prove it is us
-- ---------------------------------------------------------------------------

-- **Not `app.settings`, and not a hardcoded URL.** A GUC set with `alter
-- database` survives a restart but is invisible in the migration, and a
-- hardcoded secret in a migration is a secret in git. A table in a schema
-- nobody has been granted anything on is neither: the definer functions below
-- read it, and no role — not `anon`, not `authenticated` — can select from it.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.push_config (
    id      boolean primary key default true check (id),
    url     text not null,
    secret  text not null
);

revoke all on private.push_config from public, anon, authenticated;

-- Filled in by hand after deploying the function, because both values are
-- environment rather than schema:
--
--   insert into private.push_config (url, secret) values
--     ('https://fwnezkbesjoazlpaflbq.supabase.co/functions/v1/push', '<PUSH_SECRET>')
--   on conflict (id) do update set url = excluded.url, secret = excluded.secret;

-- ---------------------------------------------------------------------------
-- The one call every trigger makes
-- ---------------------------------------------------------------------------

-- `security definer` with a pinned `search_path`, following `touch_conversation`
-- — `authenticated` has no privilege on `private` or on `net`, and a definer
-- function that resolves names through the caller's path is the classic way one
-- gets hijacked.
create or replace function private.notify(
    recipient uuid,
    title     text,
    body      text,
    category  text,
    thread    text default null
)
returns void
language plpgsql
security definer
set search_path = private, extensions, pg_temp
as $$
declare
    config private.push_config;
begin
    select * into config from private.push_config limit 1;
    -- **Silently doing nothing is correct here.** Until the function is
    -- deployed and this row exists, a like must still work; a trigger that
    -- raised would take the whole feature down for want of configuration.
    if config is null then
        return;
    end if;

    perform net.http_post(
        url     := config.url,
        headers := jsonb_build_object(
            'Content-Type',   'application/json',
            'x-push-secret',  config.secret
        ),
        body    := jsonb_build_object(
            'user_id',  recipient,
            'title',    title,
            'body',     body,
            'category', category,
            'thread',   thread
        )
    );
end;
$$;

-- ---------------------------------------------------------------------------
-- A new like
-- ---------------------------------------------------------------------------

-- **The note is the notification when there is one.** A like with a message is
-- the whole reason `0018` exists — "including a message puts you on top of the
-- stack" is a promise about being read, and burying it behind "liked you" would
-- break that on the one surface where it counts.
create or replace function public.notify_new_like()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
    perform private.notify(
        new.liked_id,
        new.liker_name || ' likes you',
        coalesce(new.message, 'Tap to see who it is.'),
        'like',
        null
    );
    return new;
end;
$$;

create trigger likes_notify_new
    after insert on public.likes
    for each row execute function public.notify_new_like();

-- ---------------------------------------------------------------------------
-- A match
-- ---------------------------------------------------------------------------

-- Fires on the *transition* to accepted, not on every update of an accepted
-- row. `0018` added a second update path — the liker editing their own note —
-- and without this guard a note edited after acceptance would announce the
-- match again.
--
-- The recipient is the **liker**: the person who was accepted is the one
-- learning something. The accepter already knows; they just tapped it.
create or replace function public.notify_match()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
    accepter_name text;
begin
    if new.status <> 'accepted' or old.status = 'accepted' then
        return new;
    end if;

    -- The one place these triggers have to read `users`: `likes` carries the
    -- *liker's* name, and the person being announced here is the other one.
    select coalesce(nullif(btrim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), 'Someone')
      into accepter_name
      from public.users where id = new.liked_id;

    perform private.notify(
        new.liker_id,
        'You matched with ' || accepter_name,
        'Say hello.',
        'match',
        null
    );
    return new;
end;
$$;

create trigger likes_notify_match
    after update on public.likes
    for each row execute function public.notify_match();

-- ---------------------------------------------------------------------------
-- A new message
-- ---------------------------------------------------------------------------

-- **The body is included.** A lock screen is a semi-public surface and this is a
-- dating app, so that is a real choice rather than a default: it is what every
-- messaging app does and what makes a notification worth reading at all. The
-- alternative — "New message from …" with nothing under it — is one line in this
-- function if it ever needs to change.
--
-- `thread` is the conversation id, so several messages from one person collapse
-- into one stack on the lock screen instead of a column of them.
create or replace function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
    conversation public.conversations;
    recipient    uuid;
    sender_name  text;
begin
    select * into conversation from public.conversations where id = new.conversation_id;
    if conversation is null then
        return new;
    end if;

    if new.sender_id = conversation.user_a then
        recipient   := conversation.user_b;
        sender_name := conversation.user_a_name;
    else
        recipient   := conversation.user_a;
        sender_name := conversation.user_b_name;
    end if;

    perform private.notify(
        recipient,
        sender_name,
        new.body,
        'message',
        new.conversation_id::text
    );
    return new;
end;
$$;

-- After `messages_touch_conversation`, which is alphabetical accident rather
-- than design — the two are independent and neither reads what the other
-- writes.
create trigger messages_notify_new
    after insert on public.messages
    for each row execute function public.notify_new_message();
