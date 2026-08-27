-- 0446 — a name inside another name is not named.
--
-- **The first booked-event mint proved the containment test too loose**:
-- substring matching asserted the band Chic from a Chichén Itzá ticket
-- and Final Fantasy VI from a Final Fantasy VII one. Scorer 0.24.1
-- matches whole phrases on word boundaries (both sides collapsed to
-- alphanumeric words) — "final fantasy vi" no longer matches inside
-- "final fantasy vii", and "chic" no longer matches inside "chichén".
-- The false assertions need no repair by hand: they will not re-score
-- under the corrected read, and the demotion sweep retires an
-- unscored booked assertion by the normal machinery.

begin;

do $$
declare old_row ontology.model_versions%rowtype;
begin
  select * into old_row from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc limit 1;
  if old_row.id is null then
    raise notice '0446: no active scorer stands; the model rows wait';
  else
    update ontology.model_versions set status = 'retired'
     where id = old_row.id;
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), old_row.model_key,
            '0.24.1', 'scorer', 'active',
            coalesce(old_row.parameters, '{}'::jsonb)
              || jsonb_build_object('booked_events_match',
                   'whole-phrase on word boundaries, both sides collapsed '
                   || 'to alphanumeric words'));
  end if;
end;
$$;

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0446: booked-event names match whole, never inside another name');
end;
$$;

commit;
