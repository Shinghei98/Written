-- 0310 — the testing-lane door, keyed to something that survives the write.
--
-- **`0308`'s door could never open, and the reason is a guard doing its job.**
-- It admitted a mention whose invocation named a release manifest with
-- `environment = 'ris_lab'`. But `derive_invocation_lane` — `0239` — discards
-- the caller's `release_manifest_id` and `model_lane_mode` outright and
-- substitutes `authorized_model_release()`, on the stated principle that *"a
-- mistake and an attempt get the same answer: the deployment"*. So every
-- invocation this lane writes points at the deployed production release
-- whatever it asked for, the manifest test never matches, and `0309` failed on
-- its third statement with every calendar mention refused.
--
-- Deploying the RIS manifest as a second *calling-lane* release is not the
-- repair: `derive_invocation_lane` raises when more than one is deployed, so
-- that would stop every model call in the system rather than admit these.
--
-- **The door now keys on `logical_extraction_key`**, which the writer sets and
-- which nothing overwrites — `0236` defines it as what makes a retry the same
-- work, and `0309` writes `ris|<row>|<prompt>|<grammar>`. The prefix is the
-- lane saying which run produced the item.
--
-- **This is weaker than the manifest test would have been, and the difference
-- is worth stating rather than glossing.** A manifest is assigned by the
-- deployment; an extraction key is chosen by whoever inserts. So this is a
-- *marker*, not a boundary: it distinguishes the testing lane's rows from the
-- attested lane's rows, and it would not stop something with write access to
-- `model_invocation_items` from claiming the prefix. What limits that is the
-- grant — `semantic_ingestor` holds zero table privileges and the worker's
-- list is enumerated — and not this string. The `0289` door and the
-- private-lane test are unchanged and still refuse everything else.

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
      -- **The second door (0308, re-keyed by 0310): the internal testing
      -- lane, named by the extraction key its items carry.** Read through
      -- `to_jsonb` because this same trigger guards `mapping_feedback_labels`,
      -- which has no such column; naming it directly would raise there on
      -- every insert, and a table without the column simply never satisfies
      -- the door.
      and not exists (
        select 1
          from semantic_private.model_invocation_items item
         where item.id = (to_jsonb(new) ->> 'model_invocation_item_id')::uuid
           and item.logical_extraction_key like 'ris|%'
      )
  ) then
    raise exception 'private source observations cannot enter generic mention or feedback lanes';
  end if;
  return new;
end;
$function$;

do $$
declare
  body text;
begin
  select pg_get_functiondef(p.oid) into body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'semantic_private'
     and p.proname = 'guard_private_source_generic_lane_v03';

  -- The two conditions that must survive every edit to this guard. Losing
  -- either turns it into a formality, and the failure is silent: a calendar
  -- title entering the generic lane raises nothing, it simply gets written.
  if body not like '%is_private_lane_source%' then
    raise exception '0310: the private-lane test is gone from the guard';
  end if;
  if body not like '%calendar_public_event_is_eligible%' then
    raise exception '0310: the 0289 door is gone from the guard';
  end if;
  if body not like '%logical_extraction_key%' then
    raise exception '0310: the testing-lane door is not there';
  end if;
  -- The manifest test is what could not work; if it comes back, somebody has
  -- re-introduced the dependency `derive_invocation_lane` defeats.
  if body like '%ris_lab%' then
    raise exception '0310: the guard still keys on a manifest the writer cannot set';
  end if;

  -- Calendars are still private. This migration moves the key of a door; it
  -- does not change what counts as a private source, and the two are easy to
  -- confuse when reading it later.
  if not (semantic_private.is_private_lane_source('apple_calendar')
      and semantic_private.is_private_lane_source('google_calendar')
      and semantic_private.is_private_lane_source('outlook_calendar')
      and semantic_private.is_private_lane_source('healthkit')) then
    raise exception '0310: a private-lane source stopped being private';
  end if;
  if semantic_private.is_private_lane_source('apple_music')
     or semantic_private.is_private_lane_source('youtube') then
    raise exception '0310: a public-lane source became private';
  end if;

  raise notice '0310: the door is keyed to the extraction key; every other refusal stands';
end;
$$;
