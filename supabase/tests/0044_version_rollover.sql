-- Adapted from the v0.3.1 reference `sql/tests/001_version_rollover.sql`.
-- Gates application migration 0044.
--
-- The reference chain numbers its files 001-006 while this repository's
-- are 0042-0047, so contract numbering is off by two and the two
-- fixture lanes are off by one -- reference fixture `004` gates the
-- app's 0046, and reference fixture `005` gates 0047. The file name
-- states which migration it gates so nobody re-derives that each time.
--
-- Substituted from the reference: 0 `private.` -> `semantic_private.`
-- and 0 bare `'private'` schema arguments. Privacy-class VALUES
-- such as `'private_text'` are deliberately untouched: they are
-- check-constraint values, not schema names, and rewriting them is how
-- a mechanical rename corrupts a contract while still passing.

-- Run after 001_schema.sql, 002_rls_and_rpc.sql, and 003_seed.sql.
-- The transaction is rolled back so the test does not alter the active seed.
begin;

do $$
declare
  old_version_id uuid;
  new_version_id uuid := ontology.stable_uuid('written:test:ontology:v0.2.0');
  old_published_at timestamptz;
  retained_published_at timestamptz;
  published_count integer;
begin
  select id, published_at into old_version_id, old_published_at
  from ontology.versions
  where status = 'published';
  if old_version_id is null or old_published_at is null then
    raise exception 'test requires one published seed version';
  end if;

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (new_version_id, 'test-0.2.0', old_version_id, 'draft', 'rollover integration test');

  perform ontology.publish_version(new_version_id);

  select published_at into retained_published_at
  from ontology.versions
  where id = old_version_id and status = 'retired';
  if retained_published_at is distinct from old_published_at then
    raise exception 'retired version lost its original publication timestamp';
  end if;

  if not exists (
    select 1 from ontology.versions
    where id = new_version_id and status = 'published' and published_at is not null
  ) then
    raise exception 'new version was not published';
  end if;

  select count(*) into published_count
  from ontology.versions
  where status = 'published';
  if published_count <> 1 then
    raise exception 'expected exactly one published version, found %', published_count;
  end if;

  begin
    update ontology.concept_revisions
    set preferred_label = preferred_label || ' mutation'
    where ontology_version_id = old_version_id;
    raise exception 'retired historical revision unexpectedly allowed mutation';
  exception
    when raise_exception then
      if sqlerrm = 'retired historical revision unexpectedly allowed mutation' then
        raise;
      end if;
  end;
end;
$$;

rollback;
