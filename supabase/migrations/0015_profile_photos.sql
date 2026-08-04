-- ---------------------------------------------------------------------------
-- Profile photos: the second thing in this schema one user may see of another
-- ---------------------------------------------------------------------------
--
-- `PhotoEntryView` has picked, framed and displayed photographs since the first
-- build and dropped every one of them on Continue. So a dating profile has had
-- no face on it, a reinstall lost what was chosen, and the discovery feed drew
-- generated placeholder portraits from six random integers.
--
-- Two pieces: a bucket for the files and a table for their order.
--
-- **The read policy is the whole security argument, and it mirrors
-- `0007_discovery.sql` deliberately.** Everything before that migration was
-- `auth.uid() = user_id`; `discovery_cards` opened exactly one table to any
-- signed-in reader because a feed of other people is impossible otherwise. A
-- photograph is the same kind of exception for the same reason, so it gets the
-- same shape: readable by anyone signed in, writable only by its owner.

-- ---------------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'profile-photos',
    'profile-photos',
    -- **Not public**, though every signed-in user may read it. A public bucket
    -- is readable by URL alone with no account at all, which would put people's
    -- faces on the open web the moment one link escaped — and links escape.
    -- Private plus a policy means a reader has to be signed in, and the app
    -- fetches short-lived signed URLs the same way `MediaService` does for chat.
    false,
    -- 15 MB. Photos are re-encoded before upload; this is the backstop for when
    -- they are not.
    15728640,
    -- **Photographs only for now.** Video is commented out here as well as in
    -- the picker and in `PhotoService.encode`, so the refusal is structural: even
    -- if a video reached the uploader by some other route, Storage turns it away
    -- at the door rather than accepting a file nothing re-encoded.
    -- Restore by adding 'video/mp4', 'video/quicktime' back to this list.
    array['image/jpeg', 'image/png', 'image/heic']
)
on conflict (id) do nothing;

-- Objects are stored under `<user_id>/<position>.<ext>`, so the owner is the
-- first path component — the same trick `chat-media` uses with the conversation
-- id, and the reason `storage.foldername` appears here too.

create policy "profile photos readable by anyone signed in" on storage.objects
    for select using (
        bucket_id = 'profile-photos'
        and auth.role() = 'authenticated'
    );

create policy "profile photos writable by their owner" on storage.objects
    for insert with check (
        bucket_id = 'profile-photos'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

-- **Update and delete, unlike `chat-media`.** A sent message is not withdrawable
-- and a profile photograph very much is: replacing a picture and taking one down
-- are both things a person must be able to do about their own face.
create policy "profile photos replaceable by their owner" on storage.objects
    for update using (
        bucket_id = 'profile-photos'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

create policy "profile photos removable by their owner" on storage.objects
    for delete using (
        bucket_id = 'profile-photos'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

-- ---------------------------------------------------------------------------
-- Their order, which the bucket cannot express
-- ---------------------------------------------------------------------------

create table if not exists public.photos (
    user_id     uuid not null references public.users (id) on delete cascade,
    -- 0-5. The grid position the user put it in, which is the order they meant.
    position    integer not null check (position between 0 and 5),
    object_path text not null,
    -- `photo` | `video`. A video keeps its file whole and carries the crop
    -- below; a photo is cropped for real before upload and does not.
    --
    -- The `video` option and the crop columns stay although nothing writes them
    -- today: they are inert, they default correctly for a photograph, and
    -- dropping them would mean a second migration to put them back.
    kind        text not null default 'photo' check (kind in ('photo', 'video')),

    -- How the user framed a video, in unit coordinates across the source.
    -- Stored rather than baked in because the file has to be re-encoded for size
    -- anyway, and cropping during a compression pass that is already running
    -- costs almost nothing.
    crop_x      double precision not null default 0,
    crop_y      double precision not null default 0,
    crop_w      double precision not null default 1,
    crop_h      double precision not null default 1,

    created_at  timestamptz not null default now(),
    primary key (user_id, position)
);

alter table public.photos enable row level security;

-- Read is open to any signed-in user, matching the bucket: the feed needs to
-- know *which* objects belong to the person it is drawing, and in what order.
-- Nothing here is more revealing than the photograph it points at.
create policy "photos readable by anyone signed in" on public.photos
    for select using (auth.role() = 'authenticated');

create policy "own photos" on public.photos
    for insert with check (auth.uid() = user_id);

create policy "own photos update" on public.photos
    for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own photos delete" on public.photos
    for delete using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- The card carries the paths, as it carries the name
-- ---------------------------------------------------------------------------
--
-- Denormalised onto `discovery_cards` for exactly the reason `display_name` is:
-- the feed builds hundreds of profiles from a handful of people, and a join per
-- person per appearance to fetch six paths is a round trip to learn something
-- that never changes between them.
--
-- `photo_seeds` stays. The six synthetic accounts have seeds and no files, and
-- deleting the column would empty the feed of everybody it currently contains.
-- A card with paths draws photographs; a card with only seeds draws generated
-- portraits; a card with neither is not shown at all.

alter table public.discovery_cards
    add column if not exists photo_paths text[] not null default '{}';
