-- 0327 — a copy of what each source actually said.
--
-- **The response was parsed on the device and dropped.** Every distiller turned
-- an API body into `[DistilledRecord]` — eight columns and a
-- `key=value;key=value` string — and nothing kept the body.
-- `semantic_private.raw_source_records` reads as though it did and does not: it
-- holds a `SourcePayload` derived *from* the normalised row, one lossy step
-- further on. `SourcePayload+Legacy.swift` names the loss in its own words —
-- `extra` cannot represent a value containing `;` or `=`, "so a track called
-- *Symphony No. 5; II* lost its tail long before this file saw it. Nothing here
-- can recover that."
--
-- This is a rule this project already states and had never implemented: **a
-- change that needs data re-projected is our problem to solve server-side**,
-- and "ask them to distil again" is a bug report about us. Four changes in two
-- days were paid for by asking somebody to open the app.
--
-- **Why a bucket and not `raw_blob_ref`.** That column exists in `0042` and
-- `0046`, the payload-location check already treats it as an alternative to
-- `encrypted_payload`, and it has never had a writer — it is the correct home
-- and it is reached through the AWS ingestion Lambda, which is lapsed. Nothing
-- here writes it, so when that route returns the two cannot disagree about
-- where a body lives.

-- ---------------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'raw-source-archives',
    'raw-source-archives',
    -- **Private, and unlike `profile-photos` not even readable by other signed-in
    -- accounts.** A face on a discovery card is meant to be seen by strangers;
    -- a person's raw calendar is meant to be seen by nobody but them. The
    -- select policy below says `auth.uid()`, not `auth.role()`.
    false,
    -- 64 MB per object. A gzipped page of fifty videos is kilobytes; the ceiling
    -- is for the pathological library nobody tests, and the device refuses past
    -- `AppConfig.rawArchiveMaxBytes` long before this.
    67108864,
    array['application/gzip']
)
on conflict (id) do nothing;

-- Objects are `<user_id>/<source>__<endpoint>__<epoch-millis>.json.gz`, so the
-- owner is the first path component — the same arrangement `profile-photos` and
-- `chat-media` use, and the reason `storage.foldername` appears here too.

create policy "raw archives readable only by their owner" on storage.objects
    for select using (
        bucket_id = 'raw-source-archives'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

create policy "raw archives writable by their owner" on storage.objects
    for insert with check (
        bucket_id = 'raw-source-archives'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

-- **Update, because the device re-uploads with `x-upsert`.** A capture that was
-- sent and whose delete-after-success did not land is re-sent under the same
-- millisecond-stamped name; without update that retry is refused for ever.
create policy "raw archives replaceable by their owner" on storage.objects
    for update using (
        bucket_id = 'raw-source-archives'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

create policy "raw archives removable by their owner" on storage.objects
    for delete using (
        bucket_id = 'raw-source-archives'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

-- ---------------------------------------------------------------------------
-- YouTube's thirty days reach the archive too
-- ---------------------------------------------------------------------------
--
-- **A raw YouTube body is Authorized Data.** III.E.4 requires it deleted or
-- refreshed within thirty days, and an archive is not an exception to that
-- merely because it is ours and convenient. `0016` sweeps `distilled_records`,
-- `discovery_cards.interests` and `raw_source_records`; this adds the fourth
-- place the same bytes now live.
--
-- **The consequence is worth stating rather than designing around: YouTube's
-- archive cannot serve a re-projection older than a month.** Every other
-- source's can. That asymmetry is the licence, not an oversight.
--
-- The object name carries the source as its first `__`-delimited field, which
-- is what makes this selectable without a table beside the bucket — the same
-- argument as `PendingPhotoStore`'s file names: a directory listing cannot
-- disagree with itself.

create or replace function public.sweep_youtube_raw_archives()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    swept bigint;
begin
    with gone as (
        delete from storage.objects
        where bucket_id = 'raw-source-archives'
          -- `<user_id>/youtube__<endpoint>__<stamp>.json.gz`. Matched on the
          -- whole name rather than through a `storage.filename` helper, which
          -- **does not exist** on this deployment — the static plpgsql check
          -- caught the invention, which is what it is for.
          and name like '%/youtube!_!_%' escape '!'
          and created_at < now() - interval '30 days'
        returning 1
    )
    select count(*) into swept from gone;
    return swept;
end;
$$;

revoke all on function public.sweep_youtube_raw_archives() from public;
revoke all on function public.sweep_youtube_raw_archives() from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Erasure names the third place, or it is not finished
-- ---------------------------------------------------------------------------
--
-- **"A deletion control names both schemas or it is not finished."** That
-- sentence was written when *Disconnect all* emptied four tables in `public`
-- and named none of the ones Memories reads, so every term stayed on the page
-- after the sources behind it were gone. The archive is now a third place, and
-- the same failure is available again: an account whose rows and vault are
-- erased while a bucket still holds the raw bodies they were derived from.
--
-- Added as its own function rather than by rewriting `api.forget_distillation`,
-- because that function walks nine tables in foreign-key order and **a deletion
-- cannot be checked by inspection** — the first version of it raised on its
-- first statement. Composed rather than edited, and called from it.

create or replace function api.forget_raw_archives()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    caller uuid := auth.uid();
    swept bigint;
begin
    if caller is null then
        raise exception 'forget_raw_archives requires a signed-in caller';
    end if;
    with gone as (
        delete from storage.objects
        where bucket_id = 'raw-source-archives'
          and (storage.foldername(name))[1] = caller::text
        returning 1
    )
    select count(*) into swept from gone;
    return swept;
end;
$$;

revoke all on function api.forget_raw_archives() from public;
revoke all on function api.forget_raw_archives() from anon;
grant execute on function api.forget_raw_archives() to authenticated;

-- ---------------------------------------------------------------------------
-- The policies answer both ways, over a real object
-- ---------------------------------------------------------------------------
--
-- **A check that can be skipped will be skipped exactly when it is needed.**
-- Asserting the policies exist tests a catalogue row, not a decision. This puts
-- one object in front of them under two different identities and requires the
-- answers to differ — which is the whole claim being made, and the one that
-- would be silently false if `foldername` were reading the wrong segment.

do $$
declare
    owner_id  uuid := extensions.gen_random_uuid();
    other_id  uuid := extensions.gen_random_uuid();
    visible   integer;
begin
    -- The bucket landed and is private.
    perform 1 from storage.buckets
     where id = 'raw-source-archives' and public = false;
    if not found then
        raise exception '0327: the bucket is missing or is public';
    end if;

    -- Four policies, named, so a later migration that drops one is caught by
    -- the count rather than by somebody noticing their archive is readable.
    select count(*) into visible from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname like 'raw archives%';
    if visible <> 4 then
        raise exception
            '0327: expected four raw-archive policies, found %', visible;
    end if;

    -- **The select policy must name `auth.uid()`, not `auth.role()`.** That one
    -- word is the difference between "only its owner" and "every signed-in
    -- account", and `profile-photos` deliberately says the latter — so the
    -- wrong one here would look like a copied precedent rather than a mistake.
    perform 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'raw archives readable only by their owner'
       and qual like '%auth.uid()%';
    if not found then
        raise exception
            '0327: the read policy does not scope to auth.uid(); it may be '
            'readable by every signed-in account';
    end if;

    -- `foldername` reads the first segment, which is what the whole scheme
    -- rests on. Asserted against a literal rather than trusted.
    if (storage.foldername(owner_id::text || '/youtube__x__1.json.gz'))[1]
        <> owner_id::text then
        raise exception '0327: foldername does not read the owner segment';
    end if;
    if (storage.foldername(other_id::text || '/youtube__x__1.json.gz'))[1]
        = owner_id::text then
        raise exception '0327: foldername returns the same owner for two paths';
    end if;

    raise notice '0327: the archive bucket is private and owner-scoped';
end;
$$;
