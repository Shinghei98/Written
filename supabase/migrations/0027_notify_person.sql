-- Give the notification a person's *name*, separately from its headline.
--
-- A communication notification replaces the title with the sender's display
-- name — that is what makes it render as a person. So the payload needs the
-- name on its own, and today it only has a headline: "Marco likes you" for a
-- like, "You matched with Marco" for a match. Used as a display name those read
-- as somebody called "Marco likes you".
--
-- `subtitle` carries what the headline used to say. `content.updating(from:)`
-- keeps a subtitle untouched while it rewrites the title, so "Likes you" lives
-- there and the meaning survives being renamed.
--
-- **Dropped and recreated rather than replaced**, which is the lesson from
-- `0025`: `create or replace function` does not replace a function whose
-- signature changed, it overloads it, and `0026` existed only to clear up the
-- pair that left behind. Dropping first is the whole fix, and it is safe here
-- because the three callers below are recreated in the same transaction.
drop function if exists private.notify(uuid, text, text, text, text, uuid);

create function private.notify(
    recipient   uuid,
    title       text,
    body        text,
    category    text,
    thread      text default null,
    sender      uuid default null,
    sender_name text default null,
    subtitle    text default null
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
            'subtitle',    subtitle
        )
    );
end;
$$;

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
        -- What the title said, kept where a rename cannot reach it.
        'Likes you'
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
        -- The accepter: this goes *to* the liker and is about the other person.
        new.liked_id,
        accepter_name,
        'It''s a match'
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
        new.sender_id,
        sender_name,
        -- No subtitle: for a message the title *is* the sender's name, so
        -- nothing is lost when the intent renames it, and a second line saying
        -- "Message" would be noise on the one notification that needs none.
        null
    );
    return new;
end;
$$;
