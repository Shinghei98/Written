-- 0447 — an accent is not a different event.
--
-- **0446's boundary fix un-matched Chichén Itzá**: the concept label's
-- normalized form is unaccented while the filed ticket text keeps its
-- accents, so the whole-phrase comparison called them strangers — the
-- exact class 0423 fixed for the journey builder, met again one lane
-- over. Scorer 0.24.2 folds accents on both sides of the booked-event
-- match. The retired assertion needs no hand repair: it re-scores under
-- the corrected read and revives, which is what "retiring is not
-- deleting" is for.

begin;

do $$
declare old_row ontology.model_versions%rowtype;
begin
  select * into old_row from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc limit 1;
  if old_row.id is null then
    raise notice '0447: no active scorer stands; the model rows wait';
  else
    update ontology.model_versions set status = 'retired'
     where id = old_row.id;
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), old_row.model_key,
            '0.24.2', 'scorer', 'active',
            coalesce(old_row.parameters, '{}'::jsonb)
              || jsonb_build_object('booked_events_match',
                   'whole-phrase on word boundaries, accents folded on '
                   || 'both sides'));
  end if;
end;
$$;

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0447: booked-event names fold accents before they match');
end;
$$;

commit;
