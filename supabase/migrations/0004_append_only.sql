-- Nothing is ever deleted: every distillation is kept.
--
-- Until now a re-distillation destroyed the one before it. `replace_source_records`
-- deleted a source's rows before inserting, `health_signals` was keyed on
-- `user_id` alone and upserted, and `health_sports` had grown a delete-then-insert
-- so a sport someone stopped doing wouldn't linger. Each was locally reasonable
-- and collectively they meant the database held one moment rather than a history.
--
-- What that costs is drift, and drift is the interesting part: that someone's top
-- artists differed in March is a fact about them, and it cannot be reconstructed
-- once overwritten. Storage is not the constraint — a distillation is under two
-- thousand rows.
--
-- The obstacle was that no column identified a *run*. `collected_at` is stamped
-- per record with `Date()`, so rows from one distillation differ by microseconds
-- and cannot be grouped. `distilled_at` is set once, server-side, by
-- `append_source_records`.

-- ---------------------------------------------------------------------------
-- The run stamp, promoted into every primary key
-- ---------------------------------------------------------------------------

-- Dropped first: it names the old primary key in its `on conflict`, so the key
-- cannot be altered while it exists. Recreated as `append_source_records` in
-- 0005 — the rename is deliberate, because a function called *replace* that
-- appends is the kind of thing that gets trusted at a glance.
drop function if exists public.replace_source_records(text, jsonb);

alter table public.distilled_records
    add column if not exists distilled_at timestamptz;

-- Existing rows are one run each. `collected_at` is per-record so it cannot say
-- exactly when the run happened, but the newest record in a source is within
-- seconds of it, and every row of that source belongs to the same distillation.
update public.distilled_records r
   set distilled_at = m.at
  from (select user_id, source, max(collected_at) at
          from public.distilled_records group by 1, 2) m
 where r.user_id = m.user_id and r.source = m.source
   and r.distilled_at is null;

alter table public.distilled_records
    alter column distilled_at set not null,
    alter column distilled_at set default now();

alter table public.distilled_records drop constraint if exists distilled_records_pkey;
alter table public.distilled_records
    add primary key (user_id, source, data_type, item_id, distilled_at);

comment on column public.distilled_records.distilled_at is
    'Identifies the distillation run. One value per push, set server-side. Distinct from collected_at, which is stamped per record and differs by microseconds within a run.';

-- ---------------------------------------------------------------------------
-- Derived health, likewise
-- ---------------------------------------------------------------------------

alter table public.health_signals
    add column if not exists distilled_at timestamptz;
update public.health_signals set distilled_at = coalesce(updated_at, now()) where distilled_at is null;
alter table public.health_signals
    alter column distilled_at set not null,
    alter column distilled_at set default now();
alter table public.health_signals drop constraint if exists health_signals_pkey;
alter table public.health_signals add primary key (user_id, distilled_at);

alter table public.health_sports
    add column if not exists distilled_at timestamptz;
update public.health_sports set distilled_at = now() where distilled_at is null;
alter table public.health_sports
    alter column distilled_at set not null,
    alter column distilled_at set default now();
alter table public.health_sports drop constraint if exists health_sports_pkey;
alter table public.health_sports add primary key (user_id, sport, distilled_at);

-- Every read below orders on this.
create index if not exists distilled_records_user_source_run_idx
    on public.distilled_records (user_id, source, distilled_at desc);
create index if not exists health_sports_user_run_idx
    on public.health_sports (user_id, distilled_at desc);
create index if not exists health_signals_user_run_idx
    on public.health_signals (user_id, distilled_at desc);

-- ---------------------------------------------------------------------------
-- Reading it back: one summary across every run
-- ---------------------------------------------------------------------------

-- The app wants a combined picture, not the newest run — something distilled
-- once and since aged out of a lookback window still counts toward who someone
-- is. So each view takes the *latest row per key*, which is a union across runs.
--
-- **Latest per key, never a sum.** Each HealthKit distillation reports sessions
-- and minutes over a 365-day lookback, so it is a cumulative reading rather than
-- an increment: two runs a week apart describe substantially the same year of
-- workouts, and adding them would roughly double every figure on the exercise
-- card. Apple Music play counts behave the same way. Union is the combination
-- that is wanted; addition is a silent double-count that reads as enthusiasm.
--
-- `security_invoker = on` is load-bearing. A view runs as its owner by default,
-- which would bypass row-level security — and RLS is the *whole* authorisation
-- layer here, so that would hand every signed-in user every other user's rows.

create or replace view public.summary_distilled_records
with (security_invoker = on) as
select distinct on (user_id, source, data_type, item_id)
       user_id, source, data_type, item_id, name, creator, detail,
       extra, collected_at, removed_at, removed_reason, distilled_at
  from public.distilled_records
 order by user_id, source, data_type, item_id, distilled_at desc;

comment on view public.summary_distilled_records is
    'Every item ever distilled, carrying its most recent row. A union across runs, not a sum.';

create or replace view public.summary_health_sports
with (security_invoker = on) as
select distinct on (user_id, sport)
       user_id, sport, sessions, minutes, distilled_at
  from public.health_sports
 order by user_id, sport, distilled_at desc;

comment on view public.summary_health_sports is
    'Every sport ever recorded, with its latest figures. Figures are cumulative per run, so they are taken, never added.';

-- The latest row rather than any blend: chronotype is a median over 365 days,
-- and the median of two medians is not a median. The raw rows are discarded on
-- the device, so there is no honest way to recompute one — the newest full-year
-- reading *is* the summary.
create or replace view public.summary_health_signals
with (security_invoker = on) as
select distinct on (user_id)
       user_id, chronotype_label, median_wake_minutes, spread_minutes,
       days_observed, average_daily_steps, hourly_activity, distilled_at
  from public.health_signals
 order by user_id, distilled_at desc;

comment on view public.summary_health_signals is
    'The newest reading. Medians cannot be merged, so this is a take rather than a blend.';
