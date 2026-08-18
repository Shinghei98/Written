-- 0244 — the model lane gets input, and its mentions get somewhere to land.
--
-- `0243` built the bridge and `extract_mentions` can now run. Two things meant
-- it would run and change nothing, and both are absences rather than mistakes:
--
-- 1. **Nothing writes `source_text_evidence`**, so there is nothing to ask the
--    model about. The table has existed since `0203` and every producer for it
--    was still notional.
-- 2. **Nothing arms `extract_mentions`.** `0209` deliberately left it out —
--    *"because the contract disables the overlay and its handler declines"* —
--    which was right then and is what keeps the job unreachable now.
--
-- And a third, further down the pipe: a model mention could be written and
-- would then stop, because `0234` admits only `projection_field` mentions in
-- three roles the model does not emit.
--
-- ## Evidence is written by the worker, and needs no new key
--
-- The obvious objection is that writing evidence means encrypting, and
-- *"ingestion gets encrypt-only; the worker gets decrypt"*. It does not: the
-- worker already unwraps the account's data key to read raw records, and a
-- plaintext DEK encrypts as well as it decrypts. **No KMS grant changes**, and
-- the property that rule protects — that the internet-facing ingestor cannot
-- read the vault back — is untouched.
--
-- What changes is one table grant. The worker may insert and select evidence
-- for the accounts it is already reading.
--
-- ## Why the model needs its own evidence at all
--
-- `observations.normalized_payload` is the sanitised projection, and *"the
-- projection keeps the fields carrying nothing and excludes the one carrying
-- everything"* — the title. The exact lane mines the projection; the model lane
-- exists precisely to read what the projection excludes, so it reads from the
-- vault and files what it read as evidence. `guard_model_mention_lineage`
-- then has something to hang the mention on, and
-- `sweep_youtube_vault_retention` and `forget_distillation` already know how to
-- redact it.

-- ---------------------------------------------------------------------------
-- 1. The worker may file evidence for the accounts it already reads.
-- ---------------------------------------------------------------------------

grant select, insert on semantic_private.source_text_evidence to semantic_worker;

-- **Not update and not delete.** Evidence is append-only in spirit for the same
-- reason observations are, and the one legitimate erasure — redaction to
-- `refresh_status = 'deleted'` with the text nulled — belongs to
-- `forget_distillation`, which is `security definer` and does not need this
-- grant.

-- ---------------------------------------------------------------------------
-- 2. The armer offers the model lane its work.
-- ---------------------------------------------------------------------------
--
-- **Guarded on the contract, not on a guess.** `extract_mentions` is armed only
-- where the account has evidence the model has not been asked about; an account
-- with none gets no job, so an empty lane costs nothing. The handler still
-- declines while `qwen_overlay` is `off` — the arming is what makes the job
-- reachable, and the contract is what decides whether it does anything.

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
         'overlay:extract_mentions:' || e.user_id::text || ':' || prompt_version,
         now()
    from semantic_private.source_text_evidence e
    join semantic_private.observations o on o.id = e.observation_id
   where e.refresh_status = 'current'
     and o.lifecycle_state = 'active'
     and (target_user is null or e.user_id = target_user)
     -- Evidence nothing has proposed a mention from yet. A model mention
     -- names its invocation item, and an item names its evidence, so "already
     -- asked" is a fact the ledger holds rather than a flag on the row.
     and not exists (
       select 1 from semantic_private.model_invocation_items i
        where i.source_text_evidence_id = e.id
     )
   group by e.user_id
      -- One job per account per prompt version, which the idempotency key also
      -- enforces; the group by is what stops the insert proposing one per row.
      on conflict (idempotency_key) do nothing;

  get diagnostics armed = row_count;
  return armed;
end;
$$;

comment on function semantic_private.arm_extract_mentions is
  'Offers the model lane the evidence nothing has asked about yet. Arming is '
  'not enabling: the handler declines while the contract disables the overlay.';

revoke all on function semantic_private.arm_extract_mentions(uuid, text, text)
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.arm_extract_mentions(uuid, text, text)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- 3. A model mention can reach a provisional entity.
-- ---------------------------------------------------------------------------
--
-- `0234` maps a *projection* role to a family, and its three roles — `album`,
-- `work`, `source_work` — are `0207`'s projection vocabulary. The model emits
-- `mention_extract_v2`'s roles, and the two sets **do not intersect at all**,
-- so every model mention fell out of `provision_exact_misses` silently: not
-- refused, just never matched. The failure mode of a lookup that misses
-- everything looks exactly like a lane that found nothing to say.
--
-- The same authoring rule governs the additions as governed the first three:
-- **the family must say no more than the role knows.** A role that names what
-- part a mention plays in a sentence, and nothing about what kind of thing it
-- is, gets no family — it is left out rather than guessed at, and left out
-- means the mention still exists, is still evidence, and simply mints nothing.

insert into semantic_private.provisional_projection_families
  (mention_role, family, notes)
values
  ('work_or_franchise', 'work',
   'The model naming a work or the franchise it belongs to. `work` is the same '
   'least-committed reading 0234 chose for the projection role: it does not '
   'decide between a song, a composition or a recording, and 0221 is why that '
   'restraint matters.'),
  ('creator_identity', 'creator',
   'The model naming whoever made the thing. Distinct from `performing_group` '
   'and `featured_person` because those say how somebody appears on a record, '
   'and this says that they authored it.'),
  ('performing_group', 'group',
   'A named ensemble. The family says a group exists, not what it plays.'),
  ('featured_person', 'person',
   'A named person appearing on the item. Person rather than creator: being '
   'featured is not authorship, and 0234''s rule is that the family may say no '
   'more than the role knows.')
on conflict (mention_role) do nothing;

-- **Deliberately not mapped**, and each for the same reason: the role says what
-- part the mention plays and nothing about what kind of thing it is.
--
--   primary_subject           what the item is about — could be anything
--   channel_core_topic        a topic, and `topic` is not a provisional family
--   durable_activity_or_idea  ditto
--   publisher, uploader       an account, not an entity the ontology holds
--   incidental_context        explicitly not a claim
--   tag_roster, format_token  vocabulary of the source, not of the world
--   generic_action, analogy   not entities
--   unresolved_generic        the model saying it does not know
--
-- Mapping any of these would mint a provisional entity whose family is a guess,
-- and a wrong family is worse than no mint: it is a false claim with an id.

-- ---------------------------------------------------------------------------
-- 4. And the three functions must admit a model mention.
-- ---------------------------------------------------------------------------
--
-- The role map alone changes nothing while the queries filter
-- `extraction_method = 'projection_field'`. **Widened by name, not by removing
-- the filter**: the point of the column is that a mention says where it came
-- from, and `explicit_addition` or a future method must still have to be
-- argued in rather than inherited.

do $$
declare
  target record;
  source text;
  updated text;
  changed integer := 0;
begin
  for target in
    select p.oid, p.proname,
           pg_get_functiondef(p.oid) as definition
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'semantic_private'
       and p.proname in ('provision_exact_misses', 'build_provisional_candidates',
                         'arm_candidate_overlay')
  loop
    source := target.definition;
    updated := replace(
      source,
      'extraction_method = ''projection_field''',
      'extraction_method in (''projection_field'', ''model_proposed'')');
    if updated <> source then
      execute updated;
      changed := changed + 1;
    end if;
  end loop;

  if changed = 0 then
    raise exception
      '0244: no function was widened to admit a model mention. The literal this '
      'rewrites has moved, and a migration that silently changed nothing would '
      'leave the model lane producing mentions that mint nothing.';
  end if;
  raise notice '0244: widened % function(s) to admit model_proposed mentions', changed;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
begin
  if not has_table_privilege('semantic_worker',
                             'semantic_private.source_text_evidence', 'INSERT') then
    raise exception '0244: the worker still cannot file evidence';
  end if;
  if has_table_privilege('semantic_worker',
                         'semantic_private.source_text_evidence', 'DELETE') then
    raise exception
      '0244: the worker can delete evidence; erasure belongs to forget_distillation';
  end if;
  if has_table_privilege('semantic_ingestor',
                         'semantic_private.source_text_evidence', 'SELECT') then
    raise exception '0244: the ingestion identity can read the vault back';
  end if;

  -- The model's roles reach a family, and the ones that say nothing about kind
  -- still do not.
  select count(*) into n
    from semantic_private.provisional_projection_families
   where mention_role in ('work_or_franchise', 'creator_identity',
                          'performing_group', 'featured_person');
  if n <> 4 then
    raise exception '0244: expected four model roles mapped, found %', n;
  end if;

  select count(*) into n
    from semantic_private.provisional_projection_families
   where mention_role in ('primary_subject', 'incidental_context',
                          'unresolved_generic', 'tag_roster', 'publisher');
  if n <> 0 then
    raise exception
      '0244: a role that says nothing about what kind of thing it is was given '
      'a family; a wrong family is a false claim with an id';
  end if;
end;
$$;
