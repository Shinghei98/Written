-- 0246 — evidence expires on its own, and prohibited text is redacted rather
-- than assumed absent.
--
-- `0244` gave every evidence row an `expires_at` thirty days out and **nothing
-- acted on it**. A retention promise kept by a column nobody reads is the shape
-- this project already names about the async bucket's lifecycle rule: a backstop
-- for a process that died, not a licence to proceed. Here there was not even a
-- backstop.
--
-- Two things, and the second is the one that matters more.
--
-- ## The sweep
--
-- Redaction, never a delete: `refresh_status = 'deleted'` with `encrypted_text`
-- nulled, which is exactly what `source_text_evidence_payload_location_check`
-- was written for in `0238`. Row identity and lineage survive, so an invocation
-- item that named this evidence still resolves and
-- `guard_model_mention_lineage` can still tell that the text behind a mention
-- has gone — which is what that guard's `refresh_status = 'deleted'` branch is
-- for.
--
-- **It cannot extend retention.** The predicate is `expires_at <= now()` and the
-- statement writes no `expires_at`, so running it early does nothing and running
-- it twice does nothing the second time. Idempotence here is not a nicety: a
-- sweep that is safe to rerun is one that can be run by hand after an outage
-- without anybody reasoning about what it already did.
--
-- ## And the prohibited rows, which may already exist
--
-- `0244` shipped the evidence writer with **no source filter**, so Spotify and
-- YouTube titles could have been filed before `741bd57` added one. Nothing has
-- run the job — the armer had no caller and the overlay is off — but *"nothing
-- has run it"* is a claim about code and this is a statement about data. The
-- migration redacts any such row rather than asserting there are none, and then
-- asserts that none survive.

-- ---------------------------------------------------------------------------
-- 1. The sweep.
-- ---------------------------------------------------------------------------

create or replace function semantic_private.sweep_expired_source_text(
  p_limit integer default 5000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  redacted integer := 0;
begin
  with due as (
    select id
      from semantic_private.source_text_evidence
     where expires_at <= now()
       and refresh_status <> 'deleted'
     order by expires_at
     limit greatest(1, p_limit)
     for update skip locked
  )
  update semantic_private.source_text_evidence e
     set encrypted_text = null,
         refresh_status = 'deleted',
         deleted_at = now()
    from due
   where e.id = due.id;

  get diagnostics redacted = row_count;
  return redacted;
end;
$$;

comment on function semantic_private.sweep_expired_source_text is
  'Redacts source text whose retention window has closed: the payload is '
  'nulled and the row is marked deleted, never removed. Bounded and safe to '
  'rerun — the predicate is `expires_at <= now()` and nothing here writes '
  '`expires_at`, so it cannot extend retention.';

revoke all on function semantic_private.sweep_expired_source_text(integer)
  from public, anon, authenticated, semantic_ingestor;
grant execute on function semantic_private.sweep_expired_source_text(integer)
  to semantic_worker;

-- ---------------------------------------------------------------------------
-- 2. Something runs it.
-- ---------------------------------------------------------------------------
--
-- Daily, in the shape `0016` uses for the YouTube sweeps. Scheduled here rather
-- than left to an operator, because the whole defect being fixed is a retention
-- rule with no caller.

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('sweep-expired-source-text')
      where exists (select 1 from cron.job
                     where jobname = 'sweep-expired-source-text');
    perform cron.schedule(
      'sweep-expired-source-text', '17 4 * * *',
      $cron$select semantic_private.sweep_expired_source_text();$cron$);
  else
    -- A replay against a throwaway Postgres has no pg_cron, and the sweep is
    -- still asserted below. Refusing here would make the whole chain
    -- unreplayable, which `tools/ci/unreplayable_migrations.txt` exists to keep
    -- empty.
    raise notice '0246: pg_cron absent; the sweep is defined but not scheduled';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Prohibited text, redacted rather than assumed absent.
-- ---------------------------------------------------------------------------

do $$
declare
  found integer;
begin
  with prohibited as (
    select e.id
      from semantic_private.source_text_evidence e
      join semantic_private.observations o on o.id = e.observation_id
     where o.source_code in ('spotify', 'youtube')
       and e.refresh_status <> 'deleted'
  )
  update semantic_private.source_text_evidence e
     set encrypted_text = null,
         refresh_status = 'deleted',
         deleted_at = now()
    from prohibited
   where e.id = prohibited.id;

  get diagnostics found = row_count;
  if found > 0 then
    raise notice
      '0246: redacted % evidence row(s) from sources that may not feed a model',
      found;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. What must stay true.
-- ---------------------------------------------------------------------------

do $$
declare
  n integer;
  probe uuid;
  alice uuid := '00000000-0000-4000-8000-0000000000e6';
  run_id uuid;
  obs uuid;
begin
  -- No prohibited evidence survives, now or after any later insert this
  -- migration can see.
  select count(*) into n
    from semantic_private.source_text_evidence e
    join semantic_private.observations o on o.id = e.observation_id
   where o.source_code in ('spotify', 'youtube')
     and e.refresh_status <> 'deleted';
  if n <> 0 then
    raise exception '0246: % prohibited evidence row(s) are still live', n;
  end if;

  -- **The sweep is exercised, both ways, on a row built for it.** A predicate
  -- believed without being seen answering is the failure this project names
  -- repeatedly; here it must redact a row that is due and leave one that is not.
  insert into auth.users (id, email) values (alice, 'sweep@example.invalid')
  on conflict (id) do nothing;
  insert into semantic_private.ingestion_runs
    (user_id, source_code, connector_version, input_hash, status)
  values (alice, 'apple_music', 'probe-0246', 'probe_0246', 'running')
  returning id into run_id;
  insert into semantic_private.observations
    (user_id, ingestion_run_id, source_code, data_type, observation_kind,
     action_type, source_item_hmac, record_fingerprint,
     payload_schema_version, normalized_payload, privacy_class)
  values (alice, run_id, 'apple_music', 'library_song', 'catalog_entity',
          'library_song', repeat(md5('0246-obs'), 2), repeat(md5('0246-fp'), 2),
          'synthetic-v0.3.1', '{}'::jsonb, 'public_catalog')
  returning id into obs;

  -- **Backdated `fetched_at`, because the constraint is `expires_at >
  -- fetched_at` rather than `expires_at > now()`.** A row cannot be born
  -- expired, so an expired row is one fetched long enough ago — which is also
  -- the only way one occurs in reality.
  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, fetched_at, expires_at)
  values (alice, obs, '\x01'::bytea, 'probe-key-v1', 'provider_catalog_text',
          now() - interval '40 days', now() - interval '10 days')
  returning id into probe;

  perform semantic_private.sweep_expired_source_text();

  select count(*) into n from semantic_private.source_text_evidence
   where id = probe and refresh_status = 'deleted' and encrypted_text is null;
  if n <> 1 then
    raise exception '0246: the sweep did not redact an expired row';
  end if;

  -- The other direction: a row still within its window is untouched.
  insert into semantic_private.source_text_evidence
    (user_id, observation_id, encrypted_text, encryption_key_version,
     retention_class, expires_at)
  values (alice, obs, '\x02'::bytea, 'probe-key-v1', 'provider_catalog_text',
          now() + interval '30 days')
  returning id into probe;
  perform semantic_private.sweep_expired_source_text();
  select count(*) into n from semantic_private.source_text_evidence
   where id = probe and refresh_status = 'current' and encrypted_text is not null;
  if n <> 1 then
    raise exception
      '0246: the sweep redacted a row whose retention window is still open';
  end if;

  -- Rerunning is a no-op rather than an error.
  perform semantic_private.sweep_expired_source_text();

  delete from auth.users where id = alice;
end;
$$;
