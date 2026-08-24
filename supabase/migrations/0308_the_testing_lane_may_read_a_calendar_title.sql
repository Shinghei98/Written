-- 0308 — one door, named, for the lane that is allowed through it.
--
-- **What this changes, said plainly first.** A calendar title may now become
-- an `observation_mentions` row — but only where that row descends from a
-- model invocation whose release manifest says `environment = 'ris_lab'`.
-- Nothing else moves. The attested serving lane, the app, the worker and the
-- projection guards all behave exactly as before, and `is_private_lane_source`
-- still says a calendar is private.
--
-- **Why it is needed.** `guard_private_source_generic_lane_v03` admits a
-- private-lane observation into the mention lane only where
-- `calendar_public_event_is_eligible` passes — the `0289` door, meaning a
-- calendar row the classifier judged an independently public ticketed event.
-- Measured 2026-08-22, that predicate passes for **0 of 1,049** calendar
-- observations in this database, so the entire calendar corpus was
-- unreachable to the testing lane. The owner's direction of 2026-08-22 is
-- that on RIS the only things that matter are how much information is
-- extracted, how accurate the labels are and how accurately terms merge, with
-- the privacy projections bypassed for internal testing; and, asked directly,
-- that calendar must be fully distilled.
--
-- **Why a door rather than removing the source from the private list.**
-- Widening `is_private_lane_source` would take the calendars out of the
-- private lane everywhere at once — the generic mapping lane, the feedback
-- lane, the projection guard and the sanitised projection, four prohibitions
-- that have nothing to do with this. The failure mode of a deny-list is
-- silence, and the failure mode of *shrinking* one is silence in four places.
-- This adds a condition instead, so the refusal still stands for every writer
-- that is not this lane, and reverting is deleting one clause.
--
-- **What it costs, so the cost is written down rather than discovered.** A
-- calendar title is somebody's diary. Rows written through this door put that
-- title in `observation_mentions.mention_text`, which is a plaintext column
-- the sanitised projection was built to keep it out of. That is the whole of
-- what is being traded, it is traded on data the owner and collaborators have
-- given for exactly this, and it does not travel: nothing user-facing reads
-- `mention_text`, and `III.E.3.b`'s display rule is untouched.
--
-- **The guard is not restated, it is extended.** The `0289` door and the
-- private-lane test below are the deployed text, read from
-- `pg_get_functiondef` before this was written; only the third condition is
-- new. Restating a deployed body from memory is a defect this project has
-- paid for about six times.

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
      -- **The second door (0308): the internal testing lane.** Keyed on the
      -- release manifest's environment rather than on a source, a flag or a
      -- role, because the manifest is the one place that already records
      -- which lane produced a row and it is written by the migration that
      -- publishes the run rather than by whoever is inserting.
      --
      -- Read through `to_jsonb` because this same trigger guards
      -- `mapping_feedback_labels`, which has no such column; naming it
      -- directly would raise there on every insert. A table without the
      -- column simply never satisfies the door.
      and not exists (
        select 1
          from semantic_private.model_invocation_items item
          join semantic_private.model_invocations invocation
            on invocation.id = item.invocation_id
          join ontology.release_manifests manifest
            on manifest.id = invocation.release_manifest_id
         where item.id = (to_jsonb(new) ->> 'model_invocation_item_id')::uuid
           and manifest.environment = 'ris_lab'
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

  -- **The two conditions that must survive are asserted, not assumed.**
  -- A later edit that drops either one turns this guard into a formality, and
  -- the failure would be silent — a calendar title entering the generic lane
  -- raises nothing, it simply gets written.
  if body not like '%is_private_lane_source%' then
    raise exception '0308: the private-lane test is gone from the guard';
  end if;
  if body not like '%calendar_public_event_is_eligible%' then
    raise exception '0308: the 0289 door is gone from the guard';
  end if;
  if body not like '%ris_lab%' then
    raise exception '0308: the door this migration exists to add is not there';
  end if;

  -- The calendars are still private. This migration is a door in the guard
  -- and not a change to what counts as private, and the two are easy to
  -- confuse later.
  if not (semantic_private.is_private_lane_source('apple_calendar')
      and semantic_private.is_private_lane_source('google_calendar')
      and semantic_private.is_private_lane_source('outlook_calendar')
      and semantic_private.is_private_lane_source('healthkit')) then
    raise exception '0308: a private-lane source stopped being private';
  end if;
  if semantic_private.is_private_lane_source('apple_music')
     or semantic_private.is_private_lane_source('youtube') then
    raise exception '0308: a public-lane source became private';
  end if;

  -- **No manifest in this database may claim the testing environment yet.**
  -- `0309` publishes the first one. Asserting it here means that if this
  -- migration is ever replayed against a database where something else has
  -- claimed `ris_lab`, the door's meaning has changed and it says so.
  if exists (select 1 from ontology.release_manifests
              where environment = 'ris_lab'
                and prompt_version <> 'qwen_extractor_v14') then
    raise exception '0308: something other than the RIS lane claims ris_lab';
  end if;

  raise notice '0308: the testing lane has a door; every other refusal stands';
end;
$$;
