-- Put the icon in front of the noun, as every messaging app does.
--
-- `0023` made an uncaptioned attachment say "Photo" or "Voice message" instead
-- of nothing. This adds the glyph, so a banner reads the way the chat list
-- already does — `ChatView.lastLine` has drawn `mic.fill` beside "Voice
-- message" since voice memos landed.
--
-- **It has to be an emoji rather than an SF Symbol**, and that is a property of
-- the medium rather than a preference. An APNs alert body is plain text
-- rendered by SpringBoard; there is no attributed string, no font, and no way to
-- reach the symbol set the app draws with. A Notification Service Extension can
-- attach an *image*, but that is a thumbnail beside the banner, not a glyph
-- inline in the sentence. So the choice is this emoji or nothing, and the ones
-- below are what WhatsApp, Signal and Messages all converged on.
--
-- The caption still wins where there is one — see `0023`. An attachment with
-- words is a message about the words, and prefixing those with a camera would
-- be decorating somebody's sentence.
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

    if length(btrim(coalesce(new.body, ''))) > 0 then
        preview := new.body;
    else
        preview := case new.attachment_kind
                       when 'photo' then '📷 Photo'
                       when 'video' then '📹 Video'
                       when 'audio' then '🎤 Voice message'
                       -- Unreachable while `messages_have_content` holds, and
                       -- here because a future kind must not silently notify as
                       -- a blank — which is the bug `0023` exists for.
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
