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
-- Set at authoring, by analogy within the registry's own scale, and
-- recorded here as every λ is; the strike lane's Δ-log-odds
-- recalibration owns them from here.

begin;

insert into ontology.relation_types
  (predicate_key, propagation_weight, minimum_relation_confidence)
values
  ('work_in_collection', 0.45, 0.65),
  ('signed_to_label', 0.20, 0.65),
  ('platform_of', 0.00, 0.65)
on conflict (predicate_key) do nothing;

commit;
