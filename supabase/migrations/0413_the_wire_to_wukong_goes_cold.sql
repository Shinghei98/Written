-- 0413 — the wire to Wukong goes cold, and eleven more works find their genres.
--
-- **Two acts from tonight's audits, each carrying only what was verified:**
--
-- 1. **The aespa -> Black Myth: Wukong edge demotes to `candidate`.**
--    The relation audit's doctrine (GRAMMARBOOK 2.22) ran its pair-check
--    to completion: aespa's entities and the game's (Q98582386, unique)
--    hold no claim connecting them in either direction. A completed check
--    finding nothing is the one verdict allowed to demote. The mint
--    stands — identity mints, weight measures — but the wire conducts
--    nothing, and the cutoff removes the game from the page it reached
--    only through the owner's amplified aespa listening.
--    **The 71 other demote-list rows deliberately wait**: the audit's
--    entity resolution mistook namesakes for short names (asa, ruka),
--    and an audit that saw the wrong witness must not rule. They demote
--    only after the refined run records unique resolution on both ends.
--
-- 2. **The widened Wikidata re-ask's assignments land** (rounds 2 and 3
--    — the hub-floored door plus the multi-name search): 14 works,
--    id-to-id through our vocabulary's own QIDs, one-candidate-binds.
--    Loki stays hub-floored for now — two screen candidates, honestly
--    refused, awaiting the tier-2 franchise tie-break.
--
-- Ends with the recompute enqueue (0396's rule; the release-aware
-- 0412 form actually enqueues it).

begin;

do $$
declare
  current_version text;
  next_version text;
  old_version_id uuid;
  new_version_id uuid;
  wire_cooled integer := 0;
  guesses_superseded integer := 0;
  reads_placed integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'A fabricated wire cools; eleven works find their genres.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  update ontology.concept_edges e
     set status = 'candidate',
         provenance = coalesce(e.provenance, '{}'::jsonb)
           || jsonb_build_object('demoted_by', '0413',
                'reason', 'ungrounded_uncorroborated',
                'checked', 'wikidata:Q98582386')
    from ontology.concepts sc, ontology.concepts oc
   where e.ontology_version_id = new_version_id
     and e.status = 'active' and e.predicate_key = 'part_of_franchise'
     and sc.id = e.subject_concept_id and sc.concept_key = 'creator:aespa'
     and oc.id = e.object_concept_id and oc.concept_key = 'work:black_myth_wukong';
  get diagnostics wire_cooled = row_count;
  if wire_cooled = 0 then
    raise notice '0413: no wukong wire stands to cool';
  end if;

  create temporary table _replacements (
    concept_key text, genre_key text, qid text) on commit drop;
  insert into _replacements values
    ('work:teri_baaton_mein_aisa_uljha_jiya', 'genre:comedy_film', 'Q124260479'),
    ('work:teri_baaton_mein_aisa_uljha_jiya', 'genre:romance_film', 'Q124260479'),
    ('work:teri_baaton_mein_aisa_uljha_jiya', 'genre:science_fiction_film', 'Q124260479'),
    ('work:chungking_express', 'genre:crime_film', 'Q766263'),
    ('work:chungking_express', 'genre:romance_film', 'Q766263'),
    ('work:chungking_express', 'genre:tragicomedy', 'Q766263'),
    ('work:f1_the_movie', 'genre:action_film', 'Q114246242'),
    ('work:f1_the_movie', 'genre:sport_film', 'Q114246242'),
    ('work:call_me_by_your_name', 'genre:romance_film', 'Q25136757'),
    ('work:veere_di_wedding', 'genre:comedy_film', 'Q28841910'),
    ('work:interstellar', 'genre:adventure_film', 'Q13417189'),
    ('work:interstellar', 'genre:science_fiction_film', 'Q13417189'),
    ('work:interstellar', 'genre:thriller_film', 'Q13417189'),
    ('work:twilight', 'genre:action_film', 'Q160071'),
    ('work:twilight', 'genre:fantasy_film', 'Q160071'),
    ('work:twilight', 'genre:romance_film', 'Q160071'),
    ('work:twilight', 'genre:teen_film', 'Q160071'),
    ('work:run_with_the_wind', 'genre:teen_film', 'Q11069346'),
    ('work:la_la_land', 'genre:comedy_film', 'Q20856802'),
    ('work:la_la_land', 'genre:dance_film', 'Q20856802'),
    ('work:la_la_land', 'genre:musical_film', 'Q20856802'),
    ('work:la_la_land', 'genre:romance_film', 'Q20856802'),
    ('work:la_la_land', 'genre:tragicomedy', 'Q20856802'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:adventure_film', 'Q641315'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:family_film', 'Q641315'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:musical_film', 'Q641315'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:teen_film', 'Q641315'),
    ('work:spirit_stallion_of_the_cimarron', 'genre:western_film', 'Q641315'),
    ('work:august_rush', 'genre:action_film', 'Q695297'),
    ('work:august_rush', 'genre:musical_film', 'Q695297'),
    ('work:august_rush', 'genre:romance_film', 'Q695297'),
    ('work:the_greatest_showman', 'genre:biographical_film', 'Q27942936'),
    ('work:the_greatest_showman', 'genre:musical_film', 'Q27942936'),
    ('work:the_greatest_showman', 'genre:romance_film', 'Q27942936'),
    ('work:aashiqui_2', 'genre:musical_film', 'Q4662712'),
    ('work:aashiqui_2', 'genre:romance_film', 'Q4662712'),
    ('work:the_longest_day_in_chang_an', 'genre:period_drama_film', 'Q48927926');

  update ontology.concept_edges ge
     set status = 'rejected'
    from ontology.concepts c, ontology.concepts g
   where c.concept_key in (select distinct concept_key from _replacements)
     and ge.subject_concept_id = c.id
     and ge.ontology_version_id = new_version_id
     and ge.status = 'active' and ge.predicate_key = 'broader'
     and g.id = ge.object_concept_id
     and (g.concept_key = 'genre:anime'
          or g.concept_key ~ '^genre:.*(film|television|procedural|thriller|fiction|drama$|sitcom)')
     and g.concept_key not in (
       select genre_key from _replacements rp
        where rp.concept_key = c.concept_key);
  get diagnostics guesses_superseded = row_count;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key,
    object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, c.id, 'broader', g.id, 0.9, 'curated',
         jsonb_build_object('rule', '0413 wikidata re-placement',
                            'provider', 'wikidata', 'external_id', rp.qid),
         'active'
    from _replacements rp
    join ontology.concepts c on c.concept_key = rp.concept_key
    join ontology.concepts g on g.concept_key = rp.genre_key
  on conflict do nothing;
  get diagnostics reads_placed = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || wire_cooled
    || ' wire(s) cooled, ' || guesses_superseded || ' guess(es) superseded, '
    || reads_placed || ' read(s) placed');
  raise notice '0413: % published', next_version;
end;
$$;

commit;
