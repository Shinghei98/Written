-- 0458 — a witness the function could not see is still a witness.
--
-- **The rule was right and its reader was half-blind.** "YouTube may
-- raise a concept's strength and may never be the only reason it
-- crosses to another user" — and `concept_has_non_video_witness` read
-- only `observation_mappings` within the scoring run. Terms that arrive
-- through the mention lane carry their evidence in
-- `candidate_support_links` instead, so a work supported by Spotify OST
-- tracks — a non-video channel by the rule's own definition — answered
-- `witness = false` and was withheld, while a musically identical term
-- that happened to hold in-run mappings crossed. Measured: one user's
-- Final Fantasy VII Rebirth, eligible on Spotify evidence, 0 in-run
-- mappings, withheld; Where Winds Meet, 15 in-run mappings, crossed.
--
-- The fix teaches the witness the second evidence route, under the same
-- discipline: the support links counted are the ones behind the user's
-- own resolved candidate for exactly this concept — the evidence the
-- claim stands on, not a fuzzy near-miss — and the test is still the
-- channel (`independence_group <> 'video'`), so a YouTube-only mention
-- term remains withheld exactly as before. Nothing weakens: the
-- function answers true in strictly more of the cases the rule itself
-- says it should.

begin;

CREATE OR REPLACE FUNCTION semantic_private.concept_has_non_video_witness(p_semantic_run_id uuid, p_concept_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
      from semantic_private.observation_mappings om
      join semantic_private.observations o on o.id = om.observation_id
      join semantic_private.sources s on s.source_code = o.source_code
     where om.semantic_run_id = p_semantic_run_id
       and om.concept_id = p_concept_id
       -- A candidate is a fuzzy near-miss the scorer discards; reading one as a
       -- witness would let a mis-match license disclosure.
       and om.mapping_state = 'accepted'
       -- `video` is YouTube's group in `sources`. Named rather than joined to a
       -- provider so a future second video source falls under the rule
       -- automatically: the restriction is about the channel of evidence.
       and s.independence_group <> 'video'
  )
  -- 0458: the mention lane's evidence route. The links counted belong to
  -- the run's own user's candidate resolved to exactly this concept —
  -- the support the claim stands on — and the test is the same channel
  -- test as above.
  or exists (
    select 1
      from semantic_private.semantic_runs run
      join semantic_private.user_term_candidates tc
        on tc.user_id = run.user_id and tc.concept_id = p_concept_id
      join semantic_private.candidate_support_links l
        on l.candidate_id = tc.id and l.user_id = tc.user_id
      join semantic_private.observations o on o.id = l.observation_id
      join semantic_private.sources s on s.source_code = o.source_code
     where run.id = p_semantic_run_id
       and s.independence_group <> 'video'
  );
$function$;

commit;
