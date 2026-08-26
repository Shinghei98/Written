-- 0399 — the typed predicates join the λ registry.
--
-- 0398 gave containment its typed vocabulary in the dictionary
-- (`signed_to_label`, `work_in_collection`, `platform_of`). The scorer's
-- traversal reads `ontology.relation_types` — an edge whose predicate has
-- no registry row simply cannot conduct, and the join drops it silently —
-- so the registry decides, per GRAMMARBOOK §2.21, which of the three
-- carry weight the day such edges reach the catalogue:
--
--   - `work_in_collection` 0.45 — owning a work in a cycle speaks for the
--     cycle about as strongly as a work speaks for its franchise
--     (part_of_franchise 0.45), and less than a recording for its work
--     (recording_of 0.55).
--   - `signed_to_label` 0.20 — being on a label says less about the
--     listener than being in a group says about the music
--     (member_of_group 0.25); the label is one step further from taste.
--   - `platform_of` 0.00 — everyone is on the platform; flow here would
--     make YouTube the strongest concept in every library. Registered so
--     the zero is a decision on a row, not an absence.
--
-- Rows take `member_of_group`'s shape (descriptive, one hop, not
-- assertion-safe, `supported` authority, propagating `interested_in`
-- only); `platform_of` tightens to `verified` authority and propagates
-- nothing, its λ being zero either way. Set at authoring, by analogy
-- within the registry's own scale; the strike lane's Δ-log-odds
-- recalibration owns them from here.

begin;

insert into ontology.relation_types
  (predicate_key, relation_class, inverse_predicate_key, is_symmetric,
   transitive_for_inference, max_inference_hops, assertion_safe,
   description, propagation_weight, reverse_propagation_weight,
   minimum_propagation_authority, minimum_relation_confidence,
   may_propagate_user_predicates, registry_version)
values
  ('work_in_collection', 'descriptive', null, false, false, 1, false,
   'A work belongs to a titled collection or cycle.',
   0.45, 0, 'supported', 0.65, array['interested_in'], 'predicate-v2.2'),
  ('signed_to_label', 'descriptive', null, false, false, 1, false,
   'An act records for a named label organization.',
   0.20, 0, 'supported', 0.65, array['interested_in'], 'predicate-v2.2'),
  ('platform_of', 'descriptive', null, false, false, 1, false,
   'Material was published on this platform; carries no taste weight.',
   0.00, 0, 'verified', 0.65, array[]::text[], 'predicate-v2.2')
on conflict (predicate_key) do nothing;

commit;
