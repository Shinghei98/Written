-- 0361 — the cutoff fit reports before it acts.
--
-- **The iterative half of the owner's design: the cutoff is decided from
-- data, and a decision from data starts as a report somebody reads.** The
-- fitting tool (`tools/fit_memories_cutoff.py`) joins a user's keep/strike
-- outcomes to their surfacing scores per topical hub, proposes a threshold
-- per hub, and writes exactly one row here — the `calibration_dry_run`
-- pattern (0257): compute what a parameter version *would* do, append the
-- report, change nothing. The owner reads the report and hand-approves
-- values into the next `memories_cutoff_releases` row as draft; activation
-- is a separate, deliberate act under 0360's one-active index.
--
-- Append-only by trigger, because a fit that can be rewritten after the
-- release it justified went live is not a record of why the release exists.

begin;

create table semantic_private.memories_cutoff_dry_runs (
  id uuid primary key default gen_random_uuid(),
  proposed_release text not null,
  fitted_for_user uuid,
  -- Per hub: {"hub:music": {"n": ..., "keeps": ..., "strikes": ...,
  --   "proposed_cutoff": ..., "share_before": ..., "share_after": ...}, ...}
  per_hub jsonb not null,
  method text not null,
  notes text,
  created_at timestamptz not null default now()
);

comment on table semantic_private.memories_cutoff_dry_runs is
  'What a proposed Memories cutoff release would do, computed before it '
  'exists (0257''s dry-run pattern). One row per fit; append-only. The '
  'owner approves a report into a draft release by hand — the fit never '
  'writes releases itself.';

create or replace function semantic_private.memories_cutoff_dry_runs_append_only()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  raise exception 'memories_cutoff_dry_runs is append-only';
end;
$$;

create trigger memories_cutoff_dry_runs_append_only
  before update or delete on semantic_private.memories_cutoff_dry_runs
  for each row execute function semantic_private.memories_cutoff_dry_runs_append_only();

-- The worker writes fits; nothing else needs a grant, and no client role
-- can reach the schema.
grant insert, select on semantic_private.memories_cutoff_dry_runs to semantic_worker;

-- Proven both ways, rolled back by raising.
do $$
declare
  probe_id uuid;
  refused boolean := false;
begin
  insert into semantic_private.memories_cutoff_dry_runs
    (proposed_release, per_hub, method)
  values ('0361-probe', '{}'::jsonb, 'probe')
  returning id into probe_id;

  begin
    update semantic_private.memories_cutoff_dry_runs
       set notes = 'rewritten' where id = probe_id;
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception '0361: a dry-run report accepted an update';
  end if;

  refused := false;
  begin
    delete from semantic_private.memories_cutoff_dry_runs where id = probe_id;
  exception when others then
    refused := true;
  end;
  if not refused then
    raise exception '0361: a dry-run report accepted a delete';
  end if;

  raise exception 'rollback the probe' using errcode = 'P0001';
exception
  when sqlstate 'P0001' then
    raise notice '0361: append-only holds both ways';
end;
$$;

do $$
begin
  if exists (select 1 from semantic_private.memories_cutoff_dry_runs
              where proposed_release = '0361-probe') then
    raise exception '0361: the probe report survived its rollback';
  end if;
end;
$$;

commit;
