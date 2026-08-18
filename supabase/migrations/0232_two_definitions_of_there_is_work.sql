-- 0232 — two definitions of "there is work", and they drifted apart.
--
-- ## What was happening
--
-- `build_candidate_overlay` had been armed 209 times for one account and was
-- still climbing every five minutes. 214 jobs had run and every one of them was
-- a no-op. Nothing was corrupted; the queue simply never emptied.
--
-- The stage's work is written by two statements, and each carries its own idea
-- of what is left to do.
--
-- `LINK_EVIDENCE` inserts one row per **(candidate, observation, route)** and
-- skips what it already holds:
--
--     not exists (select 1 from candidate_support_links l
--                  where l.candidate_id = c.id
--                    and l.observation_id = m.observation_id
--                    and l.route_id = <route>)
--
-- The armer asked a different question — whether a support link pointed at
-- **this resolution row**:
--
--     not exists (select 1 from candidate_support_links l
--                  where l.mention_resolution_id = r.id)
--
-- Those agree until a mention is judged twice. `0212` keys a verdict on
-- `(mention_id, route_id, resolver_version, evaluated_ontology_version_id)` and
-- `current_mention_resolutions` is `distinct on (mention_id, route_id)`, so
-- **every ontology publish makes a new row current** and the id the support link
-- recorded belongs to a superseded one. The armer therefore sees work; the job
-- runs, finds its own key already satisfied, writes nothing; the armer sees the
-- same work five minutes later. Four ontology versions were published on
-- 2026-08-17 and the account has been arming ever since.
--
-- Measured before the fix: the one support link in the database points at a
-- superseded resolution row, and the armer's predicate claims one unit of work
-- that the job cannot complete.
--
-- ## The fix, and why it is not the smaller one
--
-- Keying the support link on `(mention_id, route_id)` instead of the resolution
-- row would also close it, and would be wrong: the link records *which verdict
-- this evidence came from*, and a verdict is per vocabulary. Losing that is
-- losing the reason the row exists.
--
-- So the armer is taught to ask the job's question instead of its own. It goes
-- false exactly when `LINK_EVIDENCE` would insert nothing — and it stays true
-- when a publish resolves a mention to a *different* concept, because that is a
-- new candidate with no evidence under it, which is real work.
--
-- **The disjunction in the new predicate is load-bearing.** Asking only whether
-- some active candidate on the concept holds the link would under-arm the moment
-- one concept carries two candidates, and under-arming leaves evidence
-- permanently unreachable, where over-arming only wastes a job. The two failures
-- are not symmetric and the predicate is written to fail toward the cheap one.
--
-- **The two definitions still exist**, one in SQL and one in Python, because the
-- job needs its anti-join for paging and the armer cannot call it. They now ask
-- the same thing, and `supabase/tests/0232_overlay_arming_contract.sql` is what
-- says so — it seeds a support link against a superseded resolution row, which
-- is the exact shape production is in, and asserts the armer stays quiet.
--
-- Nothing else in the function changes. The other three stages, the in-flight
-- guard, the cursor and the idempotency key are reproduced verbatim.

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
           -- **The same question the job's own anti-join asks.** See 0232: this
           -- used to compare `l.mention_resolution_id` against `r.id`, and
           -- `current_mention_resolutions` is `distinct on (mention_id,
           -- route_id)`, so every ontology publish made a new row current and
           -- orphaned the id the support link had recorded. The job then
           -- correctly refused to re-insert on its own key and the test stayed
           -- true forever. Keyed on what the insert is keyed on — concept,
           -- observation, route — it goes false exactly when the job would
           -- write nothing.
           when 'build_candidate_overlay' then exists (
             select 1
               from semantic_private.current_mention_resolutions r
               join semantic_private.observation_mentions m
                 on m.id = r.mention_id and m.user_id = r.user_id
              where r.user_id = u.id
                and r.resolution = 'resolved_existing'
                and r.concept_id is not null
                -- No candidate for this concept yet, or one that is still
                -- missing this observation's evidence. The disjunction is not
                -- decoration: asking only whether *some* candidate holds the
                -- link would under-arm the moment a concept carries two, and
                -- under-arming is the failure that leaves evidence unreachable
                -- rather than the one that wastes a job.
                and (
                  not exists (
                    select 1 from semantic_private.user_term_candidates c
                     where c.user_id = r.user_id
                       and c.concept_id = r.concept_id
                       and c.lifecycle_state = 'active')
                  or exists (
                    select 1 from semantic_private.user_term_candidates c
                     where c.user_id = r.user_id
                       and c.concept_id = r.concept_id
                       and c.lifecycle_state = 'active'
                       and not exists (
                         select 1 from semantic_private.candidate_support_links l
                          where l.candidate_id = c.id
                            and l.observation_id = m.observation_id
                            and l.route_id = r.route_id))))
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
