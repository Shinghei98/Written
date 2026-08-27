-- 0445 — a ticket says what the evening was about.
--
-- **The events half of the dynamic bio (owner, 2026-08-28).** 0157
-- designed `booked_public_event_about` and the scorer has carried its
-- scoring query since — but nothing ever CREATED such an assertion,
-- and the predicate was never registered, so the foreign key would
-- have refused one anyway. Two halves land together:
--
--   * the predicate joins the registry — `user_claim`, assertion-safe,
--     zero inference hops and zero propagation: what a ticket names is
--     asserted about the person and conducts nowhere else;
--   * scorer 0.24.0 gains `assert_booked_events` (`assert_travel`'s
--     shape): one assertion per (user, concept) whose active label
--     appears whole in a booked ticket's filed text — works and
--     creators only, the same containment read the scoring query has
--     always trusted. The FF VII Rebirth concert asserts FINAL FANTASY
--     VII; the categorizer then reads it by kind, so it needs no new
--     sentence — a concert about a game is a game term with a booking
--     behind it.
--
-- The recompute is enqueued; the demotion sweep's list gains the
-- predicate in the same scorer version, so an assertion whose bookings
-- expire retires by the normal machinery.

begin;

insert into ontology.relation_types (
  predicate_key, relation_class, inverse_predicate_key, is_symmetric,
  transitive_for_inference, max_inference_hops, assertion_safe,
  description, propagation_weight, reverse_propagation_weight,
  minimum_propagation_authority, minimum_relation_confidence,
  may_propagate_user_predicates, registry_version)
select 'booked_public_event_about', 'user_claim', null, false,
       false, 0, true,
       'The person booked an event about this concept. Asserted only '
       || 'from booked-ticket evidence naming the concept; never from '
       || 'viewing, and conducts no propagation.',
       0, 0, 'verified', 0.65, '{}', 'predicate-v1'
 where not exists (select 1 from ontology.relation_types
                    where predicate_key = 'booked_public_event_about');

do $$
declare old_row ontology.model_versions%rowtype;
begin
  select * into old_row from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc limit 1;
  if old_row.id is null then
    raise notice '0445: no active scorer stands; the model rows wait';
  else
    update ontology.model_versions set status = 'retired'
     where id = old_row.id;
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), old_row.model_key,
            '0.24.0', 'scorer', 'active',
            coalesce(old_row.parameters, '{}'::jsonb)
              || jsonb_build_object('booked_events',
                   'asserts booked_public_event_about per concept a booked '
                   || 'ticket names (works and creators, whole-label '
                   || 'containment); strength n/(n+1), confidence 0.8'));
  end if;
end;
$$;

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0445: booked tickets assert what the evening was about');
end;
$$;

commit;
