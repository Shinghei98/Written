-- ---------------------------------------------------------------------------
-- YouTube retention: the one place in this schema that deletes
-- ---------------------------------------------------------------------------
--
-- **Every other rule here says nothing in Postgres is ever deleted.** That is
-- deliberate and it stays true for every other source. This migration is the
-- exception, and the reason is not ours to argue with:
--
--   YouTube API Services Developer Policies III.E.4 permits storing beyond 30
--   calendar days only Analytics data, Reporting data and *statistics* — view
--   counts, subscriber counts. Titles, channel names and playlist contents are
--   "all other Authorized Data" and must be deleted or refreshed within 30
--   calendar days.
--
-- It is the same objection that removed Spotify — whose terms forbid storing
-- Spotify Content in a third-party database at all — arriving for the source the
-- product cannot drop. Spotify could be dropped; YouTube is the other half of
-- Media.
--
-- **The resolution is derive, then delete the raw.** A row lives up to 30 days
-- as the ontology and embedding stages' input; after that the titles and channel
-- names go and only derived, non-identifying output remains. That is what these
-- rows were always for.
--
-- **A deleted row is not a lost row.** `append_source_records` writes only what
-- changed, by comparing against the *newest* version of each item — so once the
-- newest version is gone, the next distillation re-inserts it in full. Deleting
-- is therefore the same operation as refreshing, done lazily: the data returns
-- if the user is still connected and consents, and stays gone if they are not.
-- That is precisely what the policy asks for.

-- ---------------------------------------------------------------------------
-- Two stores, not one
-- ---------------------------------------------------------------------------
--
-- Missing either makes the sweep cosmetic. `shared_posts` is deliberately *not*
-- swept here: a video id there came from a public URL the user pasted into the
-- share sheet, not from an authorised API call, and it is the subject of a post
-- somebody chose to publish. It is genuinely grey and wants a written judgement
-- rather than a delete written on a guess. See CLAUDE.md.

create or replace function public.sweep_youtube_retention()
returns table (records_deleted bigint, cards_touched bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
    deleted_records bigint;
    touched_cards   bigint;
begin
    -- 1. The distillation itself.
    --
    -- `distilled_at` rather than `collected_at`: the former is stamped once per
    -- run by `append_source_records` and is what "when did this reach us" means
    -- here. A row re-sent unchanged by a later run is not rewritten, so its
    -- `distilled_at` genuinely records the last time we heard it.
    with gone as (
        delete from public.distilled_records
        where source = 'youtube'
          and distilled_at < now() - interval '30 days'
        returning 1
    )
    select count(*) into deleted_records from gone;

    -- 2. The discovery card, whose `interests` carry channel names.
    --
    -- **Marked by source, because domain cannot tell them apart.** A YouTube
    -- channel is classified through the same ontology as an Apple Music artist
    -- and can land in the same domain, so filtering on `domain` would either
    -- keep YouTube data or destroy Apple Music's. `DiscoveryCardService` stamps
    -- each entry with the source it came from for exactly this.
    --
    -- Entries written before that stamp existed have no `source` key. They are
    -- swept too: an unlabelled entry on a card older than 30 days may be a
    -- channel name, and this is not a rule to be approximately right about.
    with touched as (
        update public.discovery_cards
        set interests = coalesce((
                select jsonb_agg(entry)
                from jsonb_array_elements(interests) as entry
                where entry->>'source' is not null
                  and entry->>'source' <> 'youtube'
            ), '[]'::jsonb)
        where updated_at < now() - interval '30 days'
          and exists (
              select 1 from jsonb_array_elements(interests) as entry
              where entry->>'source' is null
                 or entry->>'source' = 'youtube'
          )
        returning 1
    )
    select count(*) into touched_cards from touched;

    return query select deleted_records, touched_cards;
end;
$$;

-- `security definer` because the sweep runs as a scheduled job with no session
-- behind it, and every policy in this schema is `auth.uid() = user_id`. Revoked
-- from callers for the same reason: nothing signed in has any business invoking
-- a function that deletes across all accounts.
revoke all on function public.sweep_youtube_retention() from public;
revoke all on function public.sweep_youtube_retention() from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Running it
-- ---------------------------------------------------------------------------
--
-- **A schedule, not an app call.** The deadline is thirty days from the data
-- arriving, and nothing guarantees the app is opened before then — a user who
-- distills once and never returns is exactly the case the rule exists for, and
-- exactly the case an app-triggered sweep cannot serve.
--
-- Daily rather than hourly: the window is thirty days, the work is a delete over
-- an indexed predicate, and a job that runs 24 times more often to be at worst
-- an hour fresher is spending on nothing.

create extension if not exists pg_cron;

select cron.schedule(
    'youtube-retention',
    '17 3 * * *',
    $$select public.sweep_youtube_retention()$$
);

-- The predicate the sweep runs on, so it stays a scan of the recent tail rather
-- than of the table.
create index if not exists distilled_records_youtube_age_idx
    on public.distilled_records (distilled_at)
    where source = 'youtube';
