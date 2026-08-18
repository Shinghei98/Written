-- 0243 — the model lane is a second identity, and the bridge is what it hands back.
--
-- `extract_mentions` has raised `NotImplementedError` in every mode but `off`
-- since it was written, and the reason it could not simply be filled in is a
-- rule this schema already enforces: **`0241` asserts that `semantic_worker`
-- cannot execute `record_model_invocation`.** The deterministic worker is the
-- process that wants to write a mention, and it is precisely the process
-- forbidden from recording the call that justifies one. That is not an
-- oversight to route around — it is the same shape as `messages`, where the one
-- client positioned to write the row is the one forbidden from writing it.
--
-- So the bridge is two identities and a handoff, not one function:
--
--   semantic_model_worker   invokes the gateway, records the call and its items
--   semantic_worker         writes the mention, naming an item it did not create
--
-- Neither can do the other's half. `guard_model_mention_lineage` (`0237`) is
-- what makes the handoff safe in the direction that matters: a mention must
-- name an item that exists, that succeeded, and whose invocation ran in a lane
-- permitted to say something about a person. The worker cannot forge one,
-- because it cannot write `model_invocation_items` at all.
--
-- ## What this migration adds
--
-- One function. `record_model_invocation` returns the invocation id, which is
-- not enough to write a mention — a mention names an **item**. The model lane
-- needs to read back what it just wrote, and it holds no select on the table
-- either, deliberately: `0241` left it with exactly one capability.
--
-- `model_invocation_lineage` is that read, scoped to one invocation, returning
-- only what a mention needs to reference. It is `security definer` for the same
-- reason `record_model_invocation` is — the privilege belongs to the code that
-- upholds the invariant rather than to the role that calls it.
--
-- **It is not granted to `semantic_worker`.** The worker receives the lineage
-- from the model lane in the same process, as a value; it never acquires the
-- ability to go and look. A worker that could read invocation items could find
-- a succeeded item belonging to some other run and hang a mention off it.

-- ---------------------------------------------------------------------------
-- 1. The lineage, readable by the identity that created it.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.model_invocation_lineage(
  p_invocation_id uuid
)
returns table (
  item_id uuid,
  item_index integer,
  outcome text,
  user_id uuid,
  observation_id uuid,
  source_text_evidence_id uuid,
  logical_extraction_key text,
  mention_count integer
)
language sql
security definer
set search_path = ''
stable
as $$
  select i.id, i.item_index, i.outcome, i.user_id, i.observation_id,
         i.source_text_evidence_id, i.logical_extraction_key, i.mention_count
    from semantic_private.model_invocation_items i
   where i.invocation_id = p_invocation_id
   order by i.item_index;
$$;

comment on function semantic_private.model_invocation_lineage is
  'What a model call produced, by item. The model lane reads this to hand the '
  'deterministic worker something to reference; the worker is not granted it, '
  'because a worker that could look up invocation items could hang a mention '
  'off one it did not earn.';

revoke all on function semantic_private.model_invocation_lineage(uuid)
  from public, anon, authenticated, semantic_ingestor, semantic_worker;
grant execute on function semantic_private.model_invocation_lineage(uuid)
  to semantic_model_worker;

-- ---------------------------------------------------------------------------
-- 2. What must stay true.
-- ---------------------------------------------------------------------------
--
-- The isolation is asserted here as well as in `0240`, because this is the
-- migration that gives the two identities something to hand each other, and a
-- handoff is exactly when somebody is tempted to merge them.

do $$
declare
  n integer;
begin
  if not has_function_privilege('semantic_model_worker',
        'semantic_private.model_invocation_lineage(uuid)', 'EXECUTE') then
    raise exception '0243: the model lane cannot read back what it recorded';
  end if;

  if has_function_privilege('semantic_worker',
        'semantic_private.model_invocation_lineage(uuid)', 'EXECUTE') then
    raise exception
      '0243: semantic_worker can enumerate invocation items it did not create';
  end if;

  -- Still one capability, still not the other's.
  if has_function_privilege('semantic_worker',
        'semantic_private.record_model_invocation(integer, jsonb, text, text, text, text, text, text, uuid, text, text, integer, integer, integer, text, text, text)',
        'EXECUTE') then
    raise exception '0243: semantic_worker can record a model call';
  end if;

  if has_table_privilege('semantic_model_worker',
                         'semantic_private.observation_mentions', 'INSERT') then
    raise exception
      '0243: the model lane can write a mention directly, which would make the '
      'lineage guard optional rather than the only door';
  end if;

  -- **Neither may become the other.** A grant is not the only way one identity
  -- acquires another's powers; role membership is the quieter way, and both
  -- roles hold capabilities the other is refused.
  select count(*) into n
    from pg_auth_members m
    join pg_roles granted on granted.oid = m.roleid
    join pg_roles member on member.oid = m.member
   where (member.rolname = 'semantic_worker'
          and granted.rolname = 'semantic_model_worker')
      or (member.rolname = 'semantic_model_worker'
          and granted.rolname = 'semantic_worker');
  if n <> 0 then
    raise exception
      '0243: one of the two lane identities is a member of the other';
  end if;
end;
$$;
