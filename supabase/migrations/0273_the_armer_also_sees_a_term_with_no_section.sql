-- 0273 — the armer also sees a kept term that reaches no section.
--
-- `0272` gave the mint processor a second job: repair kept concepts that reach
-- no block, using the same derivation a fresh keep uses. It runs inside
-- `process_mint_requests`, and `0270`'s armer arms that only while a mint
-- request is pending — so with every request already completed, the repair had
-- nothing to run it. Nine concepts, a working repair, and no path from one to
-- the other.
--
-- The same shape as the defect `0270` itself fixed: work that exists with
-- nothing left that would ever look at it. So the armer's question widens from
-- *is a request pending* to *is there work of either kind*, both read from the
-- data rather than from a flag somebody sets.

create or replace function semantic_private.arm_pending_mint_requests()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  armed integer := 0;
  request_row record;
  orphans integer := 0;
  next_count bigint;
begin
  -- Nothing while one is live: the handler drains every pending request and
  -- repairs every floating concept in one pass, so a second job would be a
  -- second pass over the same work.
  if exists (
    select 1 from semantic_private.worker_jobs j
     where j.job_type = 'process_mint_requests'
       and j.status in ('queued', 'running')) then
    return 0;
  end if;

  select mr.id into request_row
    from semantic_private.mint_requests mr
   where mr.status = 'pending'
   order by mr.created_at
   limit 1;

  -- **The second kind of work.** A kept concept that reaches no block is a
  -- term sitting under "Other" with a derivable parent nobody has written yet.
  select count(*) into orphans
    from semantic_private.mint_requests mr
   where mr.status = 'completed'
     and mr.outcome ->> 'concept_id' is not null
     and semantic_private.concept_block(
           (mr.outcome ->> 'concept_id')::uuid,
           (select id from ontology.versions where status = 'published')) is null;

  if request_row.id is null and orphans = 0 then
    return 0;
  end if;

  -- The cursor is what makes a retry possible: a dead row holds its key, so a
  -- counter in the key means the next arming is a different job rather than a
  -- conflict quietly doing nothing. Counted from the jobs themselves, which
  -- only ever grow.
  select count(*) + 1 into next_count
    from semantic_private.worker_jobs
   where job_type = 'process_mint_requests';

  insert into semantic_private.worker_jobs
    (job_type, user_id, payload, idempotency_key, available_at)
  values ('process_mint_requests', null,
          jsonb_build_object('mint_request_id',
            coalesce(request_row.id,
                     -- Provenance when the work is a repair rather than a
                     -- fresh keep: the oldest completed request, because the
                     -- payload's shape is fixed and a null is not permitted.
                     (select mr.id from semantic_private.mint_requests mr
                       where mr.status = 'completed'
                       order by mr.created_at limit 1))),
          'mint:v1:' || next_count::text,
          now())
  on conflict (idempotency_key) do nothing;

  get diagnostics armed = row_count;
  return armed;
end;
$$;

revoke all on function semantic_private.arm_pending_mint_requests()
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.arm_pending_mint_requests()
  to semantic_worker;

do $$
declare
  body text;
begin
  body := regexp_replace(
            pg_get_functiondef(
              'semantic_private.arm_pending_mint_requests()'::regprocedure),
            '--[^\n]*', '', 'g');
  if position('concept_block' in body) = 0 then
    raise exception '0273: the armer still cannot see a term with no section';
  end if;

  -- Both ways, over whatever this database holds: with work of either kind it
  -- arms exactly one job and not two; with none it arms nothing. The same
  -- assertion answers on an empty replay database and on production.
  if exists (select 1 from semantic_private.mint_requests where status = 'pending')
     or exists (
       select 1 from semantic_private.mint_requests mr
        where mr.status = 'completed'
          and mr.outcome ->> 'concept_id' is not null
          and semantic_private.concept_block(
                (mr.outcome ->> 'concept_id')::uuid,
                (select id from ontology.versions where status = 'published')) is null)
  then
    if semantic_private.arm_pending_mint_requests() <> 1 then
      raise exception '0273: outstanding kept work did not arm the processor';
    end if;
    if semantic_private.arm_pending_mint_requests() <> 0 then
      raise exception '0273: the processor was armed twice for one backlog';
    end if;
  else
    if semantic_private.arm_pending_mint_requests() <> 0 then
      raise exception '0273: the processor armed with nothing outstanding';
    end if;
  end if;
end;
$$;
