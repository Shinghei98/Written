-- 0473 — the resolver asks only the living.
--
-- `resolve_presumed_terms_to_catalogue` links a dictionary term to the
-- catalogue concept whose label it matches. Its candidate set was every
-- revision at the published version, whatever its status — which was the
-- same thing until 0469 and 0470 deprecated hundreds of revisions in place
-- (unpromoted mints, folded shadows, retired franchises) rather than
-- retiring their concepts. The first emit of the v24 corpus (2026-09-08)
-- then matched a term to such a grave on its first promotion and
-- `guard_promotion_targets_living_concept` (0449) refused it, which is
-- exactly what that guard exists to do. The repair belongs one layer
-- earlier: the resolver considers only active revisions, so a grave is not
-- a candidate and cannot be the one match that kind-agreement promotes.
--
-- Behavioural proof is the corpus migration that follows: 0474 calls this
-- resolver over 6,847 terms against a catalogue holding those graves, and
-- reaches its end.
begin;

CREATE OR REPLACE FUNCTION semantic_private.resolve_presumed_terms_to_catalogue()
 RETURNS TABLE(linked integer, ambiguous integer, kind_mismatch integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_linked integer := 0;
  v_ambiguous integer := 0;
  v_mismatch integer := 0;
begin
  create temporary table _candidate on commit drop as
  with published as (
    select lower(btrim(cr.preferred_label)) as label,
           c.id as concept_id,
           split_part(c.concept_key, ':', 1) as prefix
      from ontology.concept_revisions cr
      join ontology.concepts c on c.id = cr.concept_id
     where cr.ontology_version_id =
           (select v.id from ontology.versions v where v.status = 'published')
       -- 0473: a grave is not a catalogue entry. 0469 and 0470 deprecated
       -- hundreds of revisions in place (unpromoted mints, folded shadows)
       -- and this read matched their labels as if they still stood, so the
       -- first v24 emit met `guard_promotion_targets_living_concept` on its
       -- first promotion. The guard was right; this asks only the living.
       and cr.status = 'active'
       and c.retired_at is null
  )
  select t.id as term_id,
         count(distinct p.concept_id)                                as matches,
         count(distinct p.concept_id) filter (where p.prefix = m.key_prefix) as kind_ok,
         -- **`min(uuid)` does not exist in Postgres**, which the first version
         -- of this assumed and the replay refused. Aggregating into an array
         -- and taking the first element is the form that works; it is only ever
         -- read where `kind_ok = 1`, so the array holds exactly one id and the
         -- choice of element is not a tiebreak dressed up as one.
         (array_agg(p.concept_id) filter (where p.prefix = m.key_prefix))[1]
           as concept_id
    from semantic_private.presumed_terms t
    join ontology.family_mint_convention m on m.family = t.family
    join published p
      on p.label = lower(btrim(coalesce(t.english_label, t.canonical_label)))
   where t.promoted_concept_id is null
   group by t.id;

  -- **Ambiguity is counted before anything is written**, so the number means
  -- "refused" rather than "left over after a partial pass".
  select count(*) into v_ambiguous from _candidate where matches > 1;
  select count(*) into v_mismatch  from _candidate where kind_ok = 0;

  update semantic_private.presumed_terms t
     set promoted_concept_id = c.concept_id,
         promoted_at = now()
    from _candidate c
   where c.term_id = t.id
     and c.matches = 1
     and c.kind_ok = 1
     and c.concept_id is not null
     -- Belt and braces against a concurrent writer: the promotion check
     -- constraint pairs the two columns, and this keeps the update idempotent.
     and t.promoted_concept_id is null;
  get diagnostics v_linked = row_count;

  drop table _candidate;
  return query select v_linked, v_ambiguous, v_mismatch;
end;
$function$
;

commit;
