-- 0139 — Spotify leaves David's vault, and `top_track` earns a weight.
--
-- **Two changes in one migration because their order is the whole point.**
-- The scorer reads `semantic_private.sources.action_weights` *live* at score
-- time — `aws/worker/score.py` at 210, 267, 306 and 316 all join `sources` and
-- read `action_weights ->> o.action_type` — and never reads the
-- `observations.action_weight` column stamped at ingestion. So weighting
-- `top_track` retroactively re-weights every Spotify observation already in the
-- vault, and the only ones there belong to the wrong person.
--
-- Split across two migrations, the window between them is a re-score that hands
-- David a musical profile built from somebody else's listening. In one
-- transaction the order is structural rather than remembered.
--
-- ## What is being withdrawn, and why it is not a change of mind
--
-- A Spotify account was connected to David's Written account on 2026-08-13 to
-- prove the ingestion path, and **it is not his** — it is Timi's, distilled
-- under his account by an arrangement mistake rather than a code one. It
-- worked: 593 raw records, 580 observations, 9 accepted mappings, and —
-- measured either side of a worker run — **zero change to his 67 eligible
-- assertions**, the same list character for character.
--
-- "Nothing in Postgres is ever deleted" is the rule for a distillation somebody
-- consented to. This is evidence about one person filed under another, which is
-- the case that rule was never about.
--
-- ## The vault refuses to be deleted from, and the first draft of this
-- ## migration found out the expensive way
--
-- This began as `delete from observations where source_code = 'spotify'` and
-- Postgres refused it: **`ingestion_run_items_observation_id_user_id_fkey`**, a
-- *composite* `(observation_id, user_id)` foreign key with **no cascade**, and
-- `ingestion_run_items` is append-only — `guard_ingestion_run_item_v031` raises
-- on any operation that is not an INSERT. `current_source_items` holds a second
-- such key and yields only under the finalizer's own flag. So a promoted
-- observation can never be deleted, by construction, and impersonating the
-- finalizer to reach one is what would make that guard stop meaning anything.
--
-- Worth recording *why* the constraint was missed: an `information_schema`
-- query over `constraint_column_usage` did not report it, because that view
-- resolves composite keys by column and the pair did not surface. `pg_constraint`
-- with `confrelid` shows all twelve. **Ask `pg_constraint`, not
-- `information_schema`, before writing a delete.**
--
-- ## So this excludes and erases instead, which is what the schema provides
--
-- Two different mechanisms, because the two tables hold different things:
--
-- **Observations are excluded.** `guard_observation_immutable` freezes
-- twenty-one columns and deliberately not `lifecycle_state`, `exclusion_code`
-- or `excluded_at` — the guard was written to permit exactly this. And it is
-- effective rather than cosmetic: `aws/worker/resolve.py` selects
-- `o.lifecycle_state = 'active'` at 763 and 863, so an excluded observation is
-- invisible to resolution and produces no mapping on any future run.
-- `user_deleted` is the honest code of the five the projection allows: the
-- others are policy, retention, supersession and legacy sanitation, and none of
-- them is what happened here.
--
-- **Raw records are erased.** `raw_source_records_payload_location_check`
-- requires `num_nonnulls(encrypted_payload, raw_blob_ref) = 0` of a `deleted`
-- row, so the state and the destruction of the ciphertext are one act the
-- schema will not let you separate. `guard_raw_source_record_update` permits
-- it, freezing identity, source, purpose and provenance and leaving lifecycle
-- alone. **This is a real erasure**: the borrowed listening is gone, and what
-- remains is a skeleton of hashes, fingerprints and timestamps that cannot
-- reconstruct a single track.
--
-- **The 9 mappings and 4 `assertion_evidence` rows are left alone**, and that
-- is deliberate rather than lazy. Both are keyed to the run and the score
-- version that produced them, so they are the record of what the resolver
-- actually did that day — the same reasoning that keeps a corrected concept's
-- old mappings rather than rewriting history. The next run simply produces no
-- Spotify mappings, because the observations behind them are no longer active.
--
-- ## The weights
--
-- `top_track` and `top_artist` have been `.unweighted` in
-- `SemanticSource.actionsByDataType` since Spotify was mapped — the deliberate
-- middle answer, a real signal the server has no weight for *yet*, kept apart
-- from "structurally not an act". Measured on the 593-row distillation: 500
-- `top_track` and 60 `top_artist` observations, every one weighted 0.0, against
-- 20 `followed_artist` at 0.55. **All 9 mappings came from those 20 rows**, so
-- 97% of a Spotify library was inert, and an account whose only music source is
-- Spotify could distil the lot and assert nothing.
--
-- `top_track` at 0.78 is `recently_played`'s weight on both music sources, for
-- the same reason: it reports what somebody actually played, rather than a
-- catalogue row or a suggestion. Apple's equivalent is `heavy_rotation`, still
-- unweighted for want of a decision rather than by one.
--
-- `top_artist` at 0.55 matches `followed_artist` and sits deliberately *below*
-- `top_track`, for a reason worth writing down: **the two derive from the same
-- listening.** Spotify computes both from one play history, so an artist with
-- tracks in the top 500 is counted once for the tracks and again for itself.
-- Apple has the same shape — `library_artist` beside `library_song` — so this
-- is consistent rather than new, but it is a double count either way and is the
-- first thing to look at if artists come out overweight.
--
-- **`rank` is carried and unused.** `normalizedPayload` keeps it, so a rank-1
-- and a rank-500 track arrive distinguishable and are weighted identically.
-- An approximation, not an oversight, and the second dial to turn.
--
-- ## Why a scorer version, when excluding already bumps the revision
--
-- Excluding an observation fires `observation_lifecycle_bump_semantic_revision`,
-- so the revision moves on its own and every inferred assertion goes stale —
-- David's Memories page will be blank until the worker runs, which is the
-- documented behaviour rather than a fault. But the *weights* change scores for
-- every account with music, and a weight lives in none of the five things a
-- run's identity is made of: `(user, revision, ontology version, resolver,
-- scorer)`. `0135` granted a policy, enqueued zero jobs and learned this. The
-- model version is the lever, and the parameters belong on the model row where
-- a later reader looks rather than in a commit message.

begin;

-- 1. The observations stop being evidence. `where lifecycle_state = 'active'`
--    keeps this idempotent and keeps the revision bump proportional to what
--    actually changed.
update semantic_private.observations
   set lifecycle_state = 'excluded',
       exclusion_code = 'user_deleted',
       excluded_at = now()
 where source_code = 'spotify'
   and lifecycle_state = 'active';

-- 2. The ciphertext is destroyed. The check constraint will refuse this row if
--    the payload survives, so the two halves cannot come apart.
update semantic_private.raw_source_records
   set lifecycle_state = 'deleted',
       encrypted_payload = null,
       raw_blob_ref = null,
       deleted_at = now()
 where source_code = 'spotify'
   and lifecycle_state <> 'deleted';

-- 3. Only now may the weights move.
update semantic_private.sources
   set action_weights = action_weights
     || '{"top_track": 0.78, "top_artist": 0.55}'::jsonb
 where source_code = 'spotify';

-- 4. The lever that makes any of it recompute.
insert into ontology.model_versions (
  id, model_key, version, model_role, code_hash, parameters, status
) values (
  ontology.stable_uuid('written:model:scorer:v0.8.0'),
  'missing_aware_late_fusion', '0.8.0', 'scorer', null,
  '{"half_weight": 6.0, "half_observations": 4.0, "eligible_strength": 0.35,'
  ' "classical_performer_min_albums": 2, "incidental_performer_weight": 0.02,'
  ' "never_asserted_kinds": ["hub"],'
  ' "work_eligible_strength": 0.25,'
  ' "subscribed_and_liked": "a YouTube concept attested by both a subscription'
  ' and a like is eligible regardless of strength; the conjunction is a'
  ' different kind of evidence, not a larger amount of one",'
  ' "spotify_top_track_weight": 0.78,'
  ' "spotify_top_artist_weight": 0.55,'
  ' "spotify_top_note": "top_track and top_artist derive from one play history,'
  ' so an artist is counted for its tracks and again for itself; rank is'
  ' carried in the projection and not yet used to modulate weight",'
  ' "stability": "0.0 on a first run; absence of observation is not evidence"}'::jsonb,
  'active'
) on conflict (id) do nothing;

update ontology.model_versions
   set status = 'retired'
 where model_role = 'scorer' and version = '0.7.0' and status = 'active';

do $$
declare
  active_scorers integer;
  newest text;
  leftover integer;
  weights jsonb;
  enqueued integer;
begin
  -- Retirement is not deletion: `on delete restrict` protects the runs that
  -- point at 0.7.0, and a run recording which model computed it is the whole
  -- reason the column exists. Exactly one active is what the finalizer's
  -- `order by created_at desc` needs in order to be a statement rather than a
  -- coincidence.
  select count(*) into active_scorers
  from ontology.model_versions where model_role = 'scorer' and status = 'active';
  if active_scorers <> 1 then
    raise exception 'expected exactly one active scorer, found %', active_scorers;
  end if;

  select version into newest
  from ontology.model_versions
  where model_role = 'scorer' and status = 'active'
  order by created_at desc, id
  limit 1;
  if newest <> '0.8.0' then
    raise exception 'finalization would pick scorer %, not 0.8.0', newest;
  end if;

  -- **The withdrawal is asserted, not assumed.** An `update` reports no error
  -- when it matches nothing, so a predicate that quietly stopped matching would
  -- leave the rows active and the weights raised over them — precisely the
  -- combination this migration exists to prevent. Zero is also the right answer
  -- on a replay against an empty database, so the check is that nothing is left
  -- active rather than that something moved.
  select count(*) into leftover
  from semantic_private.observations
  where source_code = 'spotify' and lifecycle_state = 'active';
  if leftover <> 0 then
    raise exception 'spotify observations are still active: %', leftover;
  end if;

  select count(*) into leftover
  from semantic_private.raw_source_records
  where source_code = 'spotify' and lifecycle_state <> 'deleted';
  if leftover <> 0 then
    raise exception 'spotify raw records are not all deleted: %', leftover;
  end if;

  -- The erasure itself, asserted separately from the state. The check
  -- constraint already forbids a `deleted` row holding a payload, so this can
  -- only fail if that constraint were ever relaxed — which is exactly when
  -- somebody would want to be told.
  select count(*) into leftover
  from semantic_private.raw_source_records
  where source_code = 'spotify'
    and num_nonnulls(encrypted_payload, raw_blob_ref) > 0;
  if leftover <> 0 then
    raise exception 'spotify ciphertext survived erasure: %', leftover;
  end if;

  -- The weights the scorer will read. Asserted positive rather than merely
  -- present, because `coalesce(..., 0.0)` in every one of the scorer's four
  -- lookups makes a missing key and a zero the same silence — which is how
  -- `top_track` stayed inert through a whole distillation without failing.
  select action_weights into weights
  from semantic_private.sources where source_code = 'spotify';
  if coalesce((weights ->> 'top_track')::double precision, 0) <= 0
     or coalesce((weights ->> 'top_artist')::double precision, 0) <= 0 then
    raise exception 'spotify top_track/top_artist weights are not both positive: %', weights;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
    'scorer 0.8.0: spotify top_track and top_artist carry weight'
  ) into enqueued;
  raise notice 'enqueued % recompute job(s) for scorer 0.8.0', enqueued;
end
$$;

commit;
