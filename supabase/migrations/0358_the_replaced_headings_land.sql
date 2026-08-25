-- 0358 — the post-culture re-place lands, curated by the owner's rule.
--
-- The re-place over the inventories 0355/0356 built (ris_v19, job 202462):
-- the 24 hub:places_cultures residue terms re-asked over the 256-heading
-- culture inventory they never had, and the 145 hub:arts_live none-residue
-- terms re-asked with the 102 stage genres added. 169/169 parsed, zero
-- overflows. 79 stayed `none` (honest), 9 routed to the proposal lane.
--
-- **What lands is the owner-curated subset (directive, 2026-08-25), and the
-- refusals are the record of two measured failure patterns.** places_cultures
-- lost eight rows: five place-shoehorns (family matched to the only place:
-- keys on the menu with identity ignored — Kyoto under place:italy, Shibuya
-- under place:hong_kong), one wrong-culture restaurant, and the model's own
-- two sub-0.2-confidence flags. arts_live lost 49: the enlarged menu turned
-- honest refusals on bare self-title records into confident dumps (twelve
-- terms on commedia dell'arte, J-pop artists under theatre forms), and
-- several anchored answers contradicted their own relations (a Wicked cast
-- member under ballet, a pop song under chuanqi, the Peking-opera group
-- member under Cantonese opera — the right heading lives in the music
-- inventory, reachable by the cross-hub ask, never by the wrong tradition).
-- What survives is what the evidence supports: the opera-voice cluster
-- (green snake, the 晚夜微雨问海棠 performers, a yue yue, mo chou xiang) and
-- the comedians (Conan O'Brien, Ken Jeong), plus sixteen culture placements
-- (taiwan, tokyo, paris, the New York cluster, zeus under Greece).
--
-- A specific answer to the same question from the same lane overwrites the
-- hub proposal it replaces; proposals from any other source are untouched.
-- Headings resolve best-effort with misses counted (`0344`'s inherited
-- rule): the inventories were read off the live tree, which holds
-- runtime-minted concepts a clean replay does not.

do $$
declare
  n integer;
  missing text;
begin
  create temporary table _replacement
    (normalized_label text, family text, parent_key text, confidence numeric)
    on commit drop;
  insert into _replacement values
    ('a yue yue', 'person', 'genre:yue_opera', 0.95),
    ('barcelona night', 'franchise', 'culture:spain', 0.95),
    ('california', 'work', 'culture:america', 0.95),
    ('central park', 'place', 'culture:america', 0.95),
    ('chen yiming', 'person', 'genre:cantonese_opera', 0.95),
    ('conan o''brien', 'person', 'genre:stand_up_comedy', 0.95),
    ('green snake', 'work', 'genre:cantonese_opera', 0.95),
    ('hyatt regency bellevue', 'organization', 'subject:travel', 0.95),
    ('jing yuge', 'person', 'genre:chuanqi', 0.95),
    ('ken jeong', 'person', 'genre:stand_up_comedy', 0.95),
    ('mo chou xiang', 'work', 'genre:cantonese_opera', 0.95),
    ('new york', 'place', 'culture:america', 0.95),
    ('new york city', 'work', 'culture:america', 0.95),
    ('paris', 'work', 'culture:france', 0.95),
    ('park terrace hotel', 'organization', 'subject:travel', 0.95),
    ('sicily', 'work', 'place:italy', 0.95),
    ('spanish sahara', 'work', 'culture:spain', 0.95),
    ('taiwan', 'culture', 'culture:taiwan', 0.95),
    ('terraced fields', 'work', 'culture:china', 0.95),
    ('the palazzo', 'organization', 'subject:travel', 0.95),
    ('the venetian resort', 'organization', 'subject:travel', 0.95),
    ('tokyo', 'culture', 'culture:japan', 0.95),
    ('xuan xiao', 'person', 'genre:chuanqi', 0.95),
    ('zeus', 'person', 'culture:greece', 0.95)
  ;
  select string_agg(distinct r.parent_key, ', ') into missing
    from _replacement r
   where not exists (select 1 from ontology.concepts c
                      where c.concept_key = r.parent_key
                        and c.retired_at is null);
  if missing is not null then
    raise notice '0358: headings not held here, skipped: %', missing;
  end if;

  update semantic_private.presumed_terms t
     set proposed_parent_concept_id = c.id,
         proposed_parent_confidence_unvalidated = r.confidence,
         proposed_parent_source = 'placement_pass'
    from _replacement r
    join ontology.concepts c
      on c.concept_key = r.parent_key and c.retired_at is null
   where t.normalized_label = r.normalized_label
     and t.family = r.family
     and coalesce(t.proposed_parent_source, 'placement_pass') = 'placement_pass';
  get diagnostics n = row_count;
  raise notice '0358: % of % re-placements landed', n,
    (select count(*) from _replacement);
  if n = 0 then
    raise exception
      '0358: re-placements were emitted and none matched a term';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- The same answers as per-hub placements: one per hub, updated not doubled.
-- ---------------------------------------------------------------------------
do $$
declare
  n integer;
begin
  create temporary table _placement2
    (normalized_label text, family text, parent_key text, hub_key text,
     confidence numeric)
    on commit drop;
  insert into _placement2 values
    ('a yue yue', 'person', 'genre:yue_opera', 'hub:arts_live', 0.95),
    ('barcelona night', 'franchise', 'culture:spain', 'hub:places_cultures', 0.95),
    ('california', 'work', 'culture:america', 'hub:places_cultures', 0.95),
    ('central park', 'place', 'culture:america', 'hub:places_cultures', 0.95),
    ('chen yiming', 'person', 'genre:cantonese_opera', 'hub:arts_live', 0.95),
    ('conan o''brien', 'person', 'genre:stand_up_comedy', 'hub:arts_live', 0.95),
    ('green snake', 'work', 'genre:cantonese_opera', 'hub:arts_live', 0.95),
    ('hyatt regency bellevue', 'organization', 'subject:travel', 'hub:places_cultures', 0.95),
    ('jing yuge', 'person', 'genre:chuanqi', 'hub:arts_live', 0.95),
    ('ken jeong', 'person', 'genre:stand_up_comedy', 'hub:arts_live', 0.95),
    ('mo chou xiang', 'work', 'genre:cantonese_opera', 'hub:arts_live', 0.95),
    ('new york', 'place', 'culture:america', 'hub:places_cultures', 0.95),
    ('new york city', 'work', 'culture:america', 'hub:places_cultures', 0.95),
    ('paris', 'work', 'culture:france', 'hub:places_cultures', 0.95),
    ('park terrace hotel', 'organization', 'subject:travel', 'hub:places_cultures', 0.95),
    ('sicily', 'work', 'place:italy', 'hub:places_cultures', 0.95),
    ('spanish sahara', 'work', 'culture:spain', 'hub:places_cultures', 0.95),
    ('taiwan', 'culture', 'culture:taiwan', 'hub:places_cultures', 0.95),
    ('terraced fields', 'work', 'culture:china', 'hub:places_cultures', 0.95),
    ('the palazzo', 'organization', 'subject:travel', 'hub:places_cultures', 0.95),
    ('the venetian resort', 'organization', 'subject:travel', 'hub:places_cultures', 0.95),
    ('tokyo', 'culture', 'culture:japan', 'hub:places_cultures', 0.95),
    ('xuan xiao', 'person', 'genre:chuanqi', 'hub:arts_live', 0.95),
    ('zeus', 'person', 'culture:greece', 'hub:places_cultures', 0.95)
  ;
  insert into semantic_private.presumed_term_placements
    (normalized_label, family, parent_concept_id, hub_key,
     confidence, source, corpus)
  select p.normalized_label, p.family, c.id, p.hub_key,
         p.confidence, 'placement_pass', 'ris_v19'
    from _placement2 p
    join ontology.concepts c
      on c.concept_key = p.parent_key and c.retired_at is null
  on conflict (normalized_label, family, hub_key) do update
    set parent_concept_id = excluded.parent_concept_id,
        confidence = excluded.confidence,
        source = excluded.source,
        corpus = excluded.corpus;
  get diagnostics n = row_count;
  raise notice '0358: % per-hub placements landed', n;
end;
$$;
