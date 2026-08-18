-- 0238 — the source text can actually be deleted.
--
-- Stage 2, last of four.
--
-- ## A state the schema described and refused to allow
--
-- `source_text_evidence` says, in a comment beside its own check constraint:
--
--     An expired row keeps its identity and loses its content, the same shape
--     the vault uses for an erasure: `lifecycle_state = 'deleted'` with the
--     payload nulled, never a row delete.
--
-- The column above it is `encrypted_text bytea not null`. **The state it
-- describes is unreachable.** A row can be marked `deleted` and keep its
-- ciphertext, and `source_text_evidence_deleted_check` ties `refresh_status` to
-- `deleted_at` and says nothing about the payload — so the state and the
-- redaction can disagree, which is exactly what
-- `raw_source_records_payload_location_check` exists one table over to prevent.
--
-- This is the only mutable text store in the vault. It is where retained
-- provider text lives, it is what the Qwen lane reads, and `0237`'s fourth
-- refusal — a mention whose source text has been deleted — had no way to become
-- true, because nothing could delete it.
--
-- ## And `forget_distillation` did not touch it
--
-- Nine steps, six tables: assertions, observations, raw records, candidates,
-- provisionals, connections. **Not this one.** So a person who asked for their
-- distillation to be forgotten kept every retained title, description and
-- channel label in `encrypted_text`, indefinitely — the copy they could not see,
-- which is the worse half of the arrangement `CLAUDE.md` names when it says a
-- deletion control names both schemas or it is not finished.
--
-- Model invocation lineage is deliberately not redacted here and that is a
-- decision rather than an omission: `model_invocations` and
-- `model_invocation_items` hold counts, identifiers, closed vocabularies and
-- keyed digests, and no column of either may hold provider text —
-- `supabase/tests/0236_invocation_lineage_contract.sql` is where that allowlist
-- is enforced. There is nothing in them to redact. Account deletion still takes
-- them, through `user_id`.

-- ---------------------------------------------------------------------------
-- 1. Deleted means the payload is gone.
-- ---------------------------------------------------------------------------

alter table semantic_private.source_text_evidence
  alter column encrypted_text drop not null;

alter table semantic_private.source_text_evidence
  drop constraint if exists source_text_evidence_payload_location_check;
alter table semantic_private.source_text_evidence
  add constraint source_text_evidence_payload_location_check
  check (
    (refresh_status = 'deleted' and encrypted_text is null)
    or (refresh_status <> 'deleted' and encrypted_text is not null));

comment on constraint source_text_evidence_payload_location_check
  on semantic_private.source_text_evidence is
  'The state and the redaction cannot disagree. There is no way to mark a row '
  'deleted while its text remains, and no way to drop the text while the row '
  'still claims to hold it — the same shape raw_source_records has had since 0046.';

-- ---------------------------------------------------------------------------
-- 2. Forgetting reaches the text.
-- ---------------------------------------------------------------------------

create or replace function api.forget_distillation()
returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout to '60s'
as $$
declare
  me uuid := auth.uid();
  retired integer := 0;
  excluded_rows integer := 0;
  redacted integer := 0;
  withdrawn integer := 0;
  quarantined integer := 0;
  text_redacted integer := 0;
begin
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;

  perform set_config('written.forget_distillation_v031', '1', true);

  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where user_id = me
     and assertion_origin = 'inferred'
     and machine_state <> 'inactive';
  get diagnostics retired = row_count;

  update semantic_private.observations
     set lifecycle_state = 'deleted',
         exclusion_code  = 'user_deleted',
         excluded_at     = now()
   where user_id = me
     and lifecycle_state <> 'deleted';
  get diagnostics excluded_rows = row_count;

  update semantic_private.raw_source_records
     set lifecycle_state   = 'deleted',
         deleted_at        = now(),
         encrypted_payload = null,
         raw_blob_ref      = null
   where user_id = me
     and lifecycle_state <> 'deleted';
  get diagnostics redacted = row_count;

  -- **3d. The retained provider text, added by `0238`.** The step that was
  --      missing: this is the only mutable text store in the vault, and an
  --      erasure that left it holding titles kept the copy the person could not
  --      see while removing the one they could.
  --
  --      The same shape as step 3 — state and payload move together, and
  --      `source_text_evidence_payload_location_check` is what makes that true
  --      rather than intended.
  update semantic_private.source_text_evidence
     set refresh_status = 'deleted',
         deleted_at     = now(),
         encrypted_text = null
   where user_id = me
     and refresh_status <> 'deleted';
  get diagnostics text_redacted = row_count;

  update semantic_private.user_term_candidates
     set lifecycle_state = 'withdrawn', updated_at = now()
   where user_id = me
     and lifecycle_state <> 'withdrawn';
  get diagnostics withdrawn = row_count;

  update semantic_private.provisional_entities
     set identity_state = 'quarantined', updated_at = now()
   where user_id = me
     and scope = 'user'
     and identity_state <> 'quarantined';
  get diagnostics quarantined = row_count;

  delete from semantic_private.source_connections
   where user_id = me;

  if excluded_rows > 0 or redacted > 0 or retired > 0
     or withdrawn > 0 or quarantined > 0 or text_redacted > 0 then
    insert into semantic_private.user_state_versions (user_id, revision)
    values (me, 1)
    on conflict (user_id) do update
    set revision = semantic_private.user_state_versions.revision + 1,
        updated_at = now();
  end if;

  return jsonb_build_object(
    'assertions_retired', retired,
    'observations_excluded', excluded_rows,
    'records_redacted', redacted,
    'source_text_redacted', text_redacted,
    'candidates_withdrawn', withdrawn,
    'provisionals_quarantined', quarantined
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
begin
  -- The state the comment described. Read back from the catalog, because a
  -- constraint that exists only in a migration file is a claim about a database
  -- rather than a property of one.
  select count(*) into n
    from information_schema.columns
   where table_schema = 'semantic_private' and table_name = 'source_text_evidence'
     and column_name = 'encrypted_text' and is_nullable = 'YES';
  if n <> 1 then
    raise exception '0238: source_text_evidence.encrypted_text is still not null';
  end if;

  -- And the erasure names it. A source-text step that stops being called is the
  -- defect this migration exists to close, so its absence fails here.
  if position('source_text_evidence' in
              pg_get_functiondef('api.forget_distillation()'::regprocedure)) = 0 then
    raise exception '0238: forget_distillation no longer redacts the source text';
  end if;
end;
$$;
