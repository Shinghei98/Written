-- 0223 — the work rule is frozen before the data.
--
-- ## What this is
--
-- A **pre-registration**. The rule that decides whether a musical work becomes
-- vocabulary is written down here, in full, while exactly **one** account emits
-- work mentions — and it may not be changed once more accounts arrive.
--
-- The reason is the failure this project keeps paying for in a different form.
-- `0220` predicted four genre crossings from an artist count and got three;
-- `0220` also predicted `genre:apple_19` would not cross and it did, at 0.391,
-- onto a real profile. Both were rules tuned against the data they were read
-- from. A vocabulary rule fitted to one library would be the same mistake with
-- a longer feedback loop: it would look right on that library by construction,
-- and there would be no way afterwards to tell a real threshold from a
-- remembered one.
--
-- So the order is inverted. **The rule first, the population second, the
-- decision last.**
--
-- ## The rule, frozen
--
-- > A work qualifies when, within one account, **three or more distinct primary
-- > performers** each contribute at least one policy-eligible live observation
-- > mentioning it.
--
-- Two things about that number, and the distinction matters:
--
--   * **Three is the rule.** It is a literal, frozen, and it does not move when
--     `ELIGIBLE_STRENGTH` or `HALF_WEIGHT` move. A rule that tracked the scorer's
--     constants would silently redefine the experiment every time somebody tuned
--     one, which is the opposite of a pre-registration.
--   * **Three is *derived from* the scorer**, and that derivation is provenance
--     rather than the rule. A work is scored against the 0.25 relief; mappings
--     average about 0.6 apiece on real libraries; `w/(w+6) >= 0.25` needs
--     `w >= 2.0`, so about 3.3 performers. Three is the nearest whole number
--     below that, chosen deliberately so the shadow set is a superset of what
--     would actually assert — an experiment that under-collects cannot be
--     rescued later, and one that over-collects can be filtered.
--
-- **The performer is the independence unit**, exactly as the artist is for the
-- genre rollup: forty tracks of one work by one ensemble are one opinion about
-- that work; three ensembles agreeing are three. This is the property the
-- 2026-08-17 measurement found missing — 16 works reach two performers, **2
-- reach three**, and **0 of 35 classical works reach two**, which was the
-- hypothesis most worth having and is false on this library.
--
-- ## What is recorded, and what is deliberately not
--
-- The two qualifying works are recorded as **`eligible_shadow`**. They are not
-- concepts, they get no `ontology.concepts` row, they are copied into no
-- ontology version, and nothing reads them into an assertion. That is the whole
-- point: `0221` removed 560 recordings that had been minted because minting was
-- the only way to have a durable handle on something, and this is what having a
-- handle looks like without minting.
--
-- ## The gate
--
-- `evaluate_work_independence` **refuses to report below five accounts** with
-- work mentions. Not "returns a caveat" — refuses, because a number that is
-- printed gets quoted, and the entire failure mode being guarded against is a
-- threshold read off too little data. Five is `EmergentTermMiner`'s floor and
-- is reused rather than reinvented.
--
-- ## The five measurements
--
-- Named here so the analysis cannot be chosen after the fact:
--
--   1. **qualifying works per user** — is the rule productive at all;
--   2. **recurrence across users** — does the same work qualify for several
--      people, which is where a work would get independence a single library
--      cannot give it;
--   3. **candidate precision after review** — of those shown, how many a human
--      kept. Reported as `null` until review data exists, never as zero;
--   4. **independence of the qualifying evidence** — whether the performers are
--      genuinely distinct and the actions genuinely separate, or whether one
--      import produced all of them;
--   5. **ontology growth per useful assertion** — concepts added divided by
--      assertions that clear the bar. `0198`/`0199` added 779 concepts for 6
--      mappings and 0 assertions, and this is the ratio that says so early.
--
-- **Publication is a separate decision after that**, on a held-out population,
-- and no part of this migration performs it.

begin;

-- ---------------------------------------------------------------------------
-- 1. The pre-registration.
-- ---------------------------------------------------------------------------

create table if not exists semantic_private.vocabulary_experiments (
  experiment_key   text primary key,
  frozen_at        timestamptz not null default now(),
  hypothesis       text not null,
  -- **The rule, as data.** A rule in a commit message is a rule nobody can
  -- check; a rule in a column is one a later reader can compare against what
  -- ran. Same reasoning as `model_versions.parameters`.
  rule             jsonb not null,
  rule_digest      text not null,
  population_gate  integer not null check (population_gate > 0),
  measurements     jsonb not null,
  status           text not null default 'frozen'
                   check (status in ('frozen', 'evaluated', 'published', 'abandoned')),
  notes            text
);

comment on table semantic_private.vocabulary_experiments is
  'Pre-registered vocabulary rules. The rule and its digest are immutable once '
  'written; only status and notes may move. Holds no user data.';

-- **The freeze, enforced.** Status and notes are the lifecycle and may move;
-- everything that defines the experiment may not. Without this the table is a
-- promise, and the promise would be tested exactly when it was inconvenient —
-- after the data arrived and the rule looked slightly wrong.
create or replace function semantic_private.guard_vocabulary_experiment_freeze()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'a pre-registered experiment may not be deleted (%)', old.experiment_key;
  end if;
  if new.rule is distinct from old.rule
     or new.rule_digest is distinct from old.rule_digest
     or new.hypothesis is distinct from old.hypothesis
     or new.population_gate is distinct from old.population_gate
     or new.measurements is distinct from old.measurements
     or new.frozen_at is distinct from old.frozen_at then
    raise exception
      'experiment % is frozen: rule, hypothesis, gate, measurements and frozen_at may not change',
      old.experiment_key;
  end if;
  return new;
end;
$$;

drop trigger if exists guard_vocabulary_experiment_freeze
  on semantic_private.vocabulary_experiments;
create trigger guard_vocabulary_experiment_freeze
  before update or delete on semantic_private.vocabulary_experiments
  for each row execute function semantic_private.guard_vocabulary_experiment_freeze();

-- ---------------------------------------------------------------------------
-- 2. Where a shadow candidate lives, which is not the ontology.
-- ---------------------------------------------------------------------------

create table if not exists semantic_private.vocabulary_experiment_candidates (
  id              uuid primary key default extensions.gen_random_uuid(),
  experiment_key  text not null
                  references semantic_private.vocabulary_experiments(experiment_key)
                  on delete restrict,
  -- **Cascades from the account.** A shadow candidate is derived from one
  -- person's library and has no reason to outlive it; `on delete cascade` also
  -- keeps this table out of the way of account deletion, which six `before
  -- delete` guards once made impossible for every account in this database.
  user_id         uuid not null references auth.users(id) on delete cascade,
  normalized_text text not null,
  state           text not null
                  check (state in ('eligible_shadow', 'rejected_shadow')),
  -- Counts and weights only: how many performers, how many observations, what
  -- the accumulated weight was. No titles beyond `normalized_text` itself, and
  -- no payload.
  evidence        jsonb not null default '{}'::jsonb,
  recorded_at     timestamptz not null default now(),
  unique (experiment_key, user_id, normalized_text)
);

comment on table semantic_private.vocabulary_experiment_candidates is
  'What a frozen rule selected, recorded without minting. eligible_shadow is '
  'explicitly not vocabulary: no ontology.concepts row, no revision, no version.';

create index if not exists vocabulary_experiment_candidates_lookup_idx
  on semantic_private.vocabulary_experiment_candidates (experiment_key, state);

alter table semantic_private.vocabulary_experiments enable row level security;
alter table semantic_private.vocabulary_experiment_candidates enable row level security;

-- **`on all tables` binds at execution time**, so a table added by a later
-- migration gets no grant unless that migration grants it. Both are granted
-- here, narrowly, and to the worker alone.
grant select, insert, update on semantic_private.vocabulary_experiments to semantic_worker;
grant select, insert on semantic_private.vocabulary_experiment_candidates to semantic_worker;
revoke all on semantic_private.vocabulary_experiments from anon, authenticated, semantic_ingestor;
revoke all on semantic_private.vocabulary_experiment_candidates from anon, authenticated, semantic_ingestor;

-- ---------------------------------------------------------------------------
-- 3. Freeze it.
-- ---------------------------------------------------------------------------

insert into semantic_private.vocabulary_experiments
  (experiment_key, hypothesis, rule, rule_digest, population_gate, measurements, notes)
values (
  'work_independence_v1',
  'A musical work is worth minting as vocabulary only where the evidence for it '
  || 'comes from independent performers. Measured on the single library that '
  || 'emits work mentions today, it does not: 16 of 575 works reach two '
  || 'performers, 2 reach three, and 0 of 35 classical works reach two — the '
  || 'hypothesis most worth having and false here. This freezes the rule before '
  || 'more accounts exist so the threshold cannot be fitted to them.',
  jsonb_build_object(
    'unit', 'performer',
    'field', 'normalized_payload->>primary_performer',
    'mention_role', 'work',
    'minimum_distinct_performers', 3,
    'observation_filter', 'lifecycle_state = active and action_weight > 0',
    'scope', 'within one account',
    'derivation',
      'Provenance, not the rule: a work is scored against ELIGIBLE_STRENGTH_BY_KIND '
      || 'work = 0.25; mappings average about 0.6 each on real libraries; '
      || 'w/(w+6) >= 0.25 needs w >= 2.0, so about 3.3 performers. Three is the '
      || 'nearest whole number below, chosen so the shadow set over-collects '
      || 'rather than under-collects. The literal 3 is frozen and does not track '
      || 'those constants if they move.'
  ),
  -- A digest over the rule, so "the rule did not change" is checkable by
  -- something other than trust. The trigger above is what enforces it; this is
  -- what lets a reader verify it independently.
  encode(extensions.digest(
    jsonb_build_object(
      'unit', 'performer', 'minimum_distinct_performers', 3,
      'mention_role', 'work', 'scope', 'within one account')::text, 'sha256'), 'hex'),
  5,
  jsonb_build_object(
    'm1_qualifying_works_per_user', 'count of eligible_shadow per account',
    'm2_recurrence_across_users', 'distinct accounts per qualifying normalized_text',
    'm3_precision_after_review', 'kept / shown; null until review data exists',
    'm4_evidence_independence', 'distinct performers and distinct actions behind each qualifier',
    'm5_growth_per_useful_assertion', 'concepts that would be minted / assertions clearing the bar'
  ),
  'Frozen 2026-08-17 with one account emitting work mentions. Do not evaluate '
  || 'below the population gate and do not amend after further accounts arrive; '
  || 'a superseding experiment gets a new key.'
)
on conflict (experiment_key) do nothing;

-- ---------------------------------------------------------------------------
-- 4. Record what the frozen rule selects today, as shadow.
-- ---------------------------------------------------------------------------

insert into semantic_private.vocabulary_experiment_candidates
  (experiment_key, user_id, normalized_text, state, evidence)
select 'work_independence_v1', q.user_id, q.work, 'eligible_shadow',
       jsonb_build_object('performers', q.performers,
                          'observations', q.observations,
                          'distinct_actions', q.actions)
  from (
    select m.user_id,
           m.normalized_text as work,
           count(distinct lower(btrim(o.normalized_payload ->> 'primary_performer')))
             filter (where coalesce(btrim(o.normalized_payload ->> 'primary_performer'), '') <> '')
             as performers,
           count(*) as observations,
           count(distinct o.action_type) as actions
      from semantic_private.observation_mentions m
      join semantic_private.observations o on o.id = m.observation_id
     where m.mention_role = 'work'
       and o.lifecycle_state = 'active'
       and o.action_weight > 0
     group by m.user_id, m.normalized_text
  ) q
 where q.performers >= 3
on conflict (experiment_key, user_id, normalized_text) do nothing;

-- ---------------------------------------------------------------------------
-- 5. The gate, and the five measurements behind it.
-- ---------------------------------------------------------------------------

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

  -- **Refuse, do not caveat.** A number that is printed gets quoted, and the
  -- whole failure this experiment guards against is a threshold read off too
  -- little data. The gate is the experiment.
  if population < gate then
    raise exception
      'work_independence_v1 may not be evaluated: % account(s) emit work mentions, gate is %',
      population, gate;
  end if;

  select jsonb_build_object(
    'population', population,
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
    -- **Null, never zero.** "No review has happened" and "review rejected
    -- everything" are different facts and only one of them is a result.
    'm3_precision_after_review', null,
    'm4_evidence_independence', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'performers', evidence -> 'performers',
               'distinct_actions', evidence -> 'distinct_actions',
               'observations', evidence -> 'observations')), '[]'::jsonb)
        from semantic_private.vocabulary_experiment_candidates
       where experiment_key = 'work_independence_v1' and state = 'eligible_shadow'),
    'm5_growth_per_useful_assertion', jsonb_build_object(
      'would_mint', (select count(distinct normalized_text)
                       from semantic_private.vocabulary_experiment_candidates
                      where experiment_key = 'work_independence_v1'
                        and state = 'eligible_shadow'),
      'assertions_clearing_bar', null)
  ) into result;

  return result;
end;
$$;

revoke all on function semantic_private.evaluate_work_independence()
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.evaluate_work_independence() to semantic_worker;

-- ---------------------------------------------------------------------------
-- 6. Prove it, both ways.
-- ---------------------------------------------------------------------------

do $$
declare
  shadowed   integer;
  minted     integer;
  population integer;
  refused    boolean := false;
begin
  select count(distinct user_id) into population
    from semantic_private.observation_mentions where mention_role = 'work';

  select count(*) into shadowed
    from semantic_private.vocabulary_experiment_candidates
   where experiment_key = 'work_independence_v1' and state = 'eligible_shadow';

  -- **Nothing was minted, which is the property that matters.** A shadow that
  -- quietly became vocabulary would be this migration doing the one thing it
  -- exists to refuse.
  select count(*) into minted
    from semantic_private.vocabulary_experiment_candidates c
    join ontology.concepts oc
      on oc.concept_key = 'work:' || c.normalized_text
   where c.experiment_key = 'work_independence_v1';
  if minted <> 0 then
    raise exception '0223: % shadow candidate(s) exist as concepts', minted;
  end if;

  -- **The gate refuses, and it is demonstrated rather than described.** A check
  -- that has only ever been described is not one to believe.
  begin
    perform semantic_private.evaluate_work_independence();
  exception when others then
    refused := true;
  end;
  if population < 5 and not refused then
    raise exception '0223: the population gate did not refuse at % account(s)', population;
  end if;
  if population >= 5 and refused then
    raise exception '0223: the gate refused at % account(s), at or above its own limit', population;
  end if;

  -- **And the freeze refuses.** Same rule: demonstrate it.
  refused := false;
  begin
    update semantic_private.vocabulary_experiments
       set rule = rule || jsonb_build_object('minimum_distinct_performers', 2)
     where experiment_key = 'work_independence_v1';
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception '0223: the frozen rule accepted an amendment';
  end if;

  -- ...while the lifecycle still moves, or the row could never be concluded.
  update semantic_private.vocabulary_experiments
     set notes = notes
   where experiment_key = 'work_independence_v1';

  raise notice
    '0223: work_independence_v1 frozen; % shadow candidate(s) from % account(s), 0 minted, gate 5',
    shadowed, population;
end;
$$;

commit;
