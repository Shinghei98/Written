-- Say what arrived when a message has no words in it.
--
-- `0009` wrote `body text not null check (length(btrim(body)) > 0)` and `0010`
-- relaxed it to `messages_have_content` — `length(btrim(body)) > 0 or
-- attachment_path is not null` — the moment a photo could be sent without a
-- caption. The app satisfies `not null` by sending an empty string.
--
-- `0020`'s notification passed `new.body` through unread, so a photograph with
-- no caption produced a banner with the sender's name and **an empty line under
-- it**. Not a crash and not a missing notification, which is what makes it the
-- kind of thing that ships: it looks like a delivery problem to whoever
-- receives it, and like nothing at all to everybody else.
--
-- Voice notes are the worst case, because they are *never* captioned —
-- `0011` added `audio` and nothing in the app pairs text with one. Every voice
-- message in this product would have notified as a blank.
--
-- The wording is the noun rather than a sentence — "Photo", not "sent you a
-- photo" — because the title is already the sender's name and a banner reads as
-- one line. It matches what the chat list shows for the same message through
-- `last_message_kind`.
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

    -- **The caption wins when there is one.** An attachment with words is a
    -- message about the words as much as the file, and replacing them with
    -- "Photo" would hide the part somebody chose to write.
    if length(btrim(coalesce(new.body, ''))) > 0 then
        preview := new.body;
    else
        preview := case new.attachment_kind
                       when 'photo' then 'Photo'
                       when 'video' then 'Video'
                       when 'audio' then 'Voice message'
                       -- Unreachable while `messages_have_content` holds, and
                       -- here because a future kind must not silently notify as
                       -- a blank — which is the bug this migration exists for.
                       else 'Message'
                   end;
    end if;

    perform private.notify(
        recipient,
        sender_name,
        preview,
        'message',
        new.conversation_id::text
    );
    return new;
end;
$$;
