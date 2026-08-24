-- 0335 — a dictionary term carries the heading it was placed under.
--
-- **Measured 2026-08-24, and the reason this column exists.** David's v17 run
-- over 1,540 items placed **374 of 4,003 mentions under a parent — 9.3% — and
-- proposed no new parent once.** The candidate list was not the problem:
-- `creator -> broader -> genre` is the dominant edge in the published tree
-- (2,441 of them), so a composer under `Classical` is exactly what this
-- catalogue does. The model simply answered inconsistently — Chopin took
-- `Classical`, Bach took nothing, off the same list in the same run.
--
-- Asked the same question on its own — one question, two fields, thinking on,
-- the shape `ris_relabel` established — the same model placed **1,269 of 1,284
-- terms, 98.8%**, using 30 of the 40 headings against the extraction's 15, at
-- 22 terms a second. And the placements are specific rather than safe: Bach
-- under **Baroque Era** rather than Classical, Eason Chan under **Cantopop**
-- rather than Mandopop, the Monteverdi Choir under **Choral**. The fifteen it
-- declined are the ones with no home in a list of music headings — Sheldon
-- Cooper, the Marvel Cinematic Universe, Netflix Japan.
--
-- **Eighteen fields in one forward pass is the defect; the field was never the
-- defect.** That is `ris_relabel.py`'s finding on a second problem: v14 stated
-- the native-language rule three ways to no effect, and one narrow question
-- repaired 1,459 labels.
--
-- ## Why a column and not a relation
--
-- `presumed_term_relations` (`0306`) admits `broader`, and both of its ends are
-- `references semantic_private.presumed_terms(id)`. **A heading is a published
-- concept, not a dictionary entry**, so it cannot be the object of that edge
-- without first inventing a dictionary row for something the ontology already
-- holds. Pointing from a term into the ontology is instead the shape
-- `promoted_concept_id` and `canonical_term_id` already use on this table.
--
-- ## What this is not
--
-- **Not a `broader` edge, and nothing traverses it.** The ontology's tree is
-- unchanged; this records where a model said a term would go *if* it were
-- minted. `0258`'s refusal stands until a person decides — *"a user-kept term
-- has no stated parent, and one parented to a guess is a false claim"* — and
-- this is the guess, held where a guess belongs, so that a later mint has
-- something to consult instead of landing every discovered term under "Other".
--
-- **The confidence is stored and is not yet trusted.** Across 1,269 answers it
-- ran min 0.85, median 0.95, max 0.95 — uniformly high, so it separates
-- nothing. It is kept because a later calibration needs the raw number, and it
-- is named `_unvalidated` so no reader mistakes it for a threshold anybody has
-- checked.

alter table semantic_private.presumed_terms
  add column if not exists proposed_parent_concept_id uuid
    references ontology.concepts(id) on delete set null,
  add column if not exists proposed_parent_confidence_unvalidated numeric
    check (proposed_parent_confidence_unvalidated is null
           or proposed_parent_confidence_unvalidated between 0 and 1),
  add column if not exists proposed_parent_source text
    check (proposed_parent_source is null
           or proposed_parent_source in ('extraction', 'placement_pass', 'authored'));

comment on column semantic_private.presumed_terms.proposed_parent_concept_id is
  'The published concept a model said this term belongs under. A proposal, not '
  'an edge: nothing traverses it and the ontology tree is unchanged. 0258 still '
  'refuses to guess an entity''s parent at mint time; this is where the guess '
  'is kept so a later decision has something to read.';

comment on column semantic_private.presumed_terms.proposed_parent_confidence_unvalidated is
  'As stated by the model. Named unvalidated because it is: across 1,269 '
  'placements it ran 0.85 to 0.95 with a median of 0.95, so it separates '
  'nothing and no threshold on it means anything yet.';

comment on column semantic_private.presumed_terms.proposed_parent_source is
  'Which pass placed it. `extraction` is the inline field that answered 9.3% of '
  'the time; `placement_pass` is the narrow second call that answered 98.8%.';

create index if not exists presumed_terms_proposed_parent_idx
  on semantic_private.presumed_terms (proposed_parent_concept_id)
  where proposed_parent_concept_id is not null;

-- ---------------------------------------------------------------------------
-- Proven both ways.
-- ---------------------------------------------------------------------------
-- **A column that only ever accepts is not constrained.** The confidence bound
-- is the only rule here, so it is the one made to answer twice.
do $$
declare
  accepted boolean := false;
  refused  boolean := false;
begin
  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin,
       proposed_parent_confidence_unvalidated, proposed_parent_source)
    values ('0335 probe ok', '0335 probe ok', 'person', 'inferred',
            0.95, 'placement_pass');
    accepted := true;
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then null;
    when check_violation then
      raise exception '0335: a valid placement was refused';
  end;

  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin,
       proposed_parent_confidence_unvalidated, proposed_parent_source)
    values ('0335 probe bad', '0335 probe bad', 'person', 'inferred',
            1.7, 'placement_pass');
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when check_violation then refused := true;
    when sqlstate 'P0001' then null;
  end;

  if not accepted then
    raise exception '0335: the placement columns rejected a valid row';
  end if;
  if not refused then
    raise exception '0335: a confidence above 1 was accepted';
  end if;
end;
$$;
