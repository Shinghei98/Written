-- 0135 — YouTube channels become resolvable terms.
--
-- **Everything below the flag was already built; only the flag and the titles
-- were missing.** `observation_mappings` has permitted the
-- `youtube_semantic_kind` value `channel_identity` since `0045`;
-- `ontology.youtube_channels` has had a `canonical_title` column since then;
-- `youtube_channel_role_resolver` 0.2.0 is registered and active with
-- `stable_key: youtube_channel_id`; and the YouTube projection has always
-- carried `channel_id` into the vault. What did not exist was a row in
-- `youtube_channels`, an approval granting `allow_channel_identity`, and worker
-- code that emits the term. This migration does the first two; the third is in
-- `aws/worker/resolve.py`.
--
-- **Why the approval is a new row rather than an edit.** The 2026-08-11
-- determination was scoped to uploader tags and is the record of what was
-- decided then. `initialize_youtube_run_policy` selects the most recently
-- approved row (`order by approved_at desc, approval_reference`), so a new row
-- supersedes it for future runs while the old one stays as history — which is
-- the whole reason the table has a reference and a state rather than a set of
-- columns somebody flips.
--
-- **The resolver key is load-bearing and easy to get wrong.**
-- `initialize_youtube_run_policy` looks up `model_key =
-- 'youtube_uploader_tag_resolver'` by literal. Registering a differently-named
-- resolver would leave that lookup empty, and the trigger would fall through to
-- its deny-all branch — every future run silently denied, with nothing failing.
-- So this migration registers no new model: both resolvers already exist and
-- `youtube_run_policies_resolver_shape_check` is satisfied by the one the
-- trigger finds.
--
-- **Titles come from `distilled_records`, not from the API.** The device
-- already collected them under the user's grant — 941 `liked_video` rows carry
-- `channel_id` in `extra` and the channel title in `creator`, and every
-- `subscription` row carries the title in `name`. Reading them here needs no
-- key, no quota and no network call from a Lambda, and it cannot drift from
-- what was actually observed.
--
-- **What this does not do.** It does not mint concepts. A channel resolves only
-- if its title already matches a curated alias; everything else becomes an
-- unresolved term, which is the input `EmergentTermMiner` was built for. That
-- is deliberate — minting a concept per channel would put one person's fan-edit
-- channel into the shared vocabulary, which is the five-user floor's whole
-- purpose.

begin;

-- ---------------------------------------------------------------------------
-- The channel catalogue.
-- ---------------------------------------------------------------------------

-- Liked videos: the channel id is in `extra`, the title in `creator`.
insert into ontology.youtube_channels (youtube_channel_id, canonical_title)
select distinct on (r.extra->>'channel_id')
       r.extra->>'channel_id',
       nullif(btrim(r.creator), '')
  from public.distilled_records r
 where r.source = 'youtube'
   and r.extra ? 'channel_id'
   and r.extra->>'channel_id' ~ '^[A-Za-z0-9_-]{3,128}$'
   and nullif(btrim(r.creator), '') is not null
   and char_length(btrim(r.creator)) between 1 and 240
 order by r.extra->>'channel_id', r.collected_at desc
on conflict (youtube_channel_id) do nothing;

-- Subscriptions: the row *is* the channel, so its `item_id` is the id and its
-- `name` the title.
insert into ontology.youtube_channels (youtube_channel_id, canonical_title)
select distinct on (r.item_id)
       r.item_id,
       nullif(btrim(r.name), '')
  from public.distilled_records r
 where r.source = 'youtube'
   and r.data_type = 'subscription'
   and r.item_id ~ '^[A-Za-z0-9_-]{3,128}$'
   and nullif(btrim(r.name), '') is not null
   and char_length(btrim(r.name)) between 1 and 240
 order by r.item_id, r.collected_at desc
on conflict (youtube_channel_id) do nothing;

update ontology.youtube_channels
   set last_refreshed_at = now()
 where last_refreshed_at is null;

-- ---------------------------------------------------------------------------
-- The approval.
-- ---------------------------------------------------------------------------
--
-- `allow_uploader_tags` is carried forward — a narrower approval superseding a
-- wider one would silently switch off what is working today. The three surface
-- flags stay false: `allow_bio` and `allow_icebreaker` require
-- `allow_cross_source_fusion` by check constraint, and nothing displays a
-- YouTube-derived term to another person yet. `allow_role_resolution` stays
-- false because deciding *what a channel is* — artist, reposter, label — is a
-- judgement no code here makes.

insert into ontology.youtube_policy_approvals (
  approval_reference, approval_version, approval_state,
  allow_channel_identity, allow_role_resolution, allow_uploader_tags,
  allow_title_tags, allow_cross_source_fusion, allow_bio,
  allow_icebreaker, allow_explanation, approved_at, approval_basis
) values (
  'written:determination:channel-identity:2026-08-13', '1.0', 'approved',
  true, false, true,
  true, false, false,
  false, false, now(), 'internal_determination'
)
on conflict (approval_reference) do nothing;

-- ---------------------------------------------------------------------------
-- Assertions.
-- ---------------------------------------------------------------------------
--
-- Nothing here counts channels: on an empty database there are no
-- `distilled_records` and the catalogue is legitimately empty, and
-- `tools/ci/unreplayable_migrations.txt` is empty and is to stay that way.
-- What is asserted is that the *policy* now says what it is meant to say, and
-- that the trigger will be able to find a resolver.

do $$
declare
  chosen ontology.youtube_policy_approvals%rowtype;
  resolver_id uuid;
  channels integer;
begin
  -- Exactly the query `initialize_youtube_run_policy` runs, so this asserts
  -- what a future run will actually be given rather than what was inserted.
  select * into chosen
  from ontology.youtube_policy_approvals
  where approval_state = 'approved'
    and approved_at <= now()
    and (expires_at is null or expires_at > now())
    and revoked_at is null
  order by approved_at desc, approval_reference
  limit 1;

  if chosen.approval_reference is distinct from
     'written:determination:channel-identity:2026-08-13' then
    raise exception
      'the new determination is not the one a run would select, got %',
      coalesce(chosen.approval_reference, '(none)');
  end if;
  if not (chosen.allow_channel_identity and chosen.allow_title_tags
          and chosen.allow_uploader_tags) then
    raise exception 'the selected determination does not grant what 0135 intends';
  end if;

  -- The trigger's own literal. If this is ever renamed, every run falls to the
  -- deny-all branch and nothing reports it — so it is asserted here.
  select id into resolver_id from ontology.model_versions
   where model_role = 'youtube_resolver' and status = 'active'
     and model_key = 'youtube_uploader_tag_resolver';
  if resolver_id is null then
    raise exception
      'initialize_youtube_run_policy would deny every run: no active youtube_uploader_tag_resolver';
  end if;

  select count(*) into channels from ontology.youtube_channels;
  raise notice '0135: % channel(s) catalogued; channel identity approved', channels;
end
$$;

-- ---------------------------------------------------------------------------
-- The recompute.
-- ---------------------------------------------------------------------------
--
-- A policy change is an analysis change: the same observations now support
-- terms they did not support before. Without this, the system changes what it
-- *would* compute and nothing it has. The queue does not drain itself —
-- `written-semantic-worker` must be invoked until it answers
-- `{"claimed": false}`.

do $$
declare
  enqueued integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
    'youtube determination 2026-08-13: channel identity and title tags'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for the channel-identity determination', enqueued;
end
$$;

commit;
