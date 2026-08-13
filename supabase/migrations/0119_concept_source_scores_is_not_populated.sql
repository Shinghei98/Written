-- 0119 — say in the database that `concept_source_scores` has no producer.
--
-- **`0117` read this table and answered `false` for every concept alive**,
-- because it holds 0 rows against 14,629 in `concept_scores` and 219,642 in
-- `observation_mappings`. `0118` fixed the predicate. This closes the reason
-- that mistake was available to make.
--
-- **The table is right and must not be dropped.** It is v0.3.1 contract schema
-- (`0042`), and the contract controls where it and this implementation
-- disagree. Its emptiness is deliberate and already recorded in the place that
-- decides such things: `semantic_worker` holds `insert` on `concept_scores` and
-- **not** on this table, and `0057`'s grant list is enumerated and asserted
-- from the catalog at migration time. That absence is a statement.
--
-- **What makes it a trap is that it reads as live.** RLS on (`0043`), a
-- `guard_running` trigger, two further `before insert` triggers and six added
-- columns (`0045`), sixteen columns and constraints throughout. Nothing in the
-- DDL suggests no producer exists, and the only written record of that was
-- CLAUDE.md — which a person querying the database does not read.
--
-- So the fact goes next to the thing it is about. Documentation, not a test:
-- there is nothing behavioural to assert here, and `0117`'s lesson is that an
-- assertion which cannot fail is worse than none, because it reads as coverage.

begin;

comment on table semantic_private.concept_source_scores is
  'NOT POPULATED — 0 rows, and never written as of 2026-08-12. '
  'For any per-channel or per-independence-group question, read '
  'observation_mappings -> observations -> sources.independence_group instead; '
  'that is where aws/worker/score.py''s AGGREGATE takes it from, and what '
  'semantic_private.concept_has_non_video_witness (0118) uses. '
  'The emptiness is deliberate, not an oversight: semantic_worker has insert '
  'on concept_scores and not on this table, and 0057''s grant list is '
  'enumerated and asserted from the catalog. '
  'WHAT IT IS FOR, so Phase 4 need not re-derive it: the per-channel sibling of '
  'concept_scores, keyed (semantic_run_id, concept_id, evidence_channel). It is '
  'derivable from the existing aggregate by adding s.evidence_channel to its '
  'group by, with unique_lineage_count = count(distinct '
  'o.content_lineage_hmac). Populating it belongs to the controlled-explanation '
  'surface (allow_explanation), which needs per-channel provenance; the '
  'per-channel meaning of strength is deliberately undecided until then. '
  'WORKED EXAMPLE: 0117 assumed this table was live and shipped a predicate '
  'that withheld everything.';

comment on table semantic_private.concept_scores is
  'The populated per-concept score: one row per (semantic_run_id, concept_id), '
  'written by aws/worker/score.py. Its per-channel sibling '
  'concept_source_scores exists in the schema and has no producer — see the '
  'comment on that table before reaching for it.';

commit;
