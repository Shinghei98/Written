-- What the last message *was*, not just what it said.
--
-- The chat list has been inferring this. `ChatView.lastLine` reads an empty
-- `last_message` as "an attachment with no caption" and draws a camera and the
-- word Photo — the code says outright that it is "an inference rather than a
-- fact the schema records", because the conversation summary carries no
-- attachment column.
--
-- Voice memos break the inference rather than bending it. A memo's body is its
-- **duration** — `00:04` — so the row is not empty and the list prints the bare
-- number. And it cannot be recognised by shape: `\d\d:\d\d` is also what
-- somebody types when they mean half past twelve, and turning "meet at 12:30"
-- into a voice note is a worse failure than the one being fixed.
--
-- So the summary carries the kind. The photo case stops being a guess at the
-- same time.

alter table public.conversations
    add column if not exists last_message_kind text
        check (last_message_kind in ('photo', 'video', 'audio'));

comment on column public.conversations.last_message_kind is
    'attachment_kind of the newest message, or null when it was plain text. '
    'Maintained by touch_conversation; never written by a client.';

-- `create or replace` keeps the existing trigger binding — `messages_touch_
-- conversation` goes on pointing at this function, so nothing needs recreating
-- and no insert is missed in between.
create or replace function public.touch_conversation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    update public.conversations
       set last_message      = new.body,
           last_message_at   = new.created_at,
           -- Null for text, which is what makes "is this an attachment" a fact
           -- the row states rather than something the client works out from an
           -- empty string.
           last_message_kind = new.attachment_kind
     where id = new.conversation_id;
    return new;
end;
$$;

-- Backfill, so threads whose last message predates this column do not all read
-- as text. Correlated on the newest message per conversation rather than a
-- join, because `messages` has no unique constraint that would make a join
-- single-valued and a duplicate `created_at` would multiply the update.
update public.conversations c
   set last_message_kind = m.attachment_kind
  from (
        select distinct on (conversation_id)
               conversation_id, attachment_kind
          from public.messages
         order by conversation_id, created_at desc, id desc
       ) m
 where m.conversation_id = c.id
   and m.attachment_kind is not null;
