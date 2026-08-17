-- 0216 — the worker may read the link it resolves through.
--
-- ## What happened
--
-- `0215` published resolver `0.11.0` and enqueued a recompute per account. One
-- succeeded and three failed:
--
--     {"job_failed": {"job_type": "recompute_user",
--                     "error_type": "InsufficientPrivilege", "sqlstate": "42501",
--                     "denied": "permission denied for table external_concept_links"}}
--
-- The ISRC route joins an observation's identifier to a recording concept
-- *through* `ontology.external_concept_links` — deliberately, because parsing
-- `recording:isrc_<x>` back into an ISRC would be a second place encoding the
-- naming scheme. `semantic_worker` holds no select on that table.
--
-- ## The rule this broke, which was already written down
--
-- *"Read the grants first, not sixth. `semantic_worker` is `bypassrls`, and that
-- is not a grant."* Five ontology tables were checked before the route was
-- written — `concepts`, `concept_revisions`, `concept_labels`, `versions`,
-- `external_entities` — all readable, and the sixth was never asked about.
-- `bypassrls` makes row policies irrelevant and says nothing about table
-- privileges, which is exactly the confusion that makes this class of failure
-- feel impossible right up until it happens.
--
-- Asked properly this time, of the whole schema rather than of one table: six of
-- nineteen `ontology` tables are unreadable by the worker. Only this one is
-- needed, and the others stay unreadable — a grant is not tidied up in passing.
--
-- ## And the diagnostic earned its keep
--
-- The failure surfaced as one line naming the table. The same job failing four
-- hours ago produced `handler_error` in the queue row and *nothing whatever* in
-- CloudWatch, and cost a round of guessing. That shim shipped this afternoon and
-- has now paid for itself twice.

begin;

grant select on ontology.external_concept_links to semantic_worker;

do $$
declare
  readable integer;
begin
  if not has_table_privilege('semantic_worker', 'ontology.external_concept_links', 'SELECT') then
    raise exception '0216: the worker still cannot read external_concept_links';
  end if;

  -- **Read, and nothing else.** The worker resolves through these links; it has
  -- no business writing one. Minting a link is the mint's authority, and the
  -- mint runs as a `security definer` function rather than as this role.
  if has_table_privilege('semantic_worker', 'ontology.external_concept_links', 'INSERT')
     or has_table_privilege('semantic_worker', 'ontology.external_concept_links', 'UPDATE')
     or has_table_privilege('semantic_worker', 'ontology.external_concept_links', 'DELETE') then
    raise exception '0216: the worker gained more than select on external_concept_links';
  end if;

  -- **The five that stay shut, asserted rather than assumed.** A grant added to
  -- fix one query is exactly where an unrelated table gets swept along.
  select count(*) into readable
    from (values ('concept_embeddings_384'), ('edge_proposals'),
                 ('external_entity_sources'), ('motif_rules'),
                 ('youtube_channel_resolutions')) as t(name)
   where has_table_privilege('semantic_worker', 'ontology.' || t.name, 'SELECT');
  if readable <> 0 then
    raise exception '0216: % ontology table(s) became readable that should not have', readable;
  end if;

  raise notice '0216: the worker reads external_concept_links and nothing new besides';
end;
$$;

commit;
