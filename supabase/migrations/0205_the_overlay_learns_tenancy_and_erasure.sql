-- 0205 — the overlay learns tenancy and erasure.
--
-- Four gaps in `0203`, one guard it should have carried, one thing
-- `forget_distillation` does not know about, and one repair to a resolver row
-- that describes less than the code it names.
--
-- **Everything here is still inert.** No job writes these tables, the Qwen
-- overlay is off, and the only statement that touches live data is the resolver
-- parameter at the foot — which changes no behaviour, because a run's identity
-- is the model's *id* and not its parameters.
--
-- ## The tenancy pattern had a hole in it, in the one place I wrote it out
--
-- `0203` argued that a child's foreign key should carry `user_id` so the
-- constraint proves a row belongs to the same account as its parent. Thirteen
-- tables do. `review_item_evidence.support_link_id` references
-- `candidate_support_links(id)` alone, so nothing at the database level stops
-- one person's review item citing another person's evidence. It could not have
-- been written the other way at the time — `candidate_support_links` had no
-- `unique (id, user_id)` to reference — which is exactly how the exception to a
-- rule gets made: the rule is stated, one row will not take it, and the row
-- wins quietly.
--
-- ## Two tables could be written twice by the same job
--
-- A job queue that retries — and `worker_jobs` allows five attempts — will run
-- `build_review_items` twice for the same epoch sooner or later.
-- `user_term_candidates` is protected by its partial unique indexes and
-- `candidate_support_links` by `(candidate_id, observation_id, route_id)`;
-- `review_items` and `mention_resolutions` had nothing, so a retry produced a
-- second card for the same candidate in the same epoch and a second resolution
-- for the same mention. Both are idempotency keys rather than business rules,
-- and both are the kind of thing that reads as a mysterious duplicate months
-- later.
--
-- ## `traversable` was enforced and `verified_relation` was not
--
-- `0203` refuses `traversable = true` unless `authority_state` is
-- `verified_relation`, and then let anything set `verified_relation`.
-- `semantic_worker` holds `insert` on the table, so a model proposal could
-- arrive already wearing the state that makes it walkable. The check constraint
-- was doing the second half of a job whose first half nobody had written.
--
-- The flag pattern is the house's — `written.finalize_ingestion_v031` and
-- `written.close_unpromotable_v031` are the same shape — and it is the right one
-- here for the same reason: the privilege cannot be given to a role, because the
-- role that must write proposals is the role that must not verify them.

begin;

-- ---------------------------------------------------------------------------
-- 1. The tenancy hole.
-- ---------------------------------------------------------------------------

alter table semantic_private.candidate_support_links
  add constraint candidate_support_links_id_user_id_key unique (id, user_id);

alter table semantic_private.review_item_evidence
  drop constraint review_item_evidence_support_link_id_fkey;

alter table semantic_private.review_item_evidence
  add constraint review_item_evidence_support_link_id_user_id_fkey
  foreign key (support_link_id, user_id)
  references semantic_private.candidate_support_links (id, user_id)
  on delete cascade;

-- **A shared proposal may not rest on one person's private noun.**
-- `provisional_entities` is dual-scope, so the composite-foreign-key trick does
-- not reach this: a foreign key whose referencing columns include a null is
-- satisfied without checking anything, and a shared proposal's `user_id` is
-- precisely null. A trigger is the only mechanism left.
create or replace function semantic_private.guard_relation_proposal_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  offending text;
begin
  select case
           when subject.scope = 'user' and subject.user_id is distinct from new.user_id
             then 'subject'
           when object.scope = 'user' and object.user_id is distinct from new.user_id
             then 'object'
         end
    into offending
    from (select 1) as anchor
    left join semantic_private.provisional_entities subject
      on subject.id = new.subject_provisional_id
    left join semantic_private.provisional_entities object
      on object.id = new.object_provisional_id;

  if offending is not null then
    raise exception
      'a relation proposal may not name a provisional entity belonging to '
      'another account (%)', offending;
  end if;
  return new;
end;
$$;

create trigger candidate_relation_proposals_scope
  before insert or update on semantic_private.candidate_relation_proposals
  for each row execute function semantic_private.guard_relation_proposal_scope();

-- ---------------------------------------------------------------------------
-- 2. Idempotency.
-- ---------------------------------------------------------------------------

-- One card per candidate per epoch. `review_epoch` belongs here and not in
-- `user_term_candidates`' key for the reason `0203` gives: the epoch is
-- exposure history, and a candidate is not a new candidate because it was shown
-- again.
alter table semantic_private.review_items
  add constraint review_items_one_card_per_epoch
  unique (user_id, candidate_id, review_epoch);

-- One resolution per mention per resolver and route. A second resolver version
-- or a second route is a genuinely different answer and is allowed to coexist;
-- the same one twice is a retry.
alter table semantic_private.mention_resolutions
  add constraint mention_resolutions_one_per_route
  unique (mention_id, resolver_version, route_id);

-- ---------------------------------------------------------------------------
-- 3. Who may say a relation is verified.
-- ---------------------------------------------------------------------------

alter table semantic_private.candidate_relation_proposals
  add column verified_at timestamptz,
  add column verification_basis text;

-- **Not a grant, because the role that must write proposals is the role that
-- must not verify them.** `semantic_worker` needs `insert` here to record what
-- the model proposed; verification is a different act with a different
-- authority, and there is no third role to give it to. A transaction-local flag
-- that only a `security definer` function raises is how this schema already
-- separates the atomic finalizer from ordinary writers.
create or replace function semantic_private.guard_relation_verification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- **The transition is what is guarded, not the state.** The first version
  -- tested `new.authority_state` alone, which refused every later update to an
  -- already-verified row — including setting `traversable`, which is the whole
  -- point of verifying one. The probe below caught it, which is the argument
  -- for the probe: a guard that refuses too much looks identical to a guard
  -- that works until somebody tries the thing it was written to permit.
  if new.authority_state = 'verified_relation'
     and (tg_op = 'INSERT' or old.authority_state is distinct from 'verified_relation')
     and coalesce(current_setting('written.verify_relation_v1', true), '0') <> '1' then
    raise exception
      'verified_relation may be set only by semantic_private.verify_relation_proposal';
  end if;
  if new.authority_state = 'verified_relation'
     and (new.verified_at is null or new.verification_basis is null) then
    raise exception 'a verified relation must record when and on what basis';
  end if;
  return new;
end;
$$;

create trigger candidate_relation_proposals_verification
  before insert or update on semantic_private.candidate_relation_proposals
  for each row execute function semantic_private.guard_relation_verification();

create or replace function semantic_private.verify_relation_proposal(
  target_proposal_id uuid,
  basis text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(btrim(basis), '') = '' then
    raise exception 'a verification must state its basis';
  end if;
  perform set_config('written.verify_relation_v1', '1', true);
  update semantic_private.candidate_relation_proposals
     set authority_state    = 'verified_relation',
         verified_at        = now(),
         verification_basis = basis
   where id = target_proposal_id;
  perform set_config('written.verify_relation_v1', '0', true);
end;
$$;

revoke all on function semantic_private.verify_relation_proposal(uuid, text)
  from public, anon, authenticated, semantic_worker, semantic_ingestor;

-- ---------------------------------------------------------------------------
-- 4. Disconnect all did not know the overlay exists.
-- ---------------------------------------------------------------------------

-- **The rule this repairs is already written down**: a deletion control names
-- both schemas or it is not finished. It was learned when *Disconnect all*
-- emptied four tables in `public` and named none of the ones Memories read, so
-- every term stayed on the page after the sources behind it were gone.
--
-- The overlay is the next Memories. Nothing writes it today, which is why this
-- is cheap now and would be a repeat of that defect later.
--
-- What is withdrawn and what survives follows `user_assertions` exactly:
-- inferred candidates are withdrawn, and a person's own strike is not. A
-- suppression is what somebody said about themselves — the same fact as an
-- `explicit_addition` — and disconnecting a source is not them changing their
-- mind about a term.
--
-- Review history is untouched on purpose. It is append-only by trigger and it is
-- the record of what was actually on screen when an answer was given; erasing it
-- would make every answer already collected uninterpretable, and it holds no
-- provider text.
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
begin
  -- **No parameter for whose.** Every function in this schema is scoped to
  -- `auth.uid()`, so a caller cannot act on anybody but themselves.
  if me is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;

  -- **Set before the first write and never reset.** `set_config(..., true)` is
  -- transaction-local, so it lifts when this call's transaction ends whether it
  -- commits or rolls back — there is no path that leaves the suppression on for
  -- the next caller, and no need for an exception handler that could swallow a
  -- real failure while restoring it.
  perform set_config('written.forget_distillation_v031', '1', true);

  -- 1. The claims. Inferred only: an `explicit_addition` is what the person
  --    typed in Memories, which is the same fact as a `source = 'user'` row in
  --    the legacy path.
  update semantic_private.user_assertions
     set machine_state = 'inactive', updated_at = now()
   where user_id = me
     and assertion_origin = 'inferred'
     and machine_state <> 'inactive';
  get diagnostics retired = row_count;

  -- 2. **The evidence, out of scoring.** `resolve.py` filters
  --    `lifecycle_state = 'active'` and mappings are made per run rather than
  --    reused, so nothing here is ever mapped again — which is what makes the
  --    retirement above durable rather than undone by the next model bump.
  update semantic_private.observations
     set lifecycle_state = 'deleted',
         exclusion_code  = 'user_deleted',
         excluded_at     = now()
   where user_id = me
     and lifecycle_state <> 'deleted';
  get diagnostics excluded_rows = row_count;

  -- 3. The captured payloads, every source.
  --    `raw_source_records_payload_location_check` refuses `lifecycle_state =
  --    'deleted'` unless both columns are null, so the state and the redaction
  --    cannot disagree.
  update semantic_private.raw_source_records
     set lifecycle_state   = 'deleted',
         deleted_at        = now(),
         encrypted_payload = null,
         raw_blob_ref      = null
   where user_id = me
     and lifecycle_state <> 'deleted';
  get diagnostics redacted = row_count;

  -- 3b. **The candidate overlay, added by `0205`.** The same shape as step 1,
  --     one layer earlier in the pipeline: a candidate is an inferred claim
  --     that has not been asserted yet, so leaving it active would let the next
  --     review round put a term back on the page from evidence the person has
  --     just disconnected.
  update semantic_private.user_term_candidates
     set lifecycle_state = 'withdrawn', updated_at = now()
   where user_id = me
     and lifecycle_state <> 'withdrawn';
  get diagnostics withdrawn = row_count;

  -- 3c. A user-scoped provisional entity is a noun read off this person's
  --     library and held under no stable identity — the closest thing in the
  --     overlay to raw text. Quarantined rather than deleted, because
  --     `mention_resolutions` references it and the vault does not delete rows.
  --     Shared provisionals are untouched: they carry an external identifier
  --     and belong to nobody.
  update semantic_private.provisional_entities
     set identity_state = 'quarantined', updated_at = now()
   where user_id = me
     and scope = 'user'
     and identity_state <> 'quarantined';
  get diagnostics quarantined = row_count;

  -- 4. The vault's own connection rows, for every source.
  delete from semantic_private.source_connections
   where user_id = me;

  -- 5. **The revision, once.** This is the bump the trigger was suppressed
  --    from making 2,709 times. It is not bookkeeping: the scorer's inputs have
  --    all just changed, and `api.list_assertions` withholds an inferred
  --    assertion whose score was computed at an older revision — so a claim
  --    that somehow survives step 1 is still not shown.
  --
  --    Only where the erasure touched something. A second Disconnect all on an
  --    already-empty account should be a no-op, not a revision bump that
  --    invalidates whatever the person has done since.
  if excluded_rows > 0 or redacted > 0 or retired > 0
     or withdrawn > 0 or quarantined > 0 then
    insert into semantic_private.user_state_versions (user_id, revision)
    values (me, 1)
    on conflict (user_id) do update
    set revision = semantic_private.user_state_versions.revision + 1,
        updated_at = now();
  end if;

  -- **A receipt, because the caller must not have to guess.** An erasure
  -- answering `void` would make "the terms are still there" and "the call never
  -- ran" the same observation from the client's side.
  return jsonb_build_object(
    'assertions_retired', retired,
    'observations_excluded', excluded_rows,
    'records_redacted', redacted,
    'candidates_withdrawn', withdrawn,
    'provisionals_quarantined', quarantined
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. A resolver row that describes less than the code it names.
-- ---------------------------------------------------------------------------

-- **`0174` never ran here.** It and `0181` both mint `ontology_first_resolver`
-- 0.10.0 from 0.9.0, and they collide — which only surfaced when the chain was
-- first replayed from empty, because in this database `0174` is marked applied
-- in the ledger and did not execute. The live 0.10.0 row carries `0181`'s
-- `catalogue_game_credits` and not `0174`'s `spotify_top_items`.
--
-- The substance of `0174` shipped anyway: its fix was in the Python package's
-- `SOURCE_ACTION_PAIRS`, and it works — 12,787 of 12,803 `top_track`
-- observations are mapped, and 760 of 779 `top_artist`. What was lost is the
-- parameter recording it, and *"parameters live on the model row where a later
-- reader looks, not in a commit message"* is the rule that makes that worth
-- repairing rather than shrugging at.
--
-- **This is not a behaviour change and must not read as one.** A run's identity
-- is `(user, revision, ontology version, resolver id, scorer id)` — by id, not
-- by parameters — so adding a key enqueues nothing and re-scores nobody. It
-- describes behaviour that has been live since the package shipped.
do $$
declare
  patched integer;
  note constant text :=
    'top_track and top_artist are mapped. They carried an action weight from '
    || '0139 and were refused by SOURCE_ACTION_PAIRS, which had never been told '
    || 'of them. Recorded by 0205 rather than 0174: that migration is marked '
    || 'applied in this database and never executed, because it mints the same '
    || 'resolver version 0181 does. The package half shipped independently.';
begin
  update ontology.model_versions
     set parameters = parameters || jsonb_build_object('spotify_top_items', note)
   where model_key = 'ontology_first_resolver'
     and version = '0.10.0'
     and not parameters ? 'spotify_top_items';
  get diagnostics patched = row_count;

  -- Nothing to do on a replay from empty, where `0174` ran and put the key
  -- there itself. Both endings are correct and the notice says which happened.
  if patched = 0 then
    raise notice '0205: resolver 0.10.0 already records spotify_top_items';
  else
    raise notice '0205: recorded spotify_top_items on resolver 0.10.0';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Assertions.
-- ---------------------------------------------------------------------------

do $$
declare
  probe_user uuid := extensions.gen_random_uuid();
  other_user uuid := extensions.gen_random_uuid();
  mine uuid;
  theirs uuid;
  proposal uuid;
  refusals integer := 0;
begin
  -- 1. Every composite key the overlay now claims to have.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'semantic_private.review_item_evidence'::regclass
       and contype = 'f'
       and pg_get_constraintdef(oid) like '%(support_link_id, user_id)%'
  ) then
    raise exception '0205: review_item_evidence still cites evidence without tenancy';
  end if;

  if exists (
    select 1 from pg_constraint
     where conrelid = 'semantic_private.candidate_relation_proposals'::regclass
       and contype = 'c' and conname like '%traversal%'
       and pg_get_constraintdef(oid) not like '%verified_relation%'
  ) then
    raise exception '0205: the traversal constraint no longer names verified_relation';
  end if;

  -- 2. The verification guard, answering both ways over real rows.
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (probe_user, '00000000-0000-0000-0000-000000000000', 'authenticated',
            'authenticated', 'p1-' || probe_user || '@invalid.example', now(), now()),
           (other_user, '00000000-0000-0000-0000-000000000000', 'authenticated',
            'authenticated', 'p2-' || other_user || '@invalid.example', now(), now());

    insert into semantic_private.provisional_entities
      (scope, user_id, canonical_label, normalized_label, family)
    values ('user', probe_user, 'Probe One', 'probe one', 'person')
    returning id into mine;

    insert into semantic_private.provisional_entities
      (scope, user_id, canonical_label, normalized_label, family)
    values ('user', other_user, 'Probe Two', 'probe two', 'person')
    returning id into theirs;

    -- A proposal may rest on its own account's provisional.
    insert into semantic_private.candidate_relation_proposals
      (user_id, subject_provisional_id, predicate, object_label_hypothesis)
    values (probe_user, mine, 'about', 'something')
    returning id into proposal;

    -- **And not on somebody else's.**
    begin
      insert into semantic_private.candidate_relation_proposals
        (user_id, subject_provisional_id, predicate, object_label_hypothesis)
      values (probe_user, theirs, 'about', 'something');
      raise exception '0205: a proposal named another account''s provisional';
    exception when others then
      if sqlerrm not like '%another account%' then raise; end if;
      refusals := refusals + 1;
    end;

    -- **Nobody may write the verified state directly**, including the role that
    -- writes every other column of this table.
    begin
      update semantic_private.candidate_relation_proposals
         set authority_state = 'verified_relation'
       where id = proposal;
      raise exception '0205: verified_relation was set without the verifier';
    exception when others then
      if sqlerrm not like '%verify_relation_proposal%' then raise; end if;
      refusals := refusals + 1;
    end;

    -- The verifier may, and records why.
    perform semantic_private.verify_relation_proposal(proposal, 'probe: an operator said so');
    if not exists (
      select 1 from semantic_private.candidate_relation_proposals
       where id = proposal and authority_state = 'verified_relation'
         and verified_at is not null and verification_basis is not null
    ) then
      raise exception '0205: the verifier did not verify';
    end if;

    -- Traversal is still refused until somebody asks for it explicitly, and
    -- now that the state is legitimately verified it may be granted.
    update semantic_private.candidate_relation_proposals
       set traversable = true where id = proposal;

    if refusals <> 2 then
      raise exception '0205: expected two refusals, counted %', refusals;
    end if;

    raise exception using errcode = 'YY001', message = 'probe complete';
  exception
    when sqlstate 'YY001' then
      null;
  end;

  -- 3. The erasure names the overlay.
  if position('user_term_candidates' in
              (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'api' and p.proname = 'forget_distillation')) = 0 then
    raise exception '0205: forget_distillation still does not name the overlay';
  end if;

  raise notice '0205: tenancy, idempotency and verification in place; % refusals proven', refusals;
end;
$$;

commit;
