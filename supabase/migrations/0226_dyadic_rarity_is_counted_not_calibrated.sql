-- 0226 — dyadic rarity is counted, not calibrated.
--
-- ## The signal
--
-- Two people sharing an obscure recording says far more about them than two
-- people sharing a chart hit. That is **rarity-weighted overlap**, and it is the
-- right kind of signal for matching: the same shape as inverse document
-- frequency, where an item's worth is inversely related to how many people hold
-- it.
--
-- `0164` already computes two things adjacent to this and **neither is it**:
--
--   * `specificity` — `1 / (1 + mean hops to the bridge)`. How deep in the graph.
--   * `information_value` — `1 / (1 + direct children of the bridge)`. How broad
--     the concept is.
--
-- Both are **structural** rarity, read off the ontology's shape. Neither knows
-- anything about how many *people* hold a thing, which is population rarity and
-- is what this measures. They are complementary and this replaces neither.
--
-- ## Why it is instrumented and not built
--
-- **Two accounts hold ISRCs.** So an item's document frequency has exactly two
-- possible values — `0.5` if one holds it, `1.0` if both — and every rarity
-- weight derivable from that is a choice between two numbers dressed as a
-- statistic. **1,340 distinct ISRCs, 5 shared** — and the first snapshot's
-- histogram is the argument in one line: `{1: 1335, 2: 5}`, every item held by
-- either one account or two, with no third band for a weight to discriminate
-- between. A weighting fitted to five overlapping rows across one pair would be
-- indistinguishable from a weighting fitted to nothing, and this project has
-- just spent an afternoon on two thresholds read off the data they were tuned
-- against.
--
-- (Those counts are **after** `action_weight > 0`, the same policy filter the
-- scorer applies, so the instrument counts what the pipeline would actually
-- weigh. Counted without it there are 1,513 items and 6 shared, which is what
-- an earlier draft of this comment quoted and is the wrong denominator for a
-- statistic about evidence.)
--
-- So the split is: **counting is safe now, calibrating is not.**
--
--   * The snapshot records **aggregate distributions** — how many items are held
--     by how many accounts — which is meaningful at any population and is what
--     will make the eventual calibration possible rather than retrospective.
--   * `dyad_rarity_calibration` **refuses below five accounts**, the same floor
--     `EmergentTermMiner` uses and reused rather than reinvented.
--   * **Nothing here is wired into `dyad_alignment_pairs`, `specificity` or
--     `information_value`.** The instrument observes; it does not rank.
--
-- ## The frozen definition, which is `dyad_rarity_v1`
--
--   document_frequency(item)  = accounts holding it / accounts holding any item
--   rarity(item)              = -log2(document_frequency)
--   dyad_overlap_rarity(a, b) = sum of rarity over items both hold
--
-- Stamped onto every snapshot as `definition_version`, so a row measured under
-- one definition is never silently compared against a row measured under
-- another. **A superseding definition takes a new version string** rather than
-- an edit — the same rule the model versions follow, for the same reason.
--
-- ## What is recorded, and what deliberately is not
--
-- **Distributions, never per-item rows.** "How many items are held by exactly
-- two accounts" is an aggregate. "*Which* item" at a population of two names one
-- person's library and then the other's, which is the disclosure
-- `EmergentTermMiner`'s floor exists to prevent. The histogram carries counts
-- and no identifiers.
--
-- Per-dyad overlap is likewise **not** stored: `0164`'s guards already refuse a
-- dyad run without an active match authorisation, and an instrument that
-- recorded overlap for unmatched pairs would route around a rule rather than
-- respect it.

begin;

create table if not exists semantic_private.dyad_rarity_snapshots (
  id                 uuid primary key default extensions.gen_random_uuid(),
  seq                bigint generated always as identity,
  -- **Which definition produced this row.** `now()` is transaction time and
  -- cannot order two snapshots taken together; `seq` can. Same defect `0224`
  -- had to repair after its own probe caught it.
  definition_version text not null,
  taken_at           timestamptz not null default now(),
  -- Accounts holding at least one identified item. The denominator of every
  -- frequency below, recorded so a later reader never has to guess what the
  -- population was when the snapshot was taken.
  population         integer not null check (population >= 0),
  distinct_items     integer not null check (distinct_items >= 0),
  shared_items       integer not null check (shared_items >= 0),
  -- accounts_holding -> number of items held by exactly that many accounts.
  -- Counts only; no item identifiers, no user ids.
  frequency_histogram jsonb not null,
  calibration_gate    integer not null,
  calibration_gate_open boolean not null,
  notes              text
);

comment on table semantic_private.dyad_rarity_snapshots is
  'Aggregate population-rarity distributions over time. Counts only: no item '
  'identifiers and no user ids, because "which item" at a small population names '
  'an individual library. Feeds no ranking.';

alter table semantic_private.dyad_rarity_snapshots enable row level security;
grant select, insert on semantic_private.dyad_rarity_snapshots to semantic_worker;
revoke all on semantic_private.dyad_rarity_snapshots from anon, authenticated, semantic_ingestor;

-- **Append-only.** A distribution is a measurement of a moment; editing one
-- would rewrite what was observed. Same refusal as `review_items` and the
-- attestation ledger.
create or replace function semantic_private.guard_dyad_rarity_snapshot_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'dyad_rarity_snapshots is append-only; take a new snapshot';
end;
$$;

drop trigger if exists guard_dyad_rarity_snapshot_append_only
  on semantic_private.dyad_rarity_snapshots;
create trigger guard_dyad_rarity_snapshot_append_only
  before update or delete on semantic_private.dyad_rarity_snapshots
  for each row execute function semantic_private.guard_dyad_rarity_snapshot_append_only();

-- ---------------------------------------------------------------------------
-- The instrument: safe at any population, because it counts.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.snapshot_dyad_rarity()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  snapshot_id uuid;
  gate constant integer := 5;
begin
  with held as (
    select upper(o.normalized_payload ->> 'isrc') as item, o.user_id
      from semantic_private.observations o
     where o.lifecycle_state = 'active'
       and o.action_weight > 0
       and coalesce(o.normalized_payload ->> 'isrc', '') <> ''
     group by 1, 2
  ),
  per_item as (
    select item, count(distinct user_id) as accounts from held group by item
  )
  insert into semantic_private.dyad_rarity_snapshots
    (definition_version, population, distinct_items, shared_items,
     frequency_histogram, calibration_gate, calibration_gate_open)
  select
    'dyad_rarity_v1',
    (select count(distinct user_id) from held),
    (select count(*) from per_item),
    (select count(*) from per_item where accounts >= 2),
    coalesce((select jsonb_object_agg(accounts::text, items)
                from (select accounts, count(*) as items
                        from per_item group by accounts) h), '{}'::jsonb),
    gate,
    (select count(distinct user_id) from held) >= gate
  returning id into snapshot_id;

  return snapshot_id;
end;
$$;

revoke all on function semantic_private.snapshot_dyad_rarity()
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.snapshot_dyad_rarity() to semantic_worker;

-- ---------------------------------------------------------------------------
-- The calibration, which refuses.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.dyad_rarity_calibration()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  population integer;
  gate constant integer := 5;
  result jsonb;
begin
  select count(distinct user_id) into population
    from semantic_private.observations
   where lifecycle_state = 'active' and action_weight > 0
     and coalesce(normalized_payload ->> 'isrc', '') <> '';

  -- **Refuse, do not caveat.** At two accounts a document frequency is one of
  -- two numbers and every weight derived from it is a coin dressed as a
  -- statistic. A returned value would be quoted; a refusal cannot be.
  if population < gate then
    raise exception
      'dyad rarity may not be calibrated: % account(s) hold identified items, gate is %',
      population, gate;
  end if;

  with held as (
    select upper(o.normalized_payload ->> 'isrc') as item, o.user_id
      from semantic_private.observations o
     where o.lifecycle_state = 'active'
       and o.action_weight > 0
       and coalesce(o.normalized_payload ->> 'isrc', '') <> ''
     group by 1, 2
  ),
  per_item as (
    select item, count(distinct user_id) as accounts from held group by item
  ),
  banded as (
    select accounts, count(*) as items from per_item group by accounts
  )
  select jsonb_build_object(
    'definition_version', 'dyad_rarity_v1',
    'population', population,
    -- **Bands, not items.** The calibration says what a shared item at each
    -- frequency is worth; naming the item would be the disclosure the gate and
    -- the histogram both exist to avoid.
    'rarity_by_frequency', coalesce(jsonb_agg(jsonb_build_object(
        'accounts_holding', accounts,
        'items', items,
        'document_frequency', round(accounts::numeric / population, 4),
        -- `-log2(df)`: an item everybody holds is worth 0 bits, one held by a
        -- fifth of the population is worth log2(5).
        'rarity_bits', round(-log(2.0, accounts::numeric / population), 4))
      order by accounts), '[]'::jsonb)
  ) into result
  from banded;

  return result;
end;
$$;

revoke all on function semantic_private.dyad_rarity_calibration()
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.dyad_rarity_calibration() to semantic_worker;

-- ---------------------------------------------------------------------------
-- Prove it, both ways.
-- ---------------------------------------------------------------------------

do $$
declare
  snap        uuid;
  row_seen    record;
  population  integer;
  refused     boolean := false;
begin
  select count(distinct user_id) into population
    from semantic_private.observations
   where lifecycle_state = 'active' and action_weight > 0
     and coalesce(normalized_payload ->> 'isrc', '') <> '';

  -- **The counting half works now**, which is the point of separating it.
  snap := semantic_private.snapshot_dyad_rarity();
  select * into row_seen from semantic_private.dyad_rarity_snapshots where id = snap;
  if row_seen.population <> population then
    raise exception '0226: snapshot recorded population % against %',
      row_seen.population, population;
  end if;
  if row_seen.calibration_gate_open <> (population >= 5) then
    raise exception '0226: the gate flag disagrees with the population';
  end if;
  if row_seen.shared_items > row_seen.distinct_items then
    raise exception '0226: more shared items than items';
  end if;

  -- **The calibrating half refuses**, demonstrated rather than described.
  begin
    perform semantic_private.dyad_rarity_calibration();
  exception when others then
    refused := true;
  end;
  if population < 5 and not refused then
    raise exception '0226: calibration did not refuse at % account(s)', population;
  end if;
  if population >= 5 and refused then
    raise exception '0226: calibration refused at or above its own gate';
  end if;

  -- **And the snapshot cannot be rewritten.**
  refused := false;
  begin
    update semantic_private.dyad_rarity_snapshots set population = 999 where id = snap;
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception '0226: a snapshot accepted an update';
  end if;

  -- **Nothing was wired into ranking**, which is the property most easily lost
  -- later: an instrument that quietly acquires a caller has stopped being one.
  --
  -- **`prosrc`, not `pg_get_functiondef`.** The first version used the latter and
  -- the replay refused it with `"array_agg" is an aggregate function`: there is
  -- no guaranteed evaluation order between a `where` qual and a function call in
  -- the same predicate, so Postgres reached `pg_get_functiondef` on rows the
  -- namespace filter was supposed to have excluded. `prosrc` is a column and
  -- cannot raise, and `prokind = 'f'` keeps aggregates and window functions out
  -- on their own account rather than by luck.
  if exists (
    select 1 from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'semantic_private'
      and p.prokind = 'f'
      and p.proname not in ('dyad_rarity_calibration', 'snapshot_dyad_rarity')
      and p.prosrc like '%dyad_rarity_calibration%') then
    raise exception '0226: something already calls the calibration; it is no longer an instrument';
  end if;

  raise notice
    '0226: snapshot taken — population %, items %, shared %, gate_open %',
    row_seen.population, row_seen.distinct_items, row_seen.shared_items,
    row_seen.calibration_gate_open;
end;
$$;

commit;
