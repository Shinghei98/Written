-- 0388 — the person steps out of the channel.
--
-- **The owner, 2026-08-25: "if the channel can be cleanly represented by a
-- person, only show the person; the framework always searches for the
-- person behind a channel, mints them, and a predicate connects the two."**
-- The corpus rule is staged for v21; this repairs what already stands:
-- kept concepts whose name is a channel-decorated person name —
-- ちゃんねる宮脇咲良, チャンネルX, "X Channel" — where the decoration strips
-- to a person cleanly.
--
-- Per pair: the channel concept keeps its channel name and gains
-- `official_channel_of -> person`; the person concept is found (a concept
-- already carrying the stripped name) or minted (identity-gated: the
-- stripped name may claim nothing else); the user's assertion moves to
-- the person, so only the person shows. Ambiguity refuses; a stripped
-- name that is not person-shaped (contains spaces of a title, etc.) is
-- skipped and counted, never guessed.

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  pair record;
  handled integer := 0;
  person_id uuid;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  create temporary table _channels on commit drop as
  select c.id as channel_id, c.concept_key as channel_key,
         r.preferred_label as channel_label,
         btrim(regexp_replace(r.preferred_label,
           '^(ちゃんねる|チャンネル|[Cc]hannel)\s*', '')) as person_name
    from ontology.concepts c
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = old_version_id
     and r.status = 'active'
   where c.retired_at is null
     and r.concept_kind = 'creator'
     and r.preferred_label ~ '^(ちゃんねる|チャンネル|[Cc]hannel)\s*\S'
     and btrim(regexp_replace(r.preferred_label,
           '^(ちゃんねる|チャンネル|[Cc]hannel)\s*', '')) <> '';

  if not exists (select 1 from _channels) then
    raise notice '0388: no channel-decorated person names stand; the rule waits for the corpus';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'The person steps out of the channel: decorated channel names yield their people.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  for pair in select * from _channels loop
    -- Find the person: an existing concept already named exactly this.
    select c2.id into person_id
      from ontology.concept_labels l
      join ontology.concepts c2 on c2.id = l.concept_id
     where l.ontology_version_id = new_version_id and l.status = 'active'
       and l.normalized_label = lower(btrim(pair.person_name))
       and c2.id <> pair.channel_id and c2.retired_at is null
     limit 1;

    if person_id is null then
      -- Mint, identity-gated: the key may claim nothing.
      if exists (select 1 from ontology.concepts
                  where concept_key = 'creator:' ||
                    btrim(regexp_replace(lower(pair.person_name),
                                         '[^a-z0-9À-￿]+', '_', 'g'), '_')) then
        raise notice '0388: % skipped — key collision on %',
          pair.channel_key, pair.person_name;
        continue;
      end if;
      insert into ontology.concepts (id, concept_key)
      values (extensions.gen_random_uuid(),
              'creator:' || btrim(regexp_replace(lower(pair.person_name),
                                                 '[^a-z0-9À-￿]+', '_', 'g'), '_'))
      returning id into person_id;
      insert into ontology.concept_revisions (
        ontology_version_id, concept_id, preferred_label, concept_kind,
        definition, sensitivity, inference_policy, status, metadata)
      values (new_version_id, person_id, pair.person_name, 'creator', null,
              'ordinary', 'review_required', 'active',
              jsonb_build_object('origin', '0388_person_from_channel',
                                 'channel', pair.channel_key));
      insert into ontology.concept_labels (
        ontology_version_id, concept_id, label, normalized_label, locale,
        label_type, provenance_type, confidence, status, external_ref)
      values (new_version_id, person_id, pair.person_name,
              lower(btrim(pair.person_name)), 'und', 'preferred', 'learned',
              0.9, 'active', '{}'::jsonb);
    end if;

    -- The predicate connecting the two.
    insert into ontology.concept_edges (
      ontology_version_id, subject_concept_id, predicate_key,
      object_concept_id, confidence, provenance_type, provenance, status)
    select new_version_id, pair.channel_id, 'official_channel_of', person_id,
           0.9, 'learned',
           jsonb_build_object('source', '0388_person_from_channel'), 'active'
    where exists (select 1 from ontology.relation_types
                   where predicate_key = 'official_channel_of')
    on conflict do nothing;

    -- Only the person shows: the assertion moves (or retires if the
    -- person is already claimed under the predicate).
    update semantic_private.user_assertions a
       set machine_state = 'inactive', updated_at = now()
     where a.concept_id = pair.channel_id
       and exists (select 1 from semantic_private.user_assertions w
                    where w.user_id = a.user_id and w.concept_id = person_id
                      and w.predicate_key = a.predicate_key);
    update semantic_private.user_assertions a
       set concept_id = person_id,
           created_ontology_version_id = new_version_id
     where a.concept_id = pair.channel_id
       and not exists (select 1 from semantic_private.user_assertions w
                        where w.user_id = a.user_id and w.concept_id = person_id
                          and w.predicate_key = a.predicate_key);

    handled := handled + 1;
    raise notice '0388: % -> person %', pair.channel_key, pair.person_name;
  end loop;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || handled || ' person(s) stepped out of channels');
  raise notice '0388: % published — % channel(s) handled', next_version, handled;
end;
$$;

commit;
