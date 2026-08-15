-- 0186 — a foreign key with no index behind it.
--
-- ## Found by trying to delete something
--
-- `assertion_evidence` references `observation_mappings (id, user_id)` with
-- `on delete cascade`, and its only index is the primary key
-- `(assertion_score_version_id, observation_mapping_id)`. That index is led by
-- the score version, so a lookup by `observation_mapping_id` alone cannot use
-- it — **every cascade delete is a sequential scan of the whole table.**
--
-- It surfaced pruning superseded runs: a batch of 25,000 mappings exceeded the
-- two-minute statement timeout, and the error named the cause outright —
-- `DELETE FROM ONLY assertion_evidence WHERE $1 = observation_mapping_id AND
-- $2 = user_id`. At 419,390 rows that is 25,000 sequential scans.
--
-- **This is not only a delete problem.** Postgres never creates an index for a
-- referencing key, so the same scan happens on any operation that has to check
-- children of a mapping. It has been free so far because nothing has ever
-- deleted a mapping — the growth this repairs is the growth that hid it.
--
-- ## The columns, in this order
--
-- `(observation_mapping_id, user_id)` matches the foreign key's own column list
-- and its order, which is what the planner needs for the cascade. `user_id`
-- second rather than first because the mapping id is the selective one; leading
-- on the user would give a 3-value prefix on a 419,000-row table.

begin;

create index if not exists assertion_evidence_mapping_idx
  on semantic_private.assertion_evidence (observation_mapping_id, user_id);

do $$
begin
  if not exists (
    select 1 from pg_indexes
     where schemaname = 'semantic_private'
       and tablename = 'assertion_evidence'
       and indexdef ilike '%(observation_mapping_id, user_id)%'
  ) then
    raise exception '0186: the cascade index is absent';
  end if;
end;
$$;

commit;
