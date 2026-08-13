-- 0137 — the worker may read the channel catalogue.
--
-- **`0136` shipped a resolver that reads a table its own role cannot see.**
-- The deployed worker answered `42501 permission denied for table
-- youtube_channels` on every job, three times, before this was noticed — which
-- is the defect `0086`–`0090` already paid for five times over: *"When a
-- migration needs a grant, read `pg_trigger` for the tables being written and
-- follow what each trigger calls… That should be the first move, not the
-- sixth."* It was not the first move here either.
--
-- **`semantic_worker` is `bypassrls`, and that is not a grant.** Bypassing
-- row-level security says nothing about table privileges, so the role reads
-- `ontology.versions`, `concepts` and `concept_labels` only because `0043`
-- granted them by name. `youtube_channels` arrived in `0045` and was never
-- added to that list, because until `0136` nothing read it.
--
-- Select only. The catalogue is written by migrations and by the
-- `resolve_youtube_channel` job that does not yet exist; a resolver that could
-- write it could name a channel whatever it liked.

begin;

grant select on ontology.youtube_channels to semantic_worker;

do $$
begin
  -- **Asked of the role, not of `information_schema`.** That view shows only
  -- what the *querying* role may see, so it answers empty for this schema and
  -- would have made a missing grant look like a present one.
  if not has_table_privilege('semantic_worker', 'ontology.youtube_channels', 'select') then
    raise exception 'semantic_worker still cannot read ontology.youtube_channels';
  end if;

  -- The rest of the path the resolver walks, asserted together so the next
  -- missing grant is found here rather than in CloudWatch.
  if not (
    has_schema_privilege('semantic_worker', 'ontology', 'usage')
    and has_table_privilege('semantic_worker', 'ontology.versions', 'select')
    and has_table_privilege('semantic_worker', 'ontology.concepts', 'select')
    and has_table_privilege('semantic_worker', 'ontology.concept_labels', 'select')
    and has_table_privilege('semantic_worker', 'semantic_private.observations', 'select')
  ) then
    raise exception 'the resolver''s read path is not fully granted to semantic_worker';
  end if;

  -- It must not be able to *change* the catalogue.
  if has_table_privilege('semantic_worker', 'ontology.youtube_channels', 'insert')
     or has_table_privilege('semantic_worker', 'ontology.youtube_channels', 'update')
     or has_table_privilege('semantic_worker', 'ontology.youtube_channels', 'delete') then
    raise exception 'semantic_worker may write the channel catalogue; it may only read it';
  end if;

  raise notice '0137: semantic_worker may read ontology.youtube_channels, and only read it';
end
$$;

commit;
