-- Voice messages: a third kind of attachment.
--
-- `0010` wrote `attachment_kind text check (attachment_kind in ('photo',
-- 'video'))` inline on the `add column`, so Postgres named that constraint
-- itself. An `audio` row is refused by it — 23514, and the app's send would
-- fail with a message about a constraint rather than about anything a user did.
--
-- The name is **discovered rather than assumed**, for the reason `0010` gives
-- about the body check: hardcoding `messages_attachment_kind_check` works until
-- Postgres picks something else, and then this migration half-applies. Two
-- check constraints on this table mention `attachment_kind` —
-- `messages_attachment_is_whole` is the other — so the search is narrowed by
-- the literal that only the kind check contains.

do $$
declare
    existing text;
begin
    select conname into existing
      from pg_constraint
     where conrelid = 'public.messages'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) like '%''photo''%';

    if existing is not null then
        execute format('alter table public.messages drop constraint %I', existing);
    end if;
end $$;

alter table public.messages
    add constraint messages_attachment_kind_check
        check (attachment_kind in ('photo', 'video', 'audio'));

comment on column public.messages.attachment_kind is
    'photo | video | audio. Audio is a voice memo: AAC in an m4a container, '
    'recorded in the chatroom and capped at 60 seconds by the app.';

-- Nothing else changes. `chat-media` already holds these files and its policies
-- are about *membership of the conversation*, not about what the bytes are —
-- the first path segment is the conversation id and both policies check the
-- caller is in it. A new media type needs no new policy, which is the whole
-- point of having keyed them that way.
