-- 0237 — a mode boundary the worker cannot talk its way past.
--
-- Stage 2, third of four. `74adfca` split one switch into two predicates —
-- `model_may_be_called` for `evaluation` and above, `may_write_user_candidates`
-- for `shadow` and above — and its commit message says what may be written is
-- enforced where the writes happen, because a handler deciding its own
-- permissions would be a second copy of the rule.
--
-- **The write sites do not exist.** `may_write_user_candidates` has zero call
-- sites repo-wide outside its own definition and one test; `overlay.py`'s
-- `extract_mentions` branches on the raw mode string and defers the rest. So
-- "shadow is safe because the predicate gates the writes" describes a property
-- no code has, and the deferral was honest about it: line 118 says the
-- enforcement belongs at the writes, and the writes were never written.
--
-- This is where it goes.
--
-- ## The mention is the choke point, and that is a structural argument
--
-- Every model-derived row descends from a mention: a resolution names a mention,
-- a candidate is built from a resolution, evidence links back through it. So a
-- rule that no model mention may exist without a successful, in-lane invocation
-- item is a rule about everything downstream of one — not because each
-- descendant is checked, but because the ancestor cannot be written.
--
-- Enforcing it at each descendant instead would be four guards that must agree,
-- and this repository has a name for that.
--
-- ## Four refusals
--
-- 1. **A `model_proposed` mention with no invocation item.** The rule the
--    lineage table was built for.
-- 2. **An item that did not succeed.** `output_overflow` produced no mentions;
--    `0236` already refuses `mention_count > 0` on such a row, and this refuses
--    the mention itself, which is the same fact from the other end.
-- 3. **A user-attributed mention from an `evaluation` invocation.** The whole
--    definition of that lane: model calls with operational metadata and no user
--    semantics. It is not a policy the worker applies; it is a write that fails.
-- 4. **A mention whose source text has been deleted.** An in-flight call whose
--    source was erased underneath it must not commit — the ninth property
--    `supabase/tests/0230_calibration_lifecycle_contract.sql` names at its foot
--    and declines to fake, because asserting it against a pipeline that makes no
--    model calls would be a test of nothing that later reads as coverage. This
--    is the storage half; the in-flight half needs a gateway.
--
-- And the inverse, which is the one a deny-list would miss: **a mention that is
-- not `model_proposed` may not claim an invocation item.** Without it, a
-- projection mention could carry model lineage and the column would stop meaning
-- what it says.
--
-- ## Tenancy is a foreign key, not a check
--
-- `(model_invocation_item_id, user_id)` references `model_invocation_items
-- (id, user_id)`. A mention always names a user and a fixture item never does,
-- so **an evaluation run over synthetic items cannot produce a user's mention**
-- even before the trigger looks — the composite key has no row to point at.
-- That is `0203`'s pattern: the constraint proves the row belongs to the same
-- account as its parent rather than a query being careful.

-- ---------------------------------------------------------------------------
-- 1. A mention can name the item that produced it.
-- ---------------------------------------------------------------------------

alter table semantic_private.observation_mentions
  add column if not exists model_invocation_item_id uuid;

alter table semantic_private.observation_mentions
  drop constraint if exists observation_mentions_invocation_item_fk;
alter table semantic_private.observation_mentions
  add constraint observation_mentions_invocation_item_fk
  foreign key (model_invocation_item_id, user_id)
  references semantic_private.model_invocation_items (id, user_id)
  on delete no action;

comment on column semantic_private.observation_mentions.model_invocation_item_id is
  'The successful invocation item that produced this mention. Required for '
  'extraction_method = model_proposed and refused for anything else.';

-- ---------------------------------------------------------------------------
-- 2. The boundary.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.guard_model_mention_lineage()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  item record;
  lane text;
begin
  if new.extraction_method <> 'model_proposed' then
    -- The inverse refusal. A deterministic mention carrying model lineage would
    -- make the column mean whatever its writer wanted.
    if new.model_invocation_item_id is not null then
      raise exception
        'a % mention cannot claim a model invocation item', new.extraction_method;
    end if;
    return new;
  end if;

  if new.model_invocation_item_id is null then
    raise exception 'a model_proposed mention must name its invocation item';
  end if;

  select i.outcome, i.invocation_id, i.source_text_evidence_id, i.user_id
    into item
    from semantic_private.model_invocation_items i
   where i.id = new.model_invocation_item_id;
  if item is null then
    raise exception 'the invocation item named by this mention does not exist';
  end if;
  if item.outcome <> 'succeeded' then
    raise exception
      'a model mention cannot descend from a % item', item.outcome;
  end if;

  select v.model_lane_mode into lane
    from semantic_private.model_invocations v
   where v.id = item.invocation_id;
  -- Null is refused with the rest. A call that did not record its lane cannot
  -- afterwards answer whether it was permitted to write about a person, which
  -- is the sentence `0235` put on the manifest column.
  if lane is null or lane not in ('shadow', 'active') then
    raise exception
      'a % invocation may not create a user mention', coalesce(lane, 'lane-less');
  end if;

  if item.source_text_evidence_id is not null then
    if exists (
      select 1 from semantic_private.source_text_evidence e
       where e.id = item.source_text_evidence_id
         and e.refresh_status = 'deleted'
    ) then
      raise exception 'the source text behind this mention has been deleted';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_model_mention_lineage
  on semantic_private.observation_mentions;
create trigger guard_model_mention_lineage
  before insert or update on semantic_private.observation_mentions
  for each row execute function semantic_private.guard_model_mention_lineage();

-- ---------------------------------------------------------------------------
-- 3. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
begin
  -- **The barrier between model lineage and an assertion is structural**, and
  -- it is asserted rather than assumed because the memo lists it as a required
  -- refusal and nothing new here provides it. Two facts hold it up: a candidate
  -- is not an assertion and nothing converts one, and the worker cannot write
  -- ontology at all.
  if has_table_privilege('semantic_worker', 'ontology.concepts', 'INSERT')
     or has_table_privilege('semantic_worker', 'ontology.concept_revisions', 'INSERT')
     or has_table_privilege('semantic_worker', 'ontology.versions', 'INSERT') then
    raise exception
      '0237: semantic_worker can mint ontology, so model output could become vocabulary';
  end if;

  -- `user_assertions` has no column a provisional could occupy, so a
  -- model-derived candidate has nothing to become.
  select count(*) into n
    from information_schema.columns
   where table_schema = 'semantic_private' and table_name = 'user_assertions'
     and column_name = 'provisional_entity_id';
  if n <> 0 then
    raise exception
      '0237: user_assertions gained a provisional column; the barrier is now a rule to remember';
  end if;

  -- And the trigger is attached to the table it guards, read back rather than
  -- trusted to the statement above.
  select count(*) into n
    from pg_trigger t
    join pg_class r on r.oid = t.tgrelid
    join pg_namespace ns on ns.oid = r.relnamespace
   where ns.nspname = 'semantic_private'
     and r.relname = 'observation_mentions'
     and t.tgname = 'guard_model_mention_lineage'
     and not t.tgisinternal;
  if n <> 1 then
    raise exception '0237: the mention lineage guard is not attached';
  end if;
end;
$$;
