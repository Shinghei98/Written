-- 0433 — the reader learns the new kind.
--
-- **The owner's TRAVEL card was empty because the reader never heard
-- of cities.** `api.list_memories_snapshot` (0424) allowlists item
-- kinds — the `list_assertions` discipline: a new kind is withheld
-- until somebody decides it belongs — and 0430 introduced
-- `visited_city` without deciding. The snapshot held the cities all
-- along; the RPC filtered every one. A user with only cities (the
-- owner, after the tour moved to `other`) received nothing at all.
--
-- The decision, now made: `visited_city` is exactly what the surface
-- exists to show, and it joins the allowlist.

begin;

create or replace function api.list_memories_snapshot()
returns table(item_key text, item_kind text, display_label text,
              display_payload jsonb, rank integer)
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select i.item_key, i.item_kind, i.display_label, i.display_payload,
         i.rank
    from semantic_private.memories_snapshot_items i
    join semantic_private.memories_snapshots s
      on s.id = i.snapshot_id and s.user_id = i.user_id
   where i.user_id = auth.uid()
     and s.state = 'ready'
     and i.item_kind in ('visited_city',
                         'scheduled_travel_candidate',
                         'booked_activity_candidate')
   order by i.rank;
end;
$function$;

commit;
