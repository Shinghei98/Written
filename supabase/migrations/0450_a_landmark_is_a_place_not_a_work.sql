-- 0450 — a landmark is a place, not a work.
--
-- **The v21 recompute stopped on one floating concept**: Chichén Itzá,
-- filed as kind `work` by an early extraction reading a tour ticket,
-- reaches no block — a Mayan landmark has no genre to climb — and
-- `attach_kept_concept_parents` rightly refuses to ship a floating
-- concept rather than filing it somewhere false. The fix is the type,
-- not a cosmetic parent: the site is a place, retyped through the
-- version discipline. Its `booked_public_event_about` assertion
-- retires by the normal machinery (the booked-events scorer asserts
-- works and creators only), and the evening it came from is already
-- carried by the Cancún trip and the booked-event card.

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  target uuid;
begin
  select id into target from ontology.concepts
   where concept_key = 'work:chich_n_itz';
  if target is null then
    raise notice '0450: no such concept on this database; nothing to retype';
    return;
  end if;

  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          '0450: Chichén Itzá retypes to place');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  update ontology.concept_revisions
     set concept_kind = 'place'
   where concept_id = target
     and ontology_version_id = new_version_id
     and status = 'active';

  perform ontology.publish_version(new_version_id);
  raise notice '0450: % published; the landmark is a place', next_version;
end;
$$;

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0450: the landmark is a place; the attach pass floats nothing');
end;
$$;

commit;
