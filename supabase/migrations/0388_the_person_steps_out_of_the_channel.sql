-- 0388 — the person steps out of the channel, by rename.
--
-- **The owner, 2026-08-25: a channel cleanly representing a person shows
-- only the person.** The first form moved assertions and met the run-FK:
-- an inferred assertion's (run, user, version) triple is indivisible, so a
-- fold cannot move run-sourced claims across versions. The rename needs
-- no surgery: the standing concept's preferred label becomes the person's
-- name (channel decoration stripped — ちゃんねる/チャンネル/Channel), the
-- channel title survives as an alternate label, every assertion and
-- mapping stays exactly where it is. The two-term structure with
-- `official_channel_of` arrives with the v21 corpus, where the extractor
-- emits both from the start; today's repair is display-true and
-- lineage-safe. Identity-gated: a stripped name already naming another
-- concept refuses (counted), never merges by rename.

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  pair record;
  renamed integer := 0;
  refused integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  create temporary table _channels on commit drop as
  select c.id as concept_id, c.concept_key,
         r.preferred_label as channel_label,
         btrim(regexp_replace(r.preferred_label,
           '^(ちゃんねる|チャンネル|[Cc]hannel)\s*', '')) as person_name
    from ontology.concepts c
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = old_version_id
     and r.status = 'active'
   where c.retired_at is null and r.concept_kind = 'creator'
     and r.preferred_label ~ '^(ちゃんねる|チャンネル|[Cc]hannel)\s*\S'
     and btrim(regexp_replace(r.preferred_label,
           '^(ちゃんねる|チャンネル|[Cc]hannel)\s*', '')) <> '';

  if not exists (select 1 from _channels) then
    raise notice '0388: no channel-decorated names stand; the rule waits for the corpus';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Channel-decorated person names read as the person.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  for pair in select * from _channels loop
    if exists (
      select 1 from ontology.concept_labels l
       where l.ontology_version_id = new_version_id and l.status = 'active'
         and l.normalized_label = lower(btrim(pair.person_name))
         and l.concept_id <> pair.concept_id) then
      refused := refused + 1;
      raise notice '0388: % refused — % already names another concept',
        pair.concept_key, pair.person_name;
      continue;
    end if;

    update ontology.concept_revisions
       set preferred_label = pair.person_name
     where ontology_version_id = new_version_id
       and concept_id = pair.concept_id and status = 'active';

    insert into ontology.concept_labels (
      ontology_version_id, concept_id, label, normalized_label, locale,
      label_type, provenance_type, confidence, status, external_ref)
    values (new_version_id, pair.concept_id, pair.person_name,
            lower(btrim(pair.person_name)), 'und', 'preferred', 'learned',
            0.9, 'active',
            jsonb_build_object('channel_title', pair.channel_label))
    on conflict do nothing;

    renamed := renamed + 1;
    raise notice '0388: % now reads %', pair.concept_key, pair.person_name;
  end loop;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || renamed || ' channel name(s) read as their people');
  raise notice '0388: % published — % renamed, % refused', next_version, renamed, refused;
end;
$$;

commit;
