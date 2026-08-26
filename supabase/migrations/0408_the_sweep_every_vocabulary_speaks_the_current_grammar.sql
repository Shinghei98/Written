-- 0408 — the sweep: every vocabulary speaks the current grammar.
--
-- **The owner ordered the sweep (2026-08-26) after 0407's find.** Every
-- check constraint encoding a vocabulary was enumerated and cross-diffed
-- against its siblings. Two more drifts, same disease as the role
-- catalog — a literal list copied once and never revisited:
--
-- 1. **`provisional_entities.family`** lacked `art` and `field`.
--    (`unknown` deliberately stays out: the compiled contract requires
--    every provisional family to carry a cardinal-root mapping, and
--    `unknown` is a hold, not an identity — the ladder's tier-5 holds
--    through `identity_state = 'ambiguous'`, never through a family.
--    The gate caught the first draft claiming otherwise.)
-- 2. **`candidate_relation_proposals.predicate`** still spoke the
--    13-predicate list, so the 0374 promotion lane could never propose
--    0398's typed predicates (`signed_to_label`, `work_in_collection`,
--    `platform_of`) into the catalogue. Aligned with
--    `presumed_term_relations_predicate_check`.
--
-- Checked clean in the same sweep, for the record: the surface lists
-- agree across their three tables; `model_cardinal` matches the eight
-- Cardinal roots; the relation registry carries all sixteen predicates;
-- `worker_jobs.job_type` is a deliberate superset. The mention role
-- `durable_activity_or_idea` keeps its name — a wire-contract string on
-- an append-only table is history, not vocabulary.

begin;

alter table semantic_private.provisional_entities
  drop constraint provisional_entities_family_check;
alter table semantic_private.provisional_entities
  add constraint provisional_entities_family_check
  check (family = any (array[
    'activity','album','anime','art','book','channel','culture','event',
    'event_type','field','franchise','game','game_category','group','hub',
    'music_recording','music_work','organization','person','place',
    'platform','sport','tour','work']));

alter table semantic_private.candidate_relation_proposals
  drop constraint candidate_relation_proposals_predicate_check;
alter table semantic_private.candidate_relation_proposals
  add constraint candidate_relation_proposals_predicate_check
  check (predicate = any (array[
    'part_of_franchise','features','about','performed_by','composed_by',
    'recording_of','soundtrack_of','member_of_group','played_for',
    'official_channel_of','represented_team_in','located_in','broader',
    'signed_to_label','work_in_collection','platform_of']));

do $$
begin
  raise notice '0408: family and predicate vocabularies aligned across their tables';
end;
$$;

commit;
