-- Tell the function *who* the notification is from.
--
-- Step two of communication notifications. The banner is to render as a person
-- — avatar on the left, their name, the message beneath — and for that the
-- Notification Service Extension needs an image and a stable identity for the
-- sender. Neither is in the payload today: `private.notify` carries a title, a
-- body, a category and a thread, all of which are *about* the message and none
-- of which say who wrote it.
--
-- **The id rather than the photograph.** The trigger could join `public.photos`
-- itself and pass a path, and that would put storage layout in the schema and a
-- second place to change when it moves. `functions/push` already holds the
-- secret key and already talks to the REST API; looking up and signing is its
-- job. The trigger's job is to say who.
--
-- `sender` is nullable and last, so nothing that already calls `private.notify`
-- has to change to keep working — which matters because these run inside
-- triggers on `likes` and `messages`, where a broken call means a broken like.

create or replace function private.notify(
    recipient uuid,
    title     text,
    body      text,
    category  text,
    thread    text default null,
    sender    uuid default null
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
    -- Silently doing nothing is correct until the function is deployed and this
    -- row exists: a like must still work.
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
            'user_id',   recipient,
            'title',     title,
            'body',      body,
            'category',  category,
            'thread',    thread,
            'sender_id', sender
        )
    );
end;
$$;

-- ---------------------------------------------------------------------------
-- The three callers, each naming the person the banner should wear
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
        -- The liker: the face this is from.
        new.liker_id
    );
    return new;
end;
$$;

-- **The accepter, not the liker.** This notification goes *to* the liker and is
-- about the person who accepted them — so the avatar is the accepter's, which
-- is the opposite of the row's `liker_name` and easy to get backwards.
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

    select coalesce(nullif(btrim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), 'Someone')
      into accepter_name
      from public.users where id = new.liked_id;

    perform private.notify(
        new.liker_id,
        'You matched with ' || accepter_name,
        'Say hello.',
        'match',
        null,
        new.liked_id
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
begin
    select * into conversation from public.conversations where id = new.conversation_id;
    if conversation is null then
        return new;
    end if;

    -- A seeded invitation rather than a message somebody sent: it carries the
    -- like's timestamp, which necessarily predates the conversation that exists
    -- only because that like was accepted. See `0022`.
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

    perform private.notify(
        recipient,
        sender_name,
        preview,
        'message',
        new.conversation_id::text,
        new.sender_id
    );
    return new;
end;
$$;
