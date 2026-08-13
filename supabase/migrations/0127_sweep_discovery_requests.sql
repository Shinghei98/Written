-- 0127 — the rate-limit ledger stops growing forever.
--
-- `0125` records one row per `discover_profiles` call so the limit can count,
-- and nothing removes them. Left alone that table becomes a permanent log of
-- **when each person browsed**, which is behavioural data about the user that
-- nobody decided to keep.
--
-- **Two hours, not thirty days, and the window is the argument.** `0016` keeps
-- YouTube rows for thirty days because a *contract* says so. Here the only
-- stated purpose is a limit measured over one hour, so an hour of rows is what
-- serves it; two gives margin for a job that runs late without inventing a
-- second purpose. Keeping a day "in case it is useful for abuse investigation"
-- would be exactly that — a new purpose arrived at by not deleting something.
--
-- **Hourly rather than daily**, which is the opposite of `0016`'s reasoning and
-- for the same reason: there the window is thirty days and a daily job is
-- already 30× finer than it needs to be, while here a daily job would let a
-- day of rows pile up to serve a one-hour question. The work is a delete over
-- an indexed predicate.

begin;

-- The sweep's predicate is `requested_at` alone. `0125`'s index leads on
-- `user_id`, which serves the count inside the RPC and not this — so the scan
-- would be of the table rather than of its tail.
create index if not exists discovery_requests_age_idx
  on semantic_private.discovery_requests (requested_at);

create or replace function semantic_private.sweep_discovery_requests()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed integer;
begin
  delete from semantic_private.discovery_requests
   where requested_at < now() - interval '2 hours';
  get diagnostics removed = row_count;
  return removed;
end;
$$;

comment on function semantic_private.sweep_discovery_requests() is
  'Deletes rate-limit rows older than two hours. The limit measures one hour, '
  'so anything beyond that serves no stated purpose and would be a browsing '
  'log nobody decided to keep. Scheduled hourly; not callable by any client.';

-- `security definer` because the job runs with no session behind it, and
-- revoked from callers for the reason `0016` gives: nothing signed in has any
-- business invoking a function that deletes across all accounts. From `anon`
-- by name as well as from `PUBLIC` — `0124`'s lesson about Supabase's default
-- privileges applies to every new function, and this one lives in a schema
-- clients cannot reach anyway, which is belt and braces rather than either
-- alone.
revoke all on function semantic_private.sweep_discovery_requests() from public, anon, authenticated;

-- Off the hour, like the two jobs already scheduled at :17 and :27, so three
-- sweeps do not contend for the same minute.
select cron.schedule(
  'discovery-requests-sweep',
  '37 * * * *',
  $$select semantic_private.sweep_discovery_requests()$$
);

-- **Behaviour, on rows made for the purpose and removed again.** Asserting the
-- job exists would prove scheduling, not sweeping — and this file's standing
-- rule since `0117` is that a check must be able to fail for the reason it
-- exists.
do $$
declare
  someone uuid;
  removed integer;
  survivors integer;
begin
  select id into someone from public.users limit 1;
  if someone is null then
    raise notice 'no users; sweep unexercised';
    return;
  end if;

  insert into semantic_private.discovery_requests (user_id, requested_at)
  values (someone, now() - interval '3 hours'),   -- must go
         (someone, now() - interval '1 minute');  -- must stay

  removed := semantic_private.sweep_discovery_requests();
  if removed < 1 then
    raise exception 'sweep removed nothing when a three-hour-old row existed';
  end if;

  select count(*) into survivors
    from semantic_private.discovery_requests
   where user_id = someone and requested_at > now() - interval '2 hours';
  if survivors < 1 then
    raise exception 'sweep removed a row inside the window it must not touch';
  end if;

  -- Leave the table as it was found: the fresh row was made by this check and
  -- would otherwise count against that person's next hour of browsing.
  delete from semantic_private.discovery_requests
   where user_id = someone and requested_at > now() - interval '2 hours';
end
$$;

commit;
