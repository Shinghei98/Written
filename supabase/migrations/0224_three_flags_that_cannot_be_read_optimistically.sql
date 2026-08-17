-- 0224 — three flags that cannot be read optimistically.
--
-- ## What this adds
--
-- `0223` froze the work rule and gated its evaluation at five accounts. The gate
-- raises, which is right for the *numbers* — a printed number gets quoted — but
-- it leaves a reader with no way to ask "where is this up to?" without
-- triggering the refusal, and a refusal is easy to read as "broken" rather than
-- "not yet".
--
-- So three booleans, reportable at any time, each answering a different question
-- that has been silently conflated before now:
--
--   * **`population_gate_open`** — are there enough accounts to evaluate at all.
--   * **`measurement_complete`** — did every named measurement actually produce
--     a value. Distinct from the gate: five accounts open the *measurement* and
--     do not complete it, because precision after review needs somebody to have
--     reviewed something, and there is no review surface yet. `measurement_blockers`
--     names whichever are outstanding, so the flag is never a bare false.
--   * **`publication_ready`** — **false unless separately attested**, and false
--     again the moment that attestation is withdrawn.
--
-- ## Why publication is an attestation and not a computation
--
-- Every other flag here is derived, and deriving this one too would be the
-- mistake. A computed `publication_ready` would mean the system decides to
-- publish vocabulary the moment some arithmetic crosses a line — which is
-- exactly the shape of the failure `0223` exists to prevent, one level up. The
-- numbers inform the decision; a person makes it, on a held-out population, and
-- says so in a row.
--
-- **It defaults false and it cannot default any other way**: `publication_ready`
-- is computed from the attestation ledger, and an empty ledger is false. There
-- is no column anybody can set to true by hand.
--
-- ## Withdrawal semantics, which is the part worth being careful about
--
-- An attestation that could be deleted would let the record of a decision
-- disappear along with the decision, and this project has a rule about that:
-- **retiring is not deleting.** So the ledger is **append-only**, withdrawal is
-- an *event* rather than an erasure, and `publication_ready` reads the latest
-- event:
--
--   * no events → **false**
--   * latest is `attest` → **true**
--   * latest is `withdraw` → **false**
--
-- **"Latest" is by sequence, not by `decided_at`.** The first version ordered on
-- the timestamp, and `now()` is the *transaction* time — so an attestation and
-- its withdrawal written in one transaction tie to the microsecond and the
-- tiebreak became a random uuid. The probe below caught it reporting `ready`
-- after a withdrawal, which is the exact state this flag exists to refuse.
--
-- Re-attesting after a withdrawal is a new `attest` row, so the sequence of
-- decisions survives in full. Nothing is ever removed, and "this was attested
-- and then withdrawn" stays distinguishable from "this was never attested" —
-- two states a single boolean column would have collapsed.

begin;

-- ---------------------------------------------------------------------------
-- 1. The attestation ledger.
-- ---------------------------------------------------------------------------

create table if not exists semantic_private.vocabulary_experiment_attestations (
  id             uuid primary key default extensions.gen_random_uuid(),
  -- **A monotonic sequence, because `decided_at` cannot order these.** `now()`
  -- is the *transaction* time in Postgres, so an attest and a withdrawal
  -- recorded in one transaction share a timestamp to the microsecond and the
  -- tiebreak falls to a random uuid — which made `publication_ready`
  -- nondeterministic, and was caught by the migration's own probe reporting
  -- `ready` after a withdrawal. Sequence order is insertion order whatever the
  -- clock says.
  seq            bigint generated always as identity,
  experiment_key text not null
                 references semantic_private.vocabulary_experiments(experiment_key)
                 on delete restrict,
  -- `attest` and `withdraw` are the whole vocabulary. A third value would be a
  -- state somebody has to interpret, and this is a question with two answers.
  action         text not null check (action in ('attest', 'withdraw')),
  -- Who decided and on what. Free text deliberately: this is a human judgement
  -- about a held-out population, and constraining its shape would not make it
  -- truer.
  decided_by     text not null check (length(btrim(decided_by)) > 0),
  rationale      text not null check (length(btrim(rationale)) > 0),
  decided_at     timestamptz not null default now()
);

comment on table semantic_private.vocabulary_experiment_attestations is
  'Append-only ledger of publication decisions. Withdrawal is an event, never a '
  'deletion, so "attested then withdrawn" stays distinguishable from "never '
  'attested". Holds no user data.';

create index if not exists vocabulary_experiment_attestations_latest_idx
  on semantic_private.vocabulary_experiment_attestations (experiment_key, seq desc);

-- **Append-only by trigger**, the same refusal `review_items` and
-- `ingestion_run_items` apply to evidence: an update would rewrite a decision
-- after it was made, and a delete would remove the fact that it ever was.
create or replace function semantic_private.guard_attestation_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception
    'vocabulary_experiment_attestations is append-only; withdraw by inserting a withdraw row';
end;
$$;

drop trigger if exists guard_attestation_append_only
  on semantic_private.vocabulary_experiment_attestations;
create trigger guard_attestation_append_only
  before update or delete on semantic_private.vocabulary_experiment_attestations
  for each row execute function semantic_private.guard_attestation_append_only();

alter table semantic_private.vocabulary_experiment_attestations enable row level security;
grant select, insert on semantic_private.vocabulary_experiment_attestations to semantic_worker;
revoke all on semantic_private.vocabulary_experiment_attestations
  from anon, authenticated, semantic_ingestor;

-- ---------------------------------------------------------------------------
-- 2. The three flags.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.vocabulary_experiment_status(key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  gate        integer;
  population  integer;
  latest      text;
  m3_ready    boolean;
  m5_ready    boolean;
  shadow      integer;
begin
  select population_gate into gate
    from semantic_private.vocabulary_experiments where experiment_key = key;
  if gate is null then
    raise exception 'no such experiment: %', key;
  end if;

  select count(distinct user_id) into population
    from semantic_private.observation_mentions where mention_role = 'work';

  -- **The latest event, not the presence of one.** `exists (… action = 'attest')`
  -- would answer true forever once anything had ever been attested, which is
  -- precisely the withdrawal case getting lost.
  select action into latest
    from semantic_private.vocabulary_experiment_attestations
   where experiment_key = key
   order by seq desc
   limit 1;

  -- **m3 is the one that cannot be faked.** Precision after review needs a
  -- human verdict, `assertion_reviews` is empty, and there is no `api` function
  -- that would fill it — so this stays false until the review surface exists.
  -- Counted rather than assumed, because "nobody has reviewed" and "review
  -- rejected everything" are different facts and only one is a result.
  select exists (select 1 from semantic_private.assertion_reviews) into m3_ready;

  select count(*) into shadow
    from semantic_private.vocabulary_experiment_candidates
   where experiment_key = key and state = 'eligible_shadow';

  -- **m5 is computable without minting, and the first draft of this was
  -- circular.** It asked whether any inferred assertion is eligible anywhere,
  -- which is true of 150 rows that have nothing to do with this experiment —
  -- and the honest version of the question (do *these* candidates assert?)
  -- could not be answered until they were minted, which is the decision the
  -- measurement is supposed to inform. The way out is that the ratio does not
  -- need real assertions: a shadow candidate's accumulated weight is knowable
  -- now, and whether it *would* clear the bar follows from the same curve the
  -- scorer uses. So the only precondition is having candidates to divide by,
  -- 0/0 being the one answer the ratio cannot give.
  m5_ready := shadow > 0;

  return jsonb_build_object(
    'experiment_key', key,
    'population', population,
    'population_gate', gate,
    'population_gate_open', population >= gate,
    -- **Both halves, deliberately.** A measurement is not complete because the
    -- gate opened; it is complete when every named measurement produced a
    -- value. Conflating them is how "we have five accounts" becomes "we have an
    -- answer".
    'measurement_complete', (population >= gate) and m3_ready and m5_ready,
    'measurement_blockers', (
      case when population < gate then jsonb_build_array('population') else '[]'::jsonb end
      || case when not m3_ready then jsonb_build_array('m3_precision_after_review') else '[]'::jsonb end
      || case when not m5_ready then jsonb_build_array('m5_growth_per_useful_assertion') else '[]'::jsonb end),
    -- **Never derived from the numbers.** An empty ledger is false, a withdrawal
    -- is false, and only a standing attestation is true.
    'publication_ready', coalesce(latest = 'attest', false),
    'publication_attestation', coalesce(latest, 'none'),
    'shadow_candidates', shadow
  );
end;
$$;

revoke all on function semantic_private.vocabulary_experiment_status(text)
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.vocabulary_experiment_status(text) to semantic_worker;

-- ---------------------------------------------------------------------------
-- 3. The evaluation carries them too.
-- ---------------------------------------------------------------------------
--
-- The gate still **raises** below five accounts — that has not changed and is
-- what stops a number being quoted early. What changes is that a report which
-- *does* come back now says, on its face, what it is and is not: a reader who
-- sees measurements can no longer fail to see that publication is unattested.

create or replace function semantic_private.evaluate_work_independence()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  gate       integer;
  population integer;
  result     jsonb;
begin
  select population_gate into gate
    from semantic_private.vocabulary_experiments
   where experiment_key = 'work_independence_v1';
  if gate is null then
    raise exception 'work_independence_v1 is not registered';
  end if;

  select count(distinct user_id) into population
    from semantic_private.observation_mentions where mention_role = 'work';

  if population < gate then
    raise exception
      'work_independence_v1 may not be evaluated: % account(s) emit work mentions, gate is %',
      population, gate;
  end if;

  select jsonb_build_object(
    'm1_qualifying_works_per_user', (
      select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'works', n)), '[]'::jsonb)
        from (select user_id, count(*) as n
                from semantic_private.vocabulary_experiment_candidates
               where experiment_key = 'work_independence_v1' and state = 'eligible_shadow'
               group by user_id) per_user),
    'm2_recurrence_across_users', (
      select coalesce(jsonb_agg(jsonb_build_object('accounts', accounts, 'works', works)), '[]'::jsonb)
        from (select accounts, count(*) as works
                from (select normalized_text, count(distinct user_id) as accounts
                        from semantic_private.vocabulary_experiment_candidates
                       where experiment_key = 'work_independence_v1'
                         and state = 'eligible_shadow'
                       group by normalized_text) r
               group by accounts) hist),
    'm3_precision_after_review', null,
    'm4_evidence_independence', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'performers', evidence -> 'performers',
               'distinct_actions', evidence -> 'distinct_actions',
               'observations', evidence -> 'observations')), '[]'::jsonb)
        from semantic_private.vocabulary_experiment_candidates
       where experiment_key = 'work_independence_v1' and state = 'eligible_shadow'),
    -- **The ratio the `0198`/`0199` import would have failed early**: 779
    -- concepts for 6 mappings and no assertions. `would_clear_bar` is derived
    -- from the same saturation the scorer applies, against the 0.25 `work`
    -- relief, so it needs no concept to exist first.
    'm5_growth_per_useful_assertion', (
      select jsonb_build_object(
               'would_mint', count(*),
               'would_clear_bar', count(*) filter (where w / (w + 6) >= 0.25))
        from (
          select c.user_id, c.normalized_text,
                 sum(1.0 * s.default_reliability
                     * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0)) as w
            from semantic_private.vocabulary_experiment_candidates c
            join semantic_private.observation_mentions m
              on m.user_id = c.user_id
             and m.normalized_text = c.normalized_text
             and m.mention_role = 'work'
            join semantic_private.observations o on o.id = m.observation_id
            join semantic_private.sources s on s.source_code = o.source_code
           where c.experiment_key = 'work_independence_v1'
             and c.state = 'eligible_shadow'
             and o.lifecycle_state = 'active'
             and o.action_weight > 0
           group by c.user_id, c.normalized_text) per_candidate)
  ) into result;

  -- The flags travel with the numbers rather than beside them, so a caller
  -- cannot take one without the other.
  return result || semantic_private.vocabulary_experiment_status('work_independence_v1');
end;
$$;

revoke all on function semantic_private.evaluate_work_independence()
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.evaluate_work_independence() to semantic_worker;

-- ---------------------------------------------------------------------------
-- 4. Prove all three, in both directions.
-- ---------------------------------------------------------------------------

do $$
declare
  status jsonb;
begin
  status := semantic_private.vocabulary_experiment_status('work_independence_v1');

  if (status ->> 'publication_ready')::boolean then
    raise exception '0224: publication_ready is true with an empty attestation ledger';
  end if;
  if (status ->> 'publication_attestation') <> 'none' then
    raise exception '0224: an unattested experiment does not report none';
  end if;
  if (status ->> 'measurement_complete')::boolean then
    raise exception '0224: measurement_complete is true while blockers stand';
  end if;

  -- **The probe, rolled back.** `0204`'s pattern: build the state, assert
  -- against it, then raise deliberately so the subtransaction undoes it. A flag
  -- that has only ever been observed false is not one to believe, and the
  -- alternative — leaving test attestations in a decision ledger — would be
  -- worse than not testing it.
  begin
    insert into semantic_private.vocabulary_experiment_attestations
      (experiment_key, action, decided_by, rationale)
    values ('work_independence_v1', 'attest', '0224-probe', 'probe: attest');
    status := semantic_private.vocabulary_experiment_status('work_independence_v1');
    if not (status ->> 'publication_ready')::boolean then
      raise exception '0224: an attested experiment did not report ready';
    end if;

    insert into semantic_private.vocabulary_experiment_attestations
      (experiment_key, action, decided_by, rationale)
    values ('work_independence_v1', 'withdraw', '0224-probe', 'probe: withdraw');
    status := semantic_private.vocabulary_experiment_status('work_independence_v1');
    if (status ->> 'publication_ready')::boolean then
      raise exception '0224: a withdrawn attestation still reports ready';
    end if;

    -- ...and the ledger refuses to be rewritten rather than appended to.
    begin
      update semantic_private.vocabulary_experiment_attestations
         set action = 'attest' where decided_by = '0224-probe';
      raise exception '0224: the attestation ledger accepted an update';
    exception when others then
      if sqlerrm like '%accepted an update%' then raise; end if;
    end;

    raise exception 'rollback_probe';
  exception when others then
    if sqlerrm <> 'rollback_probe' then raise; end if;
  end;

  -- The probe is gone; the standing state is the one that matters.
  if exists (select 1 from semantic_private.vocabulary_experiment_attestations
              where decided_by = '0224-probe') then
    raise exception '0224: the probe left rows in the attestation ledger';
  end if;
  status := semantic_private.vocabulary_experiment_status('work_independence_v1');
  if (status ->> 'publication_ready')::boolean then
    raise exception '0224: publication_ready survived the probe';
  end if;

  raise notice '0224: gate_open=%, measurement_complete=%, publication_ready=%, blockers=%',
    status ->> 'population_gate_open', status ->> 'measurement_complete',
    status ->> 'publication_ready', status ->> 'measurement_blockers';
end;
$$;

commit;
