-- 0211 — the overlay gets a cursor instead of a clever key.
--
-- ## The bug this exists for
--
-- `0209`/`0210` key each armed job on the user's completed resolution count:
-- `overlay:<stage>:<user>:<count>`. That advances while a drain is in progress
-- — 0, 2000, 4000 — and stops the moment the drain finishes. A later
-- distillation adds mentions but no resolutions, so arming recomputes the same
-- key, meets the job that already succeeded, and `on conflict do nothing` does
-- exactly what it says. **The resolver never runs again, so the count can never
-- advance, so it never runs again.** Silent and permanent.
--
-- The instinct is a cleverer key — resolver version, ontology version, state
-- revision, eligible count, route count, all concatenated. That is arithmetic
-- standing in for a data structure: unreadable, uninspectable, and it fails the
-- same way the day a seventh input matters.
--
-- **So: a counter, and real conditions.** `overlay_stage_cursors` holds one
-- monotonically increasing `armed_count` per (user, stage). The key becomes
-- `overlay:v2:<stage>:<user>:<n>` and can never collide with itself or with any
-- `0209`-era key. Whether to arm at all is then decided by asking whether there
-- is work — which is the question that was being smuggled into a string.
--
-- ## Re-resolution: a vocabulary release could not rescue anything
--
-- `mention_resolutions` is unique on `(mention_id, resolver_version, route_id)`,
-- and the resolver skips any mention that already has a row. So a mention
-- recorded `unresolved` today stays unresolved forever, no matter how much
-- vocabulary arrives tomorrow — the row that records the failure is what
-- prevents the retry. Publishing an ontology version would rescue nothing.
--
-- `evaluated_ontology_version_id` fixes it: every outcome now records which
-- vocabulary it was judged against, including the negative ones, and pending
-- work means *not yet judged against the version currently published*. A new
-- ontology version therefore makes every unresolved mention pending again, once,
-- automatically.
--
-- `current_mention_resolutions` is the view everything downstream must read:
-- the newest verdict per mention and route. Without it a mention counts as both
-- unresolved under the old vocabulary and resolved under the new.
--
-- ## The denominator was wrong, and by a factor of five
--
-- Measured on the live account before this migration:
--
--     12,821  mentions on active observations
--     11,741  after excluding action_weight = 0 rows
--      2,362  after collapsing duplicates
--        690  distinct strings
--          1  of those resolvable
--
-- **6,370 duplicate groups** on `(observation_id, normalized_text, mention_role,
-- source_field)`. `INSERT_MENTION` ends `on conflict do nothing` against no
-- unique constraint at all, so every re-run of the legacy resolver wrote the
-- same mentions again with fresh uuids. The clause has never done anything.
--
-- These are derived rows, not vault evidence — re-derivable from the
-- observations that produced them, referenced only by `mention_resolutions`
-- which cascades — so the duplicates are deleted and the constraint the insert
-- always claimed to have is created. Any measurement of coverage taken before
-- today was inflated about five-fold.

begin;

-- ---------------------------------------------------------------------------
-- 1. Natural identity for a mention.
-- ---------------------------------------------------------------------------

-- Oldest row per natural key wins: it is the one any existing resolution
-- already points at, so keeping it means the cascade removes only rows that
-- were duplicates of something surviving.
delete from semantic_private.observation_mentions m
 where m.id <> (
   select keep.id from semantic_private.observation_mentions keep
    where keep.observation_id = m.observation_id
      and keep.normalized_text = m.normalized_text
      and keep.mention_role = m.mention_role
      and keep.source_field is not distinct from m.source_field
      and keep.extraction_method = m.extraction_method
    order by keep.created_at, keep.id
    limit 1);

create unique index observation_mentions_natural_key
  on semantic_private.observation_mentions (
    observation_id, normalized_text, mention_role,
    coalesce(source_field, ''), extraction_method);

-- ---------------------------------------------------------------------------
-- 2. Which vocabulary a verdict was reached against.
-- ---------------------------------------------------------------------------

-- **Deliberately not the existing `ontology_version_id`.** That column is half
-- of the composite foreign key to `concept_revisions` and means *where the
-- concept this resolved to lives*; it is null for every negative outcome, which
-- is exactly the set that needs re-examining. This one means *what was
-- searched*, and is set on every row.
alter table semantic_private.mention_resolutions
  add column evaluated_ontology_version_id uuid references ontology.versions(id);

comment on column semantic_private.mention_resolutions.evaluated_ontology_version_id is
  'The published ontology version this verdict was reached against, set for '
  'negative outcomes too. Pending work is a mention with no row at the version '
  'currently published, which is what lets new vocabulary rescue an old '
  'unresolved mention. Null on rows written before 0211.';

-- The newest verdict per mention and route. **Everything downstream reads this
-- and never the table**, the same rule as reading through `summary_*` views and
-- `current_source_items`: a mention can otherwise be counted as unresolved under
-- one vocabulary and resolved under another, in the same query.
create or replace view semantic_private.current_mention_resolutions
with (security_invoker = on) as
select distinct on (r.mention_id, r.route_id)
       r.*
  from semantic_private.mention_resolutions r
  left join ontology.versions v on v.id = r.evaluated_ontology_version_id
 order by r.mention_id, r.route_id, v.published_at desc nulls last, r.created_at desc;

grant select on semantic_private.current_mention_resolutions to semantic_worker;

-- ---------------------------------------------------------------------------
-- 3. The cursor.
-- ---------------------------------------------------------------------------

create table semantic_private.overlay_stage_cursors (
  user_id uuid not null references auth.users(id) on delete cascade,
  stage text not null check (stage in (
    'resolve_mention', 'build_candidate_overlay',
    'aggregate_term_candidates', 'build_review_items')),
  -- Monotone, and its only job is to make the next idempotency key unique. It
  -- is not a measure of progress and must never be read as one.
  armed_count bigint not null default 0 check (armed_count >= 0),
  last_armed_at timestamptz,
  primary key (user_id, stage)
);

alter table semantic_private.overlay_stage_cursors enable row level security;
revoke all on semantic_private.overlay_stage_cursors from public;
grant select on semantic_private.overlay_stage_cursors to semantic_worker;

-- Indexes the armer's pending-work questions need. Without these it sequentially
-- scans 73,126 mentions per stage per user every five minutes.
create index observation_mentions_user_idx
  on semantic_private.observation_mentions (user_id);
create index mention_resolutions_route_idx
  on semantic_private.mention_resolutions (mention_id, route_id);

-- ---------------------------------------------------------------------------
-- 4. Arming, decided by work rather than by a string.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.arm_candidate_overlay(
  target_user uuid default null,
  resolver_version text default 'exact-0.1.0'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  armed integer := 0;
  published uuid;
  candidate record;
  plan record;
  next_count bigint;
begin
  select id into published from ontology.versions where status = 'published';
  if published is null then
    raise notice 'arm_candidate_overlay: no published ontology; nothing can resolve';
    return 0;
  end if;

  for plan in
    select * from (values
      ('resolve_mention', jsonb_build_object('resolver_version', resolver_version), 0),
      ('build_candidate_overlay', '{}'::jsonb, 90),
      ('aggregate_term_candidates', '{}'::jsonb, 180),
      ('build_review_items', jsonb_build_object('review_epoch', 0), 270)
    ) as s(job_type, extra, delay_seconds)
  loop
    for candidate in
      select u.id as user_id
        from auth.users u
       where (target_user is null or u.id = target_user)
         -- Nothing of this stage already in flight for this account.
         and not exists (
           select 1 from semantic_private.worker_jobs j
            where j.user_id = u.id and j.job_type = plan.job_type
              and j.status in ('queued', 'running'))
         -- **And there is work.** One condition per stage, each asking of the
         -- data rather than of a counter.
         and case plan.job_type
           when 'resolve_mention' then exists (
             select 1
               from semantic_private.observation_mentions m
               join semantic_private.observations o
                 on o.id = m.observation_id and o.user_id = m.user_id
              where m.user_id = u.id
                and o.lifecycle_state = 'active'
                and o.action_weight > 0
                and not exists (
                  select 1 from semantic_private.mention_resolutions r
                   where r.mention_id = m.id
                     and r.evaluated_ontology_version_id = published))
           when 'build_candidate_overlay' then exists (
             select 1 from semantic_private.current_mention_resolutions r
              where r.user_id = u.id and r.resolution = 'resolved_existing'
                and not exists (
                  select 1 from semantic_private.candidate_support_links l
                   where l.mention_resolution_id = r.id))
           when 'aggregate_term_candidates' then exists (
             select 1
               from semantic_private.user_term_candidates c
               join semantic_private.candidate_support_links l
                 on l.candidate_id = c.id
              where c.user_id = u.id and c.lifecycle_state = 'active'
              group by c.id, c.updated_at
             having max(l.created_at) > c.updated_at)
           when 'build_review_items' then exists (
             select 1 from semantic_private.user_term_candidates c
              where c.user_id = u.id and c.lifecycle_state = 'active'
                and not exists (
                  select 1 from semantic_private.review_items i
                   where i.candidate_id = c.id and i.review_epoch = 0))
           else false
         end
    loop
      insert into semantic_private.overlay_stage_cursors (user_id, stage, armed_count, last_armed_at)
      values (candidate.user_id, plan.job_type, 1, now())
      on conflict (user_id, stage) do update
        set armed_count = semantic_private.overlay_stage_cursors.armed_count + 1,
            last_armed_at = now()
      returning armed_count into next_count;

      insert into semantic_private.worker_jobs
        (job_type, user_id, payload, idempotency_key, available_at)
      values (plan.job_type, candidate.user_id,
              plan.extra || jsonb_build_object('user_id', candidate.user_id::text),
              'overlay:v2:' || plan.job_type || ':' || candidate.user_id::text
                || ':' || next_count::text,
              now() + make_interval(secs => plan.delay_seconds));
      armed := armed + 1;
    end loop;
  end loop;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_candidate_overlay(uuid, text)
  from public, anon, authenticated, semantic_ingestor, semantic_worker;

-- ---------------------------------------------------------------------------
-- Assertions.
-- ---------------------------------------------------------------------------

do $$
declare
  duplicates integer;
  armed integer;
  again integer;
begin
  -- 1. The natural key holds, which is what the delete above was for.
  select count(*) into duplicates from (
    select 1 from semantic_private.observation_mentions
     group by observation_id, normalized_text, mention_role,
              coalesce(source_field, ''), extraction_method
    having count(*) > 1) d;
  if duplicates <> 0 then
    raise exception '0211: % duplicate mention group(s) survive the natural key', duplicates;
  end if;

  -- 2. **Arming is idempotent and no longer self-blocking.** The first call may
  --    or may not find work depending on the database; the second must add
  --    nothing, because everything it would arm is now in flight. That is the
  --    property `0209` also had — what it lacked is the third check.
  select semantic_private.arm_candidate_overlay() into armed;
  select semantic_private.arm_candidate_overlay() into again;
  if again <> 0 then
    raise exception '0211: a second arming enqueued % more job(s)', again;
  end if;

  -- 3. **The key advances even when nothing has been resolved**, which is the
  --    whole bug. Two arming rounds for one stage must produce two distinct
  --    keys regardless of progress.
  if exists (
    select 1 from semantic_private.overlay_stage_cursors c
     where c.armed_count > 1
       and (select count(distinct j.idempotency_key)
              from semantic_private.worker_jobs j
             where j.user_id = c.user_id and j.job_type = c.stage
               and j.idempotency_key like 'overlay:v2:%') < 2
  ) then
    raise exception '0211: a stage armed twice produced fewer than two keys';
  end if;

  -- 4. Every armed payload still satisfies the registry.
  if exists (
    select 1 from semantic_private.worker_jobs j
     where j.status = 'queued'
       and j.idempotency_key like 'overlay:v2:%'
       and not semantic_private.worker_job_payload_is_valid_v03(
             j.job_type, j.user_id, j.payload)
  ) then
    raise exception '0211: an armed payload does not satisfy its own contract';
  end if;

  raise notice '0211: natural key clean, arming idempotent, % job(s) armed', armed;
end;
$$;

commit;
