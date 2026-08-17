-- 0212 — a verdict belongs to the vocabulary that reached it.
--
-- `0211` did half of re-resolution and the half it did was the visible one.
--
-- It taught the resolver's *pending* query to ask whether a mention had been
-- judged against the ontology version currently published, so a new version
-- makes old negatives pending again. That part works. But
-- `mention_resolutions_one_per_route` is still
-- `unique (mention_id, resolver_version, route_id)` — no ontology version in it
-- — so the moment the resolver tried to write the new verdict, the row
-- recording the *old* one conflicted it away. `on conflict do nothing` did
-- exactly what it says, again.
--
-- The symptom was precise and would have been easy to misread: the job
-- succeeded, reported `item_count: 0`, and left `evaluated_ontology_version_id`
-- null on every row. A pipeline that runs, reports success and writes nothing.
--
-- **A verdict is scoped to the vocabulary it was reached against**, so that is
-- what the key says. Same mention, same route, same resolver, different
-- ontology version is a different question and gets a different row —
-- and `current_mention_resolutions` already returns the newest, so nothing
-- downstream sees both.
--
-- The existing rows are backfilled rather than left null. Every one was written
-- today against `0.33.0`, which is verified below rather than assumed: a null
-- would sit outside the new constraint entirely, since nulls do not conflict,
-- and the first re-resolution would silently double every historical row.

begin;

do $$
declare
  published uuid;
  published_when timestamptz;
  earliest timestamptz;
  backfilled integer;
begin
  select v.id, coalesce(v.published_at, v.created_at)
    into published, published_when
    from ontology.versions v where v.status = 'published';

  select min(created_at) into earliest
    from semantic_private.mention_resolutions
   where evaluated_ontology_version_id is null;

  if earliest is not null and earliest < published_when then
    -- Some existing verdict predates the published version, so it was reached
    -- against something else and this migration cannot say what. Refusing is
    -- right: guessing would attribute a verdict to vocabulary that did not
    -- exist when it was made.
    raise exception
      '0212: a resolution from % predates the published version (%); backfill '
      'cannot attribute it', earliest, published_when;
  end if;

  update semantic_private.mention_resolutions
     set evaluated_ontology_version_id = published
   where evaluated_ontology_version_id is null;
  get diagnostics backfilled = row_count;
  raise notice '0212: attributed % existing verdict(s) to the published version',
    backfilled;
end;
$$;

alter table semantic_private.mention_resolutions
  alter column evaluated_ontology_version_id set not null;

alter table semantic_private.mention_resolutions
  drop constraint mention_resolutions_one_per_route;

alter table semantic_private.mention_resolutions
  add constraint mention_resolutions_one_per_route_and_vocabulary
  unique (mention_id, route_id, resolver_version, evaluated_ontology_version_id);

do $$
declare
  nulls integer;
begin
  select count(*) into nulls from semantic_private.mention_resolutions
   where evaluated_ontology_version_id is null;
  if nulls <> 0 then
    raise exception '0212: % verdict(s) still name no vocabulary', nulls;
  end if;

  -- **The key must now separate what it previously merged.** Asked of the
  -- catalog rather than assumed from the statement above, and asked both ways:
  -- the old constraint gone, the new one present and naming the version.
  if exists (select 1 from pg_constraint
              where conname = 'mention_resolutions_one_per_route') then
    raise exception '0212: the version-blind key survives';
  end if;
  if not exists (
    select 1 from pg_constraint
     where conname = 'mention_resolutions_one_per_route_and_vocabulary'
       and pg_get_constraintdef(oid) like '%evaluated_ontology_version_id%') then
    raise exception '0212: the new key does not name the evaluated vocabulary';
  end if;

  raise notice '0212: a verdict is now scoped to the vocabulary that reached it';
end;
$$;

commit;
