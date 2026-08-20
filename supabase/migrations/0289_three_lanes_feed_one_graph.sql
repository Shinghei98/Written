-- 0289 — three lanes feed one graph: Spotify joins Music, and Events opens
-- behind the classifier's wall.
--
-- The Cardinal Ontology specification (owner, 2026-08-21, binding) names the
-- lanes YouTube, Music and Events, converging on one graph while their
-- evidence semantics stay distinct. Two owner interpretations of record
-- authorize what this migration admits:
--
--   * **Spotify** (2026-08-21): with the IV.2.1.a/IV.2.5 conflict expressly
--     put to the owner, they directed Spotify into the model lanes. Recorded
--     in CLAUDE.md beside the YouTube interpretation. Nothing else about
--     Spotify moves — the development-mode caps, the removal-before-launch
--     plan and the training-corpus exclusion are separate facts.
--   * **Events** (2026-08-21): all calendars. The spec's own privacy wall
--     stands in front of it: workplace-private, health, political and
--     private-sensitive rows are excluded before Qwen, a private calendar row
--     stays evidence, and only an independently public event identity can be
--     globally minted.
--
-- **The Events wall is the classifier, and the lane is dark until it runs.**
-- A calendar observation may carry a model mention only when the classifier
-- has judged it a public ticketed event eligible for private semantics —
-- eleven ordered exclusions before a title ever leaves the Lambda. The
-- classifications table is empty today (`CALENDAR_CLASSIFIER_ARN` is the off
-- switch), so admitting the sources files nothing yet; the lane lights up
-- when the classifier does, with the wall already in place. That ordering is
-- deliberate: the alternative — open the lane first, filter later — is the
-- one this schema's history forbids.

-- ---------------------------------------------------------------------------
-- 1. The lanes.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.model_input_source_codes()
returns text[]
language sql
immutable
set search_path = ''
as $$
  -- Music: Apple Music, the device library, podcasts — and Spotify, under the
  -- owner's interpretation of record (2026-08-21). YouTube under its own
  -- (2026-08-20). Events: the three calendars, gated per-observation by
  -- `calendar_public_event_is_eligible` — presence in this list licenses the
  -- lane, and the classifier licenses each row. HealthKit has no text.
  select array['apple_music', 'music_library', 'apple_podcasts', 'podcast',
               'youtube', 'spotify',
               'apple_calendar', 'google_calendar', 'outlook_calendar'];
$$;

-- ---------------------------------------------------------------------------
-- 2. The per-row gate for Events.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.calendar_public_event_is_eligible(
  p_observation_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  -- A public ticketed occurrence the classifier judged eligible for private
  -- semantics. Anything else — birthdays, medical, work, friends, unknown —
  -- answers false, and an unclassified row answers false too: the wall fails
  -- closed, which is the only direction a calendar wall may fail.
  select exists (
    select 1 from semantic_private.calendar_event_classifications c
     where c.observation_id = p_observation_id
       and c.user_id = p_user_id
       and c.event_class = 'public_ticketed_event'
       and c.disposition = 'eligible_private_semantics')
$$;

revoke all on function semantic_private.calendar_public_event_is_eligible(uuid, uuid)
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.calendar_public_event_is_eligible(uuid, uuid)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- 3. The wall narrows by predicate, and only for calendars.
-- ---------------------------------------------------------------------------
--
-- `guard_private_source_generic_lane_v03` refuses a mention on any
-- private-lane observation. The narrowing admits exactly one shape through:
-- a calendar observation the classifier has judged public and eligible.
-- HealthKit and every other private-lane refusal are untouched — the guard
-- still refuses them by the same test it always ran.

create or replace function semantic_private.guard_private_source_generic_lane_v03()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if exists (
    select 1
    from semantic_private.observations as observation
    where observation.id = new.observation_id
      and observation.user_id = new.user_id
      and semantic_private.is_private_lane_source(observation.source_code)
      -- The one door (0289): a calendar row the classifier judged a public
      -- ticketed event, eligible for private semantics. The predicate is the
      -- whole of the exception — no source is named here, and a non-calendar
      -- private source can never satisfy it because the classifier only ever
      -- writes calendar observations.
      and not semantic_private.calendar_public_event_is_eligible(
            observation.id, observation.user_id)
  ) then
    raise exception 'private source observations cannot enter generic mention or feedback lanes';
  end if;
  return new;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Policy rows: what each new lane's evidence may say.
-- ---------------------------------------------------------------------------

-- Spotify, by the same derivation 0259 used for YouTube: the source's own
-- weighted actions supply the pairs, crossed with the authored family and
-- role allowlists. Absence still denies.
insert into semantic_private.mention_evidence_policy
  (source_code, action_type, mention_family, mention_role)
select s.source_code, a.key, fam.family, role.role
  from semantic_private.sources s,
       jsonb_each_text(s.action_weights) a,
       (values ('person'), ('group'), ('organization'), ('franchise'),
               ('work'), ('anime'), ('book'), ('game'), ('music_work'),
               ('album'), ('sport'), ('activity'), ('idea'), ('culture'),
               ('event'), ('tour')) as fam(family),
       (values ('primary_subject'), ('featured_person'), ('performing_group'),
               ('work_or_franchise'), ('creator_identity'),
               ('channel_core_topic'), ('durable_activity_or_idea')) as role(role)
 where s.source_code = 'spotify'
   and a.value::float > 0
on conflict do nothing;

-- Calendars, explicitly rather than by weight: `booked` and `scheduled` carry
-- weight 0.0 by 0133's design, and the Cardinal specification supersedes that
-- for the mention lane — an eligible calendar schedule fact is real evidence
-- for the scheduled/booked predicates, never for attendance. The rows are
-- named because there is no weight to derive them from, and naming them here
-- is the decision 0133 asked for: presence permits, absence denies.
insert into semantic_private.mention_evidence_policy
  (source_code, action_type, mention_family, mention_role)
select src.source_code, act.action, fam.family, role.role
  from (values ('apple_calendar'), ('google_calendar'), ('outlook_calendar'))
         as src(source_code),
       (values ('booked'), ('scheduled')) as act(action),
       (values ('person'), ('group'), ('organization'), ('franchise'),
               ('work'), ('sport'), ('activity'), ('idea'), ('culture'),
               ('event'), ('tour')) as fam(family),
       (values ('primary_subject'), ('featured_person'), ('performing_group'),
               ('work_or_franchise'), ('creator_identity'),
               ('channel_core_topic'), ('durable_activity_or_idea')) as role(role)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 5. The armer's work test sees the same wall.
-- ---------------------------------------------------------------------------
--
-- `arm_extract_mentions`' second union half counts vault rows with no filed
-- evidence as pending work. A private calendar row can never file, so without
-- this it would be counted as work forever — a job armed, a no-op run, and a
-- token identity that never drains. Same predicate, patched into the deployed
-- body, so the armer and the filer cannot disagree about what work is.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.arm_extract_mentions(uuid, text, text)'::regprocedure);

  if position('calendar_public_event_is_eligible' in body) > 0 then
    raise notice '0289: the armer already sees the wall';
    return;
  end if;

  patched := replace(body,
    E'             and c.source_code = any(allowed)\n'
    || E'             and not exists (\n'
    || E'               select 1 from semantic_private.source_text_evidence e\n'
    || E'                where e.observation_id = c.current_observation_id\n'
    || E'                  and e.refresh_status <> ''deleted'')',
    E'             and c.source_code = any(allowed)\n'
    || E'             and (c.source_code not in\n'
    || E'                    (''apple_calendar'', ''google_calendar'', ''outlook_calendar'')\n'
    || E'                  or semantic_private.calendar_public_event_is_eligible(\n'
    || E'                       c.current_observation_id, c.user_id))\n'
    || E'             and not exists (\n'
    || E'               select 1 from semantic_private.source_text_evidence e\n'
    || E'                where e.observation_id = c.current_observation_id\n'
    || E'                  and e.refresh_status <> ''deleted'')');
  if patched = body then
    raise exception '0289: the armer''s vault half is not the one 0247 wrote';
  end if;
  execute patched;
end;
$$;

-- ---------------------------------------------------------------------------
-- Both ways.
-- ---------------------------------------------------------------------------

do $$
declare
  lanes text[];
begin
  lanes := semantic_private.model_input_source_codes();
  if array_length(lanes, 1) <> 9 then
    raise exception '0289: expected 9 lanes, found %', array_length(lanes, 1);
  end if;
  if not ('spotify' = any (lanes)) or not ('apple_calendar' = any (lanes)) then
    raise exception '0289: a directed lane is missing';
  end if;
  -- HealthKit stays out: it has no text and no interpretation admits it.
  if 'healthkit' = any (lanes) then
    raise exception '0289: healthkit must never feed a model';
  end if;

  -- The wall fails closed: an unclassified observation is refused. Asserted
  -- against the helper directly — a random id has no classification and must
  -- answer false, the same answer on an empty replay database and on
  -- production before the classifier runs.
  if semantic_private.calendar_public_event_is_eligible(
       '00000000-0000-4000-8000-000000000000'::uuid,
       '00000000-0000-4000-8000-000000000001'::uuid) then
    raise exception '0289: the events wall fails open';
  end if;

  -- The guard still names the private-lane test and now consults the door.
  if position('calendar_public_event_is_eligible' in
              pg_get_functiondef(
                'semantic_private.guard_private_source_generic_lane_v03()'::regprocedure)) = 0 then
    raise exception '0289: the wall was not narrowed';
  end if;
  if position('is_private_lane_source' in
              pg_get_functiondef(
                'semantic_private.guard_private_source_generic_lane_v03()'::regprocedure)) = 0 then
    raise exception '0289: the wall no longer tests the private lane at all';
  end if;
end;
$$;
