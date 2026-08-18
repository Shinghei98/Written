-- 0245 — a family the table does not have, and a batch that stopped after two.
--
-- ## `creator` is not a family
--
-- `0244` mapped `creator_identity` to family `creator`. `provisional_entities`
-- has permitted twenty-three families since `0203` and **`creator` is not among
-- them** — the closest truthful ones are `person`, `group` and `organization`,
-- which is exactly the distinction `0203` was drawing.
--
-- The insert succeeded because `provisional_projection_families` carries no
-- check against that list, so the error waits until a mention actually mints:
-- `provision_exact_misses` would build a row with `family = 'creator'` and the
-- check constraint would raise, one account at a time, in a function whose
-- other rows had already been written. A vocabulary error that surfaces as a
-- runtime constraint violation is the worst version of this, because the thing
-- that reports it is nowhere near the thing that decided it.
--
-- **It is removed rather than remapped.** `creator_identity` says somebody
-- authored the item and says nothing about whether they are a person, a group
-- or an organisation; choosing one would be the guess `0234`'s rule exists to
-- forbid — *the family must say no more than the role knows*. A creator whose
-- shape is unknown mints nothing, stays evidence, and waits for a family that
-- can hold it.
--
-- ## And the map now has to agree with the table
--
-- The absent constraint is the reason this shipped, so it stops being absent.

delete from semantic_private.provisional_projection_families
 where mention_role = 'creator_identity';

alter table semantic_private.provisional_projection_families
  drop constraint if exists provisional_projection_families_family_check;

alter table semantic_private.provisional_projection_families
  add constraint provisional_projection_families_family_check
  check (family in (
    'activity','album','anime','book','channel','culture','event','event_type',
    'franchise','game','game_category','group','hub','idea','music_recording',
    'music_work','organization','person','place','platform','sport','tour','work'
  ));

comment on constraint provisional_projection_families_family_check
  on semantic_private.provisional_projection_families is
  'The same twenty-three families provisional_entities permits. Kept as a '
  'literal rather than a foreign key for the reason 0133 gives about pure '
  'literal arrays: a table would let a row quietly change what is enforced. '
  'Both lists moving together is the maintenance cost of that choice, and a '
  'migration that adds a family here without adding it there now fails at the '
  'constraint rather than at somebody''s mint.';

-- ---------------------------------------------------------------------------
-- The batch that stopped after two.
-- ---------------------------------------------------------------------------
--
-- `arm_extract_mentions` keys idempotency on `(user, prompt_version)` and the
-- handler reads `max_items_wire` — two — rows per run. So the first job asked
-- about two pieces of evidence and every later arming collided with the key
-- that job had already used: an account with two hundred titles saw two of
-- them, once, and the armer reported nothing to do for ever after.
--
-- **The key gains the work.** One job per account per prompt version *per batch
-- of outstanding evidence*, so a converged account still arms nothing and an
-- account with work left arms again. The count is the batch identity because it
-- changes exactly when there is new work and not otherwise.

create or replace function semantic_private.arm_extract_mentions(
  target_user uuid default null,
  grammar_version text default 'semantic_grammar_v3',
  prompt_version text default 'qwen_extractor_v5'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  armed integer := 0;
begin
  insert into semantic_private.worker_jobs
    (job_type, user_id, payload, idempotency_key, available_at)
  select 'extract_mentions', e.user_id,
         jsonb_build_object('user_id', e.user_id,
                            'grammar_version', grammar_version,
                            'prompt_version', prompt_version),
         'overlay:extract_mentions:' || e.user_id::text || ':' || prompt_version
           || ':' || count(*)::text,
         now()
    from semantic_private.source_text_evidence e
    join semantic_private.observations o on o.id = e.observation_id
   where e.refresh_status = 'current'
     and o.lifecycle_state = 'active'
     and (target_user is null or e.user_id = target_user)
     and not exists (
       select 1 from semantic_private.model_invocation_items i
        where i.source_text_evidence_id = e.id
     )
   group by e.user_id
      on conflict (idempotency_key) do nothing;

  get diagnostics armed = row_count;
  return armed;
end;
$$;

-- ---------------------------------------------------------------------------
-- What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  bad text;
begin
  select string_agg(family, ', ') into bad
    from semantic_private.provisional_projection_families f
   where not exists (
     select 1 from (values
       ('activity'),('album'),('anime'),('book'),('channel'),('culture'),
       ('event'),('event_type'),('franchise'),('game'),('game_category'),
       ('group'),('hub'),('idea'),('music_recording'),('music_work'),
       ('organization'),('person'),('place'),('platform'),('sport'),('tour'),
       ('work')) as permitted(name)
      where permitted.name = f.family);
  if bad is not null then
    raise exception
      '0245: the projection map still names families provisional_entities '
      'cannot hold: %', bad;
  end if;

  if exists (select 1 from semantic_private.provisional_projection_families
              where mention_role = 'creator_identity') then
    raise exception
      '0245: creator_identity is mapped again. It says somebody authored the '
      'item and nothing about whether they are a person, a group or an '
      'organisation; picking one is the guess the family rule forbids.';
  end if;
end;
$$;
