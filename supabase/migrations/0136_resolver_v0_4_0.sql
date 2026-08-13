-- 0136 — resolver 0.4.0: a YouTube channel is a term.
--
-- **This is the migration `0135` needed and did not have.** `0135` granted
-- `allow_channel_identity`, catalogued 298 channels, and enqueued **zero**
-- recompute jobs. That was not a failure of the enqueue — it was correct.
-- `enqueue_recompute_on_analysis_change` enqueues only where no run exists for
-- `(user, revision, ontology version, resolver, scorer)`, and `0134`'s
-- recompute had already created runs at ontology 0.10.0. **The YouTube approval
-- is not part of a run's identity**, so a policy change alone can never enqueue
-- anything, and `semantic_run_live_identity_idx` would have deduped a forced
-- run anyway.
--
-- The lever that does work is the one already written down: *"Deploying
-- resolver or scorer code re-scores nothing… Three levers force a fresh run: a
-- new distillation, a new ontology version, or a new model id."* The resolver's
-- behaviour changed — `aws/worker/resolve.py` now emits a `channel_identity`
-- term for every YouTube observation whose channel has a catalogued title — so
-- its version changes with it. A model version that lags its code makes
-- `semantic_runs` state something untrue.
--
-- **What 0.4.0 does that 0.3.0 did not.** One thing only: where the run policy
-- grants `allow_channel_identity`, the payload's `channel_id` is looked up in
-- `ontology.youtube_channels` and the channel's title becomes a term with the
-- `creator` type hint — the same hint an uploader tag takes, and for the same
-- reason. A channel called `Music` must not reach `hub:music`.
--
-- **It mints nothing.** A channel resolves only if its title already matches a
-- curated alias. Everything else becomes an unresolved term, which is the input
-- `EmergentTermMiner` exists for and which the five-user floor governs —
-- minting a concept per channel would put one person's fan-edit channel into
-- the shared vocabulary.
--
-- Retiring 0.3.0 in the same statement, because
-- `finalize_ingestion_run_v031` picks the newest *active* model by `created_at
-- desc` and leaving two active works only by ordering, which is a coincidence
-- rather than a statement.

begin;

insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:resolver:v0.4.0'),
  'ontology_first_resolver', '0.4.0', 'resolver', null,
  '{"fuzzy": false,'
  ' "scene": "decade and sphere must be attested on the same row; a hand-named'
  ' artist keeps the artist-level cross because its per-row dates are wrong",'
  ' "spheres": ["anglophone", "cantonese", "mandarin", "japanese", "korean"],'
  ' "min_tag_length": 3,'
  ' "whole_tag_only": true,'
  ' "composer_periods": true,'
  ' "exact_terms_only": true,'
  ' "marked_genre_wins": "a row stating Mandopop|Pop is Mandopop",'
  ' "incidental_performer_weight": 0.02,'
  ' "classical_performer_min_albums": 2,'
  ' "youtube_channel_identity": "the channel title from'
  ' ontology.youtube_channels becomes a term with the creator type hint, when'
  ' the run policy grants it; no concept is minted from a channel"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'resolver' and version = '0.3.0' and status = 'active';

do $$
declare
  active_resolvers integer;
  newest text;
  enqueued integer;
begin
  select count(*) into active_resolvers
  from ontology.model_versions where model_role = 'resolver' and status = 'active';
  if active_resolvers <> 1 then
    raise exception 'expected exactly one active resolver, found %', active_resolvers;
  end if;

  -- The selection `finalize_ingestion_run_v031` performs, asserted here so a
  -- later insert landing with an older `created_at` fails now rather than
  -- silently resolving with the wrong model.
  select version into newest
  from ontology.model_versions
  where model_role = 'resolver' and status = 'active'
  order by created_at desc, id
  limit 1;
  if newest <> '0.4.0' then
    raise exception 'resolution would pick resolver %, not 0.4.0', newest;
  end if;

  -- **The channel path must be reachable, not merely approved.** `0135` proved
  -- the determination is the one a run would select; this proves the other half
  -- — that the resolver a run would use is the one that reads it. Asserting the
  -- approval alone would be `0117` again: a guard consulting something nothing
  -- populates.
  if not exists (
    select 1 from ontology.youtube_policy_approvals
    where approval_state = 'approved' and revoked_at is null
      and allow_channel_identity
  ) then
    raise exception 'resolver 0.4.0 emits channel terms that no approval grants';
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'resolver 0.4.0: YouTube channel titles become creator-hinted terms'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for resolver 0.4.0', enqueued;
end
$$;

commit;
