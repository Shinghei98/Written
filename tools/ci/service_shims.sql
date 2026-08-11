-- What a hosted Supabase project's *services* create, which the database image
-- does not.
--
-- Neither of these is a migration defect and neither belongs in
-- `supabase/migrations/`. They exist because the replay runs against
-- `supabase/postgres` alone, with no storage-api and no GoTrue, and two
-- migrations need objects those services own:
--
--   * `storage.buckets` / `storage.objects` — created by storage-api at
--     runtime. `0010`, `0012` and `0015` insert into the first and put policies
--     on the second.
--   * `auth.users.phone` — the image ships a GoTrue schema that predates it.
--     `0033`'s trigger references `new.phone`.
--
-- Shapes match Supabase's own definitions for the columns those migrations
-- touch. Anything they do not touch is deliberately absent rather than guessed
-- at: a fuller stand-in would be a second, unversioned copy of somebody else's
-- schema, and would fail silently the day it drifted.
--
-- Run as `supabase_admin`, which owns the `storage` schema.

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  owner uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  public boolean default false,
  avif_autodetection boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  owner_id text
);

create table if not exists storage.objects (
  id uuid primary key default extensions.gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata jsonb,
  path_tokens text[],
  version text,
  owner_id text
);

create or replace function storage.foldername(name text)
returns text[] language sql immutable as $$
  select string_to_array(name, '/');
$$;

alter table storage.objects enable row level security;

grant usage on schema storage to postgres, anon, authenticated, service_role;
grant all on storage.buckets, storage.objects to postgres, service_role;
grant select on storage.buckets to anon, authenticated;
grant all on storage.objects to authenticated;

alter table auth.users add column if not exists phone text;
alter table auth.users add column if not exists phone_confirmed_at timestamptz;
do $$
begin
  begin
    alter table auth.users add constraint users_phone_key unique (phone);
  exception when others then null;
  end;
end
$$;
