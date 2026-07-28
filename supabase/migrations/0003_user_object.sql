-- The user object: identity as columns rather than rows.
--
-- Age, sex and location were `distilled_records` rows — ("health","age"),
-- ("user","gender"), ("location","place") — read back out by
-- `IdentitySummary.summary(in:)`. That worked while the device was the source of
-- truth and every screen was assembled from one flat list, but it makes the
-- three facts a profile leads with unqueryable without a scan, and it ties them
-- to a source whose raw rows are about to stop being stored at all: age and
-- biological sex come from HealthKit, and once the raw HealthKit rows are
-- discarded on the device there is no row left to carry them.
--
-- These are attributes of a person, not observations about them. Columns.

alter table public.users
    add column if not exists birth_date date,
    add column if not exists birth_year integer,
    add column if not exists sex        text,
    add column if not exists place      text,
    add column if not exists tree_seed  bigint;

-- Not an age, and the distinction is load-bearing: an integer age is silently
-- wrong from the user's next birthday onwards. Age is derived at read time.
--
-- Two columns because there are genuinely two precisions, and collapsing them
-- would mean either losing one or inventing the other. `HealthKitDistiller`
-- deliberately keeps only the year — "a full birth date is more than anything
-- here needs" — so writing a date from that path would upload more than the app
-- itself holds. The dashboard's editor collects month/day/year, which is exact
-- and typed on purpose. `birth_date` wins where both exist.
comment on column public.users.birth_date is
    'Exact date, only when the user typed it. Null when age is known only to the year.';

comment on column public.users.birth_year is
    'Year alone, from HealthKit characteristics. Coarser than birth_date and never derived from it.';

comment on column public.users.sex is
    'Biological sex from HealthKit, overridden by the gender the user typed. See IdentitySummary.';

-- District and city — "Shibuya, Tokyo" — never a coordinate. LocationDistiller
-- reverse-geocodes and keeps only the place name, so the precise position never
-- leaves the device, and this column cannot become a location history.
comment on column public.users.place is
    'District and city only, never coordinates.';

-- Follows the account rather than the install, so the plant keeps its character
-- on a new phone. It was per-device in UserDefaults, which meant restoring an
-- account elsewhere silently redrew the garden as a different plant.
comment on column public.users.tree_seed is
    'Seeds TreeSkeleton.make, so a given person''s plant is the same on every device.';

-- ---------------------------------------------------------------------------
-- The one derived health figure with nowhere to live
-- ---------------------------------------------------------------------------

-- The 24 values behind the hourly chart. Derived like the rest of
-- `health_signals` — a normalised movement profile, not samples — so it is clear
-- of guideline 5.1.3 on the same grounds as chronotype and sport levels.
--
-- Without it the chart is the only part of the lifestyle card that cannot be
-- rebuilt from the server, and dropping the raw activity_hour rows would quietly
-- empty it on every restore.
alter table public.health_signals
    add column if not exists hourly_activity jsonb;

comment on column public.health_signals.hourly_activity is
    '24 normalised values, midnight-indexed. Derived from activity_hour rows that are never themselves uploaded.';

-- No new policies: `users` and `health_signals` already carry
-- `for all using (auth.uid() = ...)`, which covers columns added later.

-- ---------------------------------------------------------------------------
-- Backfill, for accounts that predate these columns
-- ---------------------------------------------------------------------------

-- Idempotent (`coalesce` never overwrites a value that is already there), so
-- this is safe to re-run with the rest of the file.
--
-- Without it the user object stays empty until the next distillation or
-- biographics edit, and a restore to a genuinely new device would draw a profile
-- with no age, sex or district despite all three being known — they were simply
-- sitting in `distilled_records` instead of on the user.

update public.users u
   set birth_year = coalesce(u.birth_year, (
           select (r.extra ->> 'birth_year')::int
             from public.distilled_records r
            where r.user_id = u.id and r.source = 'user' and r.data_type = 'age'
              and r.extra ? 'birth_year'
            limit 1)),
       sex        = coalesce(u.sex, (
           select r.name
             from public.distilled_records r
            where r.user_id = u.id and r.source = 'user' and r.data_type = 'gender'
              and r.name <> ''
            limit 1)),
       place      = coalesce(u.place, (
           select r.name
             from public.distilled_records r
            where r.user_id = u.id and r.source = 'location' and r.data_type = 'place'
              and r.name <> ''
            limit 1));
