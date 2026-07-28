-- What `replace_source_records` became once nothing was allowed to be deleted.
--
-- The old function opened with
--
--     delete from public.distilled_records
--      where user_id = auth.uid() and source = p_source;
--
-- which made a re-distillation destroy the one before it. That line is the whole
-- difference. Renamed rather than edited in place, because a function still
-- called *replace* that quietly appends is the kind of thing that gets trusted
-- at a glance and audited never.

create function public.append_source_records(
    p_source  text,
    p_records jsonb
) returns integer
language plpgsql
security invoker            -- runs as the caller, so RLS still applies
as $$
declare
    inserted integer;
    -- One stamp for the whole run, which is the point of the column. Taken once
    -- into a variable rather than calling `now()` per row: it is stable within a
    -- transaction anyway, but reading it once says so, and `source_connections`
    -- below has to agree with it exactly for the two to line up.
    run_at timestamptz := now();
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
    -- Still needed, and now only for collisions *within* a run: a source can
    -- hand back the same item twice across endpoints — a song that is both a
    -- top track and in a playlist. Across runs there is no collision any more,
    -- because `distilled_at` differs, which is the entire change.
    on conflict (user_id, source, data_type, item_id, distilled_at) do nothing;

    get diagnostics inserted = row_count;

    -- Current state rather than history: the history is every distinct
    -- `distilled_at` in the table above. `connected_at` keeps its original value
    -- on conflict, so it stays the first time this source was ever connected.
    insert into public.source_connections (user_id, source, connected_at, last_distilled_at, record_count)
    values (auth.uid(), p_source, run_at, run_at, inserted)
    on conflict (user_id, source) do update
        set last_distilled_at = run_at, record_count = excluded.record_count;

    return inserted;
end;
$$;

comment on function public.append_source_records(text, jsonb) is
    'Appends a distillation run. Never deletes. Replaces replace_source_records, which did.';
