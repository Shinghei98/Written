-- ---------------------------------------------------------------------------
-- Photos and videos in a conversation
-- ---------------------------------------------------------------------------
--
-- `0009` gave messages a body and nothing else, so the compose bar's `+` had
-- nowhere to put a file and was drawn inert. This adds the two halves it needs:
-- somewhere to keep the bytes, and a column saying which message they belong to.
--
-- **The bucket is private and the path carries the authorisation.** Files are
-- stored as `<conversation_id>/<uuid>.<ext>`, and the policies below read that
-- first path segment back and check the caller is in that conversation. So a
-- signed URL is not what protects a photo — membership is, checked per request,
-- the same way every other table in this schema does it.
--
-- This is the first thing in the project to open `storage.objects`, and it is
-- opened no wider than `public.messages` already is: exactly the two people.

-- ---------------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'chat-media',
    'chat-media',
    -- Not public. A public bucket is readable by URL alone, which would make
    -- every photo in every conversation world-readable to anyone who ever saw
    -- one link — and links leak.
    false,
    -- 50 MB. The app re-encodes before upload; this is the backstop for when it
    -- does not, so a raw 4K video fails at the door rather than after a minute
    -- of somebody's data.
    52428800,
    array['image/jpeg', 'image/png', 'image/heic', 'video/mp4', 'video/quicktime']
)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Who may read and write those objects
-- ---------------------------------------------------------------------------

-- Split read from write, as `0008` does, because who may *see* a photo and who
-- may *add* one are different questions even when today's answer matches.

create policy "chat media readable by participants" on storage.objects
    for select using (
        bucket_id = 'chat-media'
        and exists (
            select 1 from public.conversations c
            where c.id = ((storage.foldername(name))[1])::uuid
              and auth.uid() in (c.user_a, c.user_b)
        )
    );

create policy "chat media writable by participants" on storage.objects
    for insert with check (
        bucket_id = 'chat-media'
        and exists (
            select 1 from public.conversations c
            where c.id = ((storage.foldername(name))[1])::uuid
              and auth.uid() in (c.user_a, c.user_b)
        )
    );

-- No update and no delete policy, which matches `messages` itself: a sent
-- message is not editable and not withdrawable, so neither is what came with it.

-- ---------------------------------------------------------------------------
-- The message's half
-- ---------------------------------------------------------------------------

alter table public.messages
    add column if not exists attachment_path text,
    add column if not exists attachment_kind text
        check (attachment_kind in ('photo', 'video'));

-- `0009` wrote `body text not null check (length(btrim(body)) > 0)`, which is
-- right for a text message and wrong the moment a photo can be sent with no
-- caption. The constraint was inline and therefore auto-named, so it is found
-- rather than guessed — hardcoding `messages_body_check` works until Postgres
-- picks a different name on a rebuilt database.
do $$
declare
    existing text;
begin
    select conname into existing
      from pg_constraint
     where conrelid = 'public.messages'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) like '%btrim(body)%';
    if existing is not null then
        execute format('alter table public.messages drop constraint %I', existing);
    end if;
end $$;

-- Something has to be in it, but either half will do.
alter table public.messages
    add constraint messages_have_content check (
        length(btrim(body)) > 0 or attachment_path is not null
    );

-- A photo with no caption still has to satisfy `not null`; the app sends an
-- empty string, and the constraint above is what makes that legal.

-- The two must travel together — a path with no kind is a file the client
-- cannot decide how to draw, and a kind with no path is a bubble with nothing
-- in it.
alter table public.messages
    add constraint messages_attachment_is_whole check (
        (attachment_path is null) = (attachment_kind is null)
    );
