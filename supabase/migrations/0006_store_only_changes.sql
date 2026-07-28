-- Keep every distillation, but store only what changed.
--
-- 0004 made the tables append-only, which was right and too literal: distilling
-- YouTube twice in five minutes wrote 553 rows the second time when 552 of them
-- were byte-identical to the 553 already there. The history was real and almost
-- entirely noise, and the one row that mattered — a video liked at 16:05 — was
-- indistinguishable from the 552 that hadn't moved.
--
-- So a row is now written only when it *differs from the newest version of
-- itself*. Every row in these tables therefore marks a change, and
-- `distilled_at` says when that change was first seen rather than when some
-- distillation happened to run.
--
-- Two details carry the whole thing:
--
-- **Compare against the latest version, not against any version.** `exists (…)`
-- over the history would match a value that has since changed and changed back —
-- A → B → A — and silently drop the third state, leaving the summary showing B
-- forever. The comparison has to be against the most recent row for that key.
--
-- **Exclude the timestamps from the comparison.** `collected_at` is stamped per
-- record with `Date()` at distill time and `distilled_at` per run, so both differ
-- on every pass. Comparing them would make every row look changed and defeat the
-- entire mechanism — which is exactly the failure that would be hardest to
-- notice, because it looks like it is working.

-- ---------------------------------------------------------------------------
-- Distilled records
-- ---------------------------------------------------------------------------

create or replace function public.skip_unchanged_distilled_record()
returns trigger
language plpgsql
as $$
declare
    latest public.distilled_records%rowtype;
begin
    -- A primary-key range scan: the key is
    -- (user_id, source, data_type, item_id, distilled_at), so the four equality
    -- columns plus the descending sort is exactly its leading edge.
    select * into latest
      from public.distilled_records d
     where d.user_id   = new.user_id
       and d.source    = new.source
       and d.data_type = new.data_type
       and d.item_id   = new.item_id
     order by d.distilled_at desc
     limit 1;

    if found
       and latest.name           is not distinct from new.name
       and latest.creator        is not distinct from new.creator
       and latest.detail         is not distinct from new.detail
       and latest.extra          is not distinct from new.extra
       and latest.removed_at     is not distinct from new.removed_at
       and latest.removed_reason is not distinct from new.removed_reason
    then
        -- Nothing has changed about this item since it was last seen. Returning
        -- null skips the insert without raising, so a run of 553 unchanged rows
        -- simply writes nothing.
        return null;
    end if;

    return new;
end;
$$;

drop trigger if exists skip_unchanged on public.distilled_records;
create trigger skip_unchanged
    before insert on public.distilled_records
    for each row execute function public.skip_unchanged_distilled_record();

-- ---------------------------------------------------------------------------
-- Derived health
-- ---------------------------------------------------------------------------

-- `updated_at` is excluded for the same reason as the other timestamps: the app
-- sets it to `now()` on every push, so including it would mean no row was ever
-- considered unchanged.
--
-- In practice these will rarely dedupe — `days_observed` slides as the 365-day
-- window moves, and that *is* a change — which is fine. The point is that an
-- identical reading doesn't earn a row.
create or replace function public.skip_unchanged_health_signal()
returns trigger
language plpgsql
as $$
declare
    latest public.health_signals%rowtype;
begin
    select * into latest
      from public.health_signals h
     where h.user_id = new.user_id
     order by h.distilled_at desc
     limit 1;

    if found
       and latest.chronotype_label    is not distinct from new.chronotype_label
       and latest.median_wake_minutes is not distinct from new.median_wake_minutes
       and latest.spread_minutes      is not distinct from new.spread_minutes
       and latest.days_observed       is not distinct from new.days_observed
       and latest.average_daily_steps is not distinct from new.average_daily_steps
       and latest.hourly_activity     is not distinct from new.hourly_activity
    then
        return null;
    end if;

    return new;
end;
$$;

drop trigger if exists skip_unchanged on public.health_signals;
create trigger skip_unchanged
    before insert on public.health_signals
    for each row execute function public.skip_unchanged_health_signal();

create or replace function public.skip_unchanged_health_sport()
returns trigger
language plpgsql
as $$
declare
    latest public.health_sports%rowtype;
begin
    select * into latest
      from public.health_sports h
     where h.user_id = new.user_id and h.sport = new.sport
     order by h.distilled_at desc
     limit 1;

    if found
       and latest.sessions is not distinct from new.sessions
       and latest.minutes  is not distinct from new.minutes
    then
        return null;
    end if;

    return new;
end;
$$;

drop trigger if exists skip_unchanged on public.health_sports;
create trigger skip_unchanged
    before insert on public.health_sports
    for each row execute function public.skip_unchanged_health_sport();

-- ---------------------------------------------------------------------------
-- `record_count` has to mean something different now
-- ---------------------------------------------------------------------------

-- It used to be the size of the run, which under this model is the size of the
-- *diff* — a second distillation five minutes later would report 1, and the
-- garden asking "is this branch grown?" would read that as almost nothing.
--
-- It is now how much is known about the source in total: the summary's count.
-- The function still returns the number of rows actually written, so a caller
-- can tell how much moved.
create or replace function public.append_source_records(
    p_source  text,
    p_records jsonb
) returns integer
language plpgsql
security invoker
as $$
declare
    inserted integer;
    known    integer;
    run_at   timestamptz := now();
begin
    insert into public.distilled_records
        (user_id, source, data_type, item_id, name, creator, detail,
         extra, collected_at, removed_at, removed_reason, distilled_at)
    select
        auth.uid(),
        p_source,
        r ->> 'data_type',
        r ->> 'item_id',
        coalesce(r ->> 'name', ''),
        coalesce(r ->> 'creator', ''),
        coalesce(r ->> 'detail', ''),
        coalesce(r -> 'extra', '{}'::jsonb),
        (r ->> 'collected_at')::timestamptz,
        (r ->> 'removed_at')::timestamptz,
        r ->> 'removed_reason',
        run_at
    from jsonb_array_elements(p_records) as r
    on conflict (user_id, source, data_type, item_id, distilled_at) do nothing;

    get diagnostics inserted = row_count;

    select count(*) into known
      from public.summary_distilled_records s
     where s.user_id = auth.uid() and s.source = p_source;

    insert into public.source_connections (user_id, source, connected_at, last_distilled_at, record_count)
    values (auth.uid(), p_source, run_at, run_at, coalesce(known, 0))
    on conflict (user_id, source) do update
        set last_distilled_at = run_at, record_count = coalesce(known, 0);

    return inserted;
end;
$$;

comment on function public.append_source_records(text, jsonb) is
    'Appends a distillation run, writing only rows that differ from the newest version of themselves. Never deletes. Returns the number of changes written; record_count is the total known.';
