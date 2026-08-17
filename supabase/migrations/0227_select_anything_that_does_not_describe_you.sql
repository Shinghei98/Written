-- 0227 — "select anything that does not describe you".
--
-- ## The surface, and the three verbs it exposes
--
-- A personal calibration workflow over `user_term_candidates` — terms the system
-- has proposed and not yet asserted. Scoped to `auth.uid()` with no parameter
-- for whose, like every other `api` function here.
--
-- **The client vocabulary is three verbs**, and the API is what makes that
-- structural rather than a convention a screen remembers:
--
--   * `strike_off` — this does not describe me.
--   * `restore`    — I struck that and I was wrong.
--   * `finish_review` — I have finished this batch.
--
-- **`keep` is never accepted from a client.** It is written by
-- `finish_calibration`, and only for an item that was *exposed*, *left
-- unstruck*, and *part of a batch the user completed*. An abandoned review
-- produces no positive label, because a person who closed the app has not told
-- us the remaining terms were right — and a label that cannot tell those apart
-- is worse than no label. `confirm`, `edit` and `defer` remain in the column's
-- check constraint, reserved, and no function here can write them.
--
-- ## Why `reason` is `ambiguous_rejection` and not something more specific
--
-- `review_events.reason` is `not null` over a diagnostic vocabulary, and the
-- product decision is that **no reason is requested and none is inferred**.
-- `ambiguous_rejection` is the value that already means exactly that: *"a
-- suppression is an `ambiguous_rejection`, and redistribution is disambiguation
-- rather than a negative."* Writing `not_representative` or `not_interested`
-- would be this migration inventing a motive the user was never asked for.
--
-- ## Why `finish_review` is written per item
--
-- `review_item_id` is `not null`, so a completion event has to attach to
-- something. It is written for **every exposed item in the batch**, which makes
-- "was this item part of a completed epoch" answerable from the item rather than
-- by finding one marker row somewhere. That matters for the all-struck case:
-- without it, an epoch where the user struck everything and pressed Done would
-- be indistinguishable from one they abandoned, and those are opposite facts.
--
-- ## What a strike does, and one thing it does not do yet
--
-- A strike records a `strike_off` event **and** an active row in
-- `user_term_suppressions`, which is the personal consequence. **Nothing reads
-- that table yet** — no function in `semantic_private` or `api` references it,
-- because the promotion path it would gate is the overlay, which is off. So the
-- strike is *recorded and not yet enforced*, and this comment is here so the
-- next reader does not assume the enforcement exists because the row does.
-- Wiring it is the promotion path's job, not this surface's.
--
-- **Restoring deactivates the suppression and never deletes it** — `active` goes
-- false and `restored_at` is stamped, so the history of having struck it
-- survives. Retiring is not deleting, and a restore is the user changing their
-- mind rather than the strike never having happened.
--
-- ## A personal strike is not a global verdict
--
-- These events may inform `apply_feedback`, `aggregate_feedback` and
-- `evaluate_release`. **One user does not publish vocabulary.** A person decides
-- whether a term applies to *them*; global promotion stays a separately attested
-- decision over aggregated evidence — which is what `0223`–`0225` froze and what
-- `0224`'s attestation ledger records.
--
-- ## It ships dark
--
-- A fifth surface, `calibration`, gated on its own flag rather than on
-- `memories_reads`. Showing somebody a term the system has *not yet* concluded
-- is a different exposure from showing them one it has, and a flag shared with
-- Memories could not be pulled without taking Memories down with it. The check
-- lives **inside** `assert_surface_allowed`, never beside it.

begin;

-- ---------------------------------------------------------------------------
-- 1. The fifth surface.
-- ---------------------------------------------------------------------------

insert into semantic_private.feature_flags (flag_key, enabled, description)
values ('calibration_reads', false,
        'The personal calibration surface: proposed terms a user may strike. '
        || 'Separate from memories_reads because a candidate is a different '
        || 'exposure from an assertion.')
on conflict (flag_key) do nothing;

create or replace function semantic_private.assert_surface_allowed(surface_name text)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  required_flag text;
begin
  if surface_name is null or surface_name not in (
    'memories', 'matching', 'bio', 'icebreaker', 'calibration'
  ) then
    raise exception 'unsupported assertion surface';
  end if;

  -- **`bio` shares `discovery_profile_reads` with `matching`, deliberately.**
  -- A dynamic bio is a projection of one person shown to another, which is the
  -- same exposure `matching` is, and giving it a flag of its own would let the
  -- two be switched independently when the privacy question is single.
  --
  -- **`calibration` does not share `memories_reads`, for the mirror reason.**
  -- A candidate is a term the system has not concluded; showing one is a
  -- different exposure from showing an assertion, and a shared flag could not be
  -- pulled without taking Memories down with it.
  required_flag := case surface_name
    when 'memories' then 'memories_reads'
    when 'matching' then 'discovery_profile_reads'
    when 'bio' then 'discovery_profile_reads'
    when 'icebreaker' then 'icebreaker_first_exposure'
    when 'calibration' then 'calibration_reads'
  end;

  if not semantic_private.flag_enabled_v031(required_flag, (select auth.uid())) then
    raise exception 'surface % is disabled (%)', surface_name, required_flag
      using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Begin or resume a batch.
-- ---------------------------------------------------------------------------

create or replace function api.begin_calibration(batch_size integer default 8)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me      uuid := (select auth.uid());
  epoch   integer;
  result  jsonb;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  perform semantic_private.assert_surface_allowed('calibration');
  if batch_size is null or batch_size < 1 or batch_size > 25 then
    raise exception 'batch_size must be between 1 and 25';
  end if;

  -- **Resume before starting.** The lowest epoch that has items and no
  -- completion — so a user who closed the app returns to the batch they were
  -- in rather than being handed a fresh one while the old one stays forever
  -- incomplete and therefore forever unlabelled.
  select min(ri.review_epoch) into epoch
    from semantic_private.review_items ri
   where ri.user_id = me
     and not exists (
       select 1 from semantic_private.review_events e
        where e.review_item_id = ri.id and e.user_id = me
          and e.action = 'finish_review');

  if epoch is null then
    return jsonb_build_object('epoch', null, 'items', '[]'::jsonb);
  end if;

  -- **Exposure is recorded when the row is handed out, not when it is
  -- answered.** `assertion_exposures` records on answer and consequently cannot
  -- say what was shown and ignored, which §10 lists among the shadow metrics.
  -- This does not repeat that.
  insert into semantic_private.review_exposures
    (user_id, review_item_id, position, presentation_variant)
  select me, batch.id, batch.rank, 'calibration_v1'
    from (
      select ri.id, ri.rank
        from semantic_private.review_items ri
       where ri.user_id = me and ri.review_epoch = epoch
       order by ri.rank
       limit batch_size
    ) batch
   where not exists (
     select 1 from semantic_private.review_exposures x
      where x.review_item_id = batch.id and x.user_id = me);

  select jsonb_build_object(
    'epoch', epoch,
    'items', coalesce(jsonb_agg(jsonb_build_object(
        'review_item_id', ri.id,
        'concept_id', utc.concept_id,
        'provisional_entity_id', utc.provisional_entity_id,
        'label', coalesce(cr.preferred_label, pe.canonical_label),
        'predicate', utc.user_facing_predicate,
        'confidence_tier', ri.confidence_tier,
        'rank', ri.rank,
        -- The client draws the strike state; it never decides it.
        'struck', exists (
          select 1 from semantic_private.review_events e
           where e.review_item_id = ri.id and e.user_id = me
             and e.action = 'strike_off'
             and not exists (
               select 1 from semantic_private.review_events r2
                where r2.review_item_id = ri.id and r2.user_id = me
                  and r2.action = 'restore' and r2.created_at > e.created_at)))
      order by ri.rank), '[]'::jsonb))
    into result
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
    left join ontology.concept_revisions cr
      on cr.concept_id = utc.concept_id
     and cr.ontology_version_id = (select id from ontology.versions where status = 'published')
    left join semantic_private.provisional_entities pe
      on pe.id = utc.provisional_entity_id
   where ri.user_id = me and ri.review_epoch = epoch
     and exists (select 1 from semantic_private.review_exposures x
                  where x.review_item_id = ri.id and x.user_id = me);

  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Strike, and restore.
-- ---------------------------------------------------------------------------

create or replace function api.strike_calibration_item(item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me       uuid := (select auth.uid());
  row_item record;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  perform semantic_private.assert_surface_allowed('calibration');

  select ri.id, ri.review_epoch, ri.model_revision, ri.primary_route_id,
         utc.concept_id, utc.provisional_entity_id, utc.user_facing_predicate
    into row_item
    from semantic_private.review_items ri
    join semantic_private.user_term_candidates utc
      on utc.id = ri.candidate_id and utc.user_id = ri.user_id
   where ri.id = item and ri.user_id = me;
  if row_item.id is null then
    raise exception 'no such review item';
  end if;

  -- **A strike on something never shown is not a strike.** The verdict is only
  -- interpretable against the exposure that produced it.
  if not exists (select 1 from semantic_private.review_exposures x
                  where x.review_item_id = item and x.user_id = me) then
    raise exception 'that item has not been shown';
  end if;

  insert into semantic_private.review_events
    (user_id, review_item_id, exposure_id, action, reason, model_revision, route_version)
  select me, item,
         (select x.id from semantic_private.review_exposures x
           where x.review_item_id = item and x.user_id = me
           order by x.displayed_at desc limit 1),
         'strike_off',
         -- No reason was asked for and none is inferred. This is the value that
         -- already means precisely that.
         'ambiguous_rejection',
         row_item.model_revision, row_item.primary_route_id;

  -- The personal consequence. Recorded here; enforced by the promotion path,
  -- which does not read this table yet.
  insert into semantic_private.user_term_suppressions
    (user_id, concept_id, provisional_entity_id, user_facing_predicate,
     active, source_review_item_id, source_review_epoch)
  values (me, row_item.concept_id, row_item.provisional_entity_id,
          row_item.user_facing_predicate, true, item, row_item.review_epoch);
end;
$$;

create or replace function api.restore_calibration_item(item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me       uuid := (select auth.uid());
  row_item record;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  perform semantic_private.assert_surface_allowed('calibration');

  select ri.id, ri.model_revision, ri.primary_route_id into row_item
    from semantic_private.review_items ri
   where ri.id = item and ri.user_id = me;
  if row_item.id is null then
    raise exception 'no such review item';
  end if;

  insert into semantic_private.review_events
    (user_id, review_item_id, exposure_id, action, reason, model_revision, route_version)
  select me, item,
         (select x.id from semantic_private.review_exposures x
           where x.review_item_id = item and x.user_id = me
           order by x.displayed_at desc limit 1),
         'restore', 'correct', row_item.model_revision, row_item.primary_route_id;

  -- **Deactivated, never deleted.** The strike happened and the record of it
  -- outlives the user changing their mind.
  update semantic_private.user_term_suppressions
     set active = false, restored_at = now()
   where user_id = me and source_review_item_id = item and active;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Complete the batch, which is the only thing that writes `keep`.
-- ---------------------------------------------------------------------------

create or replace function api.finish_calibration(epoch integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me     uuid := (select auth.uid());
  kept   integer := 0;
  closed integer := 0;
begin
  if me is null then
    raise exception 'not signed in' using errcode = 'insufficient_privilege';
  end if;
  perform semantic_private.assert_surface_allowed('calibration');

  -- **`keep` first, and only for exposed-and-unstruck.** Written here and
  -- nowhere else: silence inside a batch somebody finished is weak evidence the
  -- term was right, and silence in a batch they abandoned is no evidence at all.
  with exposed as (
    select ri.id, ri.model_revision, ri.primary_route_id,
           (select x.id from semantic_private.review_exposures x
             where x.review_item_id = ri.id and x.user_id = me
             order by x.displayed_at desc limit 1) as exposure_id
      from semantic_private.review_items ri
     where ri.user_id = me and ri.review_epoch = epoch
       and exists (select 1 from semantic_private.review_exposures x
                    where x.review_item_id = ri.id and x.user_id = me)
       and not exists (select 1 from semantic_private.review_events e
                        where e.review_item_id = ri.id and e.user_id = me
                          and e.action = 'finish_review')
  ),
  unstruck as (
    select * from exposed e
     where not exists (
       select 1 from semantic_private.review_events ev
        where ev.review_item_id = e.id and ev.user_id = me
          and ev.action = 'strike_off'
          and not exists (
            select 1 from semantic_private.review_events r2
             where r2.review_item_id = e.id and r2.user_id = me
               and r2.action = 'restore' and r2.created_at > ev.created_at))
  ),
  wrote_keep as (
    insert into semantic_private.review_events
      (user_id, review_item_id, exposure_id, action, reason, model_revision, route_version)
    select me, id, exposure_id, 'keep', 'correct', model_revision, primary_route_id
      from unstruck
    returning 1
  ),
  wrote_finish as (
    insert into semantic_private.review_events
      (user_id, review_item_id, exposure_id, action, reason, model_revision, route_version)
    select me, e.id, e.exposure_id, 'finish_review',
           case when u.id is null then 'ambiguous_rejection' else 'correct' end,
           e.model_revision, e.primary_route_id
      from exposed e left join unstruck u on u.id = e.id
    returning 1
  )
  select (select count(*) from wrote_keep), (select count(*) from wrote_finish)
    into kept, closed;

  return jsonb_build_object('epoch', epoch, 'kept', kept, 'closed', closed);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants: the client may call these four and nothing else.
-- ---------------------------------------------------------------------------

revoke all on function api.begin_calibration(integer) from public, anon;
revoke all on function api.strike_calibration_item(uuid) from public, anon;
revoke all on function api.restore_calibration_item(uuid) from public, anon;
revoke all on function api.finish_calibration(integer) from public, anon;
grant execute on function api.begin_calibration(integer) to authenticated;
grant execute on function api.strike_calibration_item(uuid) to authenticated;
grant execute on function api.restore_calibration_item(uuid) to authenticated;
grant execute on function api.finish_calibration(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Prove it.
-- ---------------------------------------------------------------------------

do $$
declare
  writable text;
begin
  -- **The reserved verbs are unreachable from the client**, checked against the
  -- function bodies rather than promised in a comment. `confirm`, `edit` and
  -- `defer` stay in the check constraint for later and nothing here writes one.
  --
  -- **Scoped to functions that write `review_events`.** The first version
  -- scanned every `api` function for the literals and flagged
  -- `api.confirm_assertion`, which has existed since Phase 3, writes a different
  -- table, and has nothing to do with this vocabulary. A check that fires on a
  -- correct function is a check that gets deleted rather than fixed.
  select string_agg(p.proname, ', ') into writable
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'api'
     and p.prokind = 'f'
     and p.prosrc like '%review_events%'
     and (p.prosrc like '%''confirm''%' or p.prosrc like '%''edit''%'
          or p.prosrc like '%''defer''%');
  if writable is not null then
    raise exception '0227: api function(s) can write a reserved review action: %', writable;
  end if;

  -- The surface exists, is gated, and is off.
  if not exists (select 1 from semantic_private.feature_flags
                  where flag_key = 'calibration_reads' and enabled = false) then
    raise exception '0227: calibration_reads is missing or already enabled';
  end if;

  -- **The gate answers both ways**, which is the only way to believe it.
  begin
    perform semantic_private.assert_surface_allowed('calibration');
    raise exception '0227: the calibration surface answered while its flag is false';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform semantic_private.assert_surface_allowed('nonsense');
    raise exception '0227: an unknown surface was accepted';
  exception when others then
    if sqlerrm like '%was accepted%' then raise; end if;
  end;

  -- **`memories` must still track its own flag** — and that is asserted rather
  -- than its *passing* being asserted. The first version called it and required
  -- success, which held in production where `memories_reads` is true and failed
  -- every replay, where flags default false. Demanding production state is the
  -- precondition defect `0173` and eight others were repaired for: say what must
  -- be true *given* the input, so the same assertion answers on an empty
  -- database and on a full one.
  declare
    memories_on boolean;
    memories_raised boolean := false;
  begin
    select enabled into memories_on
      from semantic_private.feature_flags where flag_key = 'memories_reads';
    begin
      perform semantic_private.assert_surface_allowed('memories');
    exception when insufficient_privilege then
      memories_raised := true;
    end;
    if memories_raised = coalesce(memories_on, false) then
      raise exception
        '0227: memories_reads is % and the surface %', memories_on,
        case when memories_raised then 'refused' else 'answered' end;
    end if;
  end;

  raise notice '0227: calibration surface registered, flag off, reserved verbs unreachable';
end;
$$;

commit;
