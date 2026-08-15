-- 0187 — every key into a mapping has an index behind it.
--
-- ## Why a second migration and not an edit to `0186`
--
-- `0186` indexed `assertion_evidence`'s foreign key into `observation_mappings`
-- after a cascade delete scanned the whole table 25,000 times. The very next
-- batch named a second child: `motif_support`, whose only index is the primary
-- key `(motif_instance_id, observation_mapping_id)` — led by the instance, so
-- again useless for the cascade's lookup.
--
-- **`motif_support` is empty today**, so it cost nothing this time; the
-- statement was cancelled for its total work and the cascade simply named where
-- it stood. That is exactly why this is worth fixing while it is free: the
-- index is missing on the day the table fills, and the symptom then is a
-- timeout in an unrelated delete.
--
-- ## The assertion is the point, and it is general
--
-- Two instances of one defect is a pattern, and the pattern is *Postgres never
-- indexes a referencing key for you*. So rather than name a third table when a
-- third arrives, the check below reads the catalog: **every foreign key
-- referencing `observation_mappings` must have an index on the child whose
-- leading columns are that key's columns, in order.** A future child added
-- without one fails the next replay instead of being found by a timeout.
--
-- The `indkey` comparison is by array prefix rather than equality, because an
-- index carrying extra trailing columns still serves the lookup.

begin;

create index if not exists motif_support_mapping_idx
  on semantic_private.motif_support
     (observation_mapping_id, user_id, semantic_run_id);

do $$
declare
  gap record;
  missing integer := 0;
begin
  for gap in
    select c.conname,
           c.conrelid::regclass::text as child,
           c.conkey
      from pg_constraint c
     where c.contype = 'f'
       and c.confrelid = 'semantic_private.observation_mappings'::regclass
  loop
    if not exists (
      select 1
        from pg_index i
       where i.indrelid = (select conrelid from pg_constraint where conname = gap.conname)
         and (i.indkey::smallint[])[0:array_length(gap.conkey, 1) - 1] = gap.conkey
    ) then
      raise warning '0187: % on % has no index behind it', gap.conname, gap.child;
      missing := missing + 1;
    end if;
  end loop;

  if missing > 0 then
    raise exception '0187: % foreign key(s) into observation_mappings lack an index', missing;
  end if;
end;
$$;

commit;
