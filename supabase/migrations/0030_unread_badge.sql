-- The number on the app icon.
--
-- **The badge only matters while the app is closed**, which is exactly when the
-- app cannot compute it — so the count travels with the notification. The app
-- corrects it on opening Chat, on reading a thread and on returning to the
-- foreground, because the server cannot know something has been read until
-- somebody reads it. Neither half is sufficient alone.
--
-- `read_at`, its policy and its column grant have existed since `0009` and
-- nothing ever used them. This is what they were for.
--
-- **Dropped and recreated, not replaced.** `create or replace function` does
-- not replace a function whose signature changed — it overloads it, which
-- `0025` did and `0026` had to clear up. Adding `badge` is a signature change.

drop function if exists private.notify(uuid, text, text, text, text, uuid, text, text);

create function private.notify(
    recipient   uuid,
    title       text,
    body        text,
    category    text,
    thread      text default null,
    sender      uuid default null,
    sender_name text default null,
    subtitle    text default null,
    badge       integer default null
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
    if config is null then
        return;
    end if;

    perform net.http_post(
        url     := config.url,
        headers := jsonb_build_object(
            'Content-Type',  'application/json',
            'x-push-secret', config.secret
        ),
        body    := jsonb_build_object(
            'user_id',     recipient,
            'title',       title,
            'body',        body,
            'category',    category,
            'thread',      thread,
            'sender_id',   sender,
            'sender_name', sender_name,
            'subtitle',    subtitle,
            -- **Null means "leave the badge alone", not "clear it".** APNs omits
            -- the key entirely when it is null, and iOS then does not touch the
            -- number — which is what a like or a match should do, since neither
            -- is an unread message. Sending 0 would wipe a badge that is
            -- correctly showing waiting messages.
            'badge',       badge
        )
    );
end;
$$;

-- ---------------------------------------------------------------------------
-- The three callers
-- ---------------------------------------------------------------------------

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
        null,
        new.liker_id,
        new.liker_name,
        'Likes you',
        -- No badge: a like is not an unread message, and the icon counts
        -- messages. Leaving it null means the existing number survives.
        null
    );
    return new;
end;
$$;

create or replace function public.notify_match()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
    accepter_name text;
    headline      text;
begin
    if new.status <> 'accepted' or old.status = 'accepted' then
        return new;
    end if;

    select coalesce(nullif(btrim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), 'Someone')
      into accepter_name
      from public.users where id = new.liked_id;

    headline := accepter_name || ' matched with you!';

    -- One line and a face; see `0029`. The display name *is* the banner title.
    perform private.notify(
        new.liker_id, headline, '', 'match', null,
        new.liked_id, headline, null, null
    );
    return new;
end;
$$;

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
    preview      text;
    waiting      integer;
begin
    select * into conversation from public.conversations where id = new.conversation_id;
    if conversation is null then
        return new;
    end if;

    -- A seeded invitation, not a message somebody sent. See `0022`.
    if new.created_at < conversation.created_at then
        return new;
    end if;

    if new.sender_id = conversation.user_a then
        recipient   := conversation.user_b;
        sender_name := conversation.user_a_name;
    else
        recipient   := conversation.user_a;
        sender_name := conversation.user_b_name;
    end if;

    -- The caption wins where there is one; see `0023` and `0024`.
    if length(btrim(coalesce(new.body, ''))) > 0 then
        preview := new.body;
    else
        preview := case new.attachment_kind
                       when 'photo' then '📷 Photo'
                       when 'video' then '📹 Video'
                       when 'audio' then '🎤 Voice message'
                       else 'Message'
                   end;
    end if;

    -- **Everything waiting for them, not just this thread.** The icon carries
    -- one number for the whole app, so a per-conversation count would be wrong
    -- the moment two people wrote. This row is already inserted — the trigger is
    -- `after insert` — so it counts itself, which is right.
    select count(*)
      into waiting
      from public.messages m
      join public.conversations c on c.id = m.conversation_id
     where m.read_at is null
       and m.sender_id <> recipient
       and recipient in (c.user_a, c.user_b);

    perform private.notify(
        recipient,
        sender_name,
        preview,
        'message',
        new.conversation_id::text,
        new.sender_id,
        sender_name,
        null,
        waiting
    );
    return new;
end;
$$;
