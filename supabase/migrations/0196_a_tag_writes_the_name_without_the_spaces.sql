-- 0196 — a tag writes the name without the spaces.
--
-- ## What the tags actually say
--
-- Stage 1 stopped fan channels becoming names. This is the other half: making
-- what those channels *carry* reach the vocabulary. Measured over every live
-- YouTube observation, the most common tags are:
--
--     kpop 76 · k-pop 63 · 케이팝 46 · 직캠 52 · fancam 40 · kbs 38
--     르세라핌 28 · 조유리 22 · joyuri 20 · le sserafim 20 · lesserafim 19
--     チョユリ 16 · sakura 18 · ive 14
--
-- **Not one of the top twenty-six resolved.** The reason is not missing
-- concepts — `genre:k_pop`, `creator:le_sserafim`, `creator:jo_yuri` and
-- `creator:ive` all exist. It is spelling:
--
--     genre:k_pop      has `k pop`     · the tag says `kpop`      (76 videos)
--     creator:jo_yuri  has `jo yuri`   · the tag says `joyuri`    (20 videos)
--
-- `k-pop` resolves because `normalize_text` folds the hyphen to a space.
-- `kpop` does not, because nothing folds a *missing* space into one — and a
-- hashtag or a tag is exactly where people drop them.
--
-- ## The mechanical half, which contains no judgement
--
-- **For every active label, the same string without its spaces.** This is not a
-- second implementation of the fold — the input is already `normalize_text`'s
-- output, and removing spaces from it produces exactly what that function
-- returns for the compact spelling (`normalize_text('kpop') = 'kpop'`, verified
-- before this was written). So the rule adds a spelling of a name we already
-- hold, and invents nothing.
--
-- **1,822 aliases, and measured first: zero collide with another concept and
-- zero are already taken.** The guard stays anyway, because the day one does
-- collide is the day this would silently merge two concepts — which is what a
-- constant fallback key once did to nine artists. Labels shorter than three
-- characters are excluded, the same floor `MIN_TAG_LENGTH` applies at the other
-- end.
--
-- ## The authored half, which is judgement and is small
--
-- Three script spellings the tags use and the vocabulary lacks. Each is a name
-- for a thing we already hold, in the script the people tagging it write:
--
--     케이팝     -> genre:k_pop        (46 videos)
--     조유리     -> creator:jo_yuri    (22)   the existing alias is the *combined*
--                                            `조유리 jo yuri`, so the bare name misses
--     チョユリ    -> creator:jo_yuri    (16)
--
-- **`sakura` (18 videos) is deliberately not authored.** It is a LE SSERAFIM
-- member, a cherry blossom and an anime commonplace, and an alias must not be a
-- word — the rule `work_titles.mjs` already follows and the reason `wicked` and
-- `bleach` are kept away from free text. It wants a person's decision, not this
-- migration's.
--
-- Nothing is minted here and no new determination is needed: an alias on a
-- concept we authored is our vocabulary, and a tag is only ever *matched*
-- against it — the same act `GAME_TAG_CATALOGUE` performs today.

begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  compact_added integer;
  scripts_added integer;
  duplicated    integer;
  ambiguous_before integer;
  enqueued      integer;
  probe         text;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  -- **What is already ambiguous, counted before anything is added.** Seven
  -- labels name two concepts today and every one is deliberate — `dance` is an
  -- activity and a genre, `renaissance` and `romantic` are an era and a genre,
  -- `statquest` is a creator and a subject. The resolver already handles them
  -- by refusing to map an ambiguous label. So the test is not *"is anything
  -- ambiguous"*, which was this migration's first draft and failed on a
  -- property the database has never had — it is *"did this make anything
  -- newly ambiguous"*.
  select count(*) into ambiguous_before
    from (
      select l.normalized_label
        from ontology.concept_labels l
       where l.ontology_version_id = old_version_id and l.status = 'active'
       group by l.normalized_label having count(distinct l.concept_id) > 1
    ) as already;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'A tag writes the name without the spaces.');
  select id into new_version_id from ontology.versions where version = next_version;

  insert into ontology.concept_revisions (ontology_version_id, concept_id, preferred_label, concept_kind, definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, r.concept_id, r.preferred_label, r.concept_kind, r.definition, r.sensitivity, r.inference_policy, r.status, r.metadata
    from ontology.concept_revisions r where r.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_labels (ontology_version_id, concept_id, label, normalized_label, locale, label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, l.concept_id, l.label, l.normalized_label, l.locale, l.label_type, l.provenance_type, l.confidence, l.status, l.external_ref
    from ontology.concept_labels l where l.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.concept_edges (ontology_version_id, subject_concept_id, predicate_key, object_concept_id, confidence, provenance_type, provenance, status)
  select new_version_id, e.subject_concept_id, e.predicate_key, e.object_concept_id, e.confidence, e.provenance_type, e.provenance, e.status
    from ontology.concept_edges e where e.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.motif_rules (id, ontology_version_id, rule_key, evidence_target_concept_id, output_concept_id, evidence_predicate_key, output_predicate_key, rule_kind, minimum_independence_groups, minimum_strength, configuration, status)
  select extensions.gen_random_uuid(), new_version_id, m.rule_key, m.evidence_target_concept_id, m.output_concept_id, m.evidence_predicate_key, m.output_predicate_key, m.rule_kind, m.minimum_independence_groups, m.minimum_strength, m.configuration, m.status
    from ontology.motif_rules m where m.ontology_version_id = old_version_id
  on conflict do nothing;

  insert into ontology.external_concept_links (ontology_version_id, concept_id, external_entity_id, link_type, confidence, status)
  select new_version_id, x.concept_id, x.external_entity_id, x.link_type, x.confidence, x.status
    from ontology.external_concept_links x where x.ontology_version_id = old_version_id
  on conflict do nothing;

  -- 1. The compact spelling of every multi-word name.
  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select distinct on (compact.normalized)
         new_version_id, compact.concept_id, compact.label, compact.normalized,
         'und', 'alternate', 'curated', 1.0, 'active',
         jsonb_build_object('source', 'compact_spelling', 'of', compact.source_label)
    from (
      select l.concept_id,
             replace(l.label, ' ', '')            as label,
             replace(l.normalized_label, ' ', '') as normalized,
             l.normalized_label                   as source_label
        from ontology.concept_labels l
        join ontology.concept_revisions r
          on r.ontology_version_id = l.ontology_version_id and r.concept_id = l.concept_id
       where l.ontology_version_id = new_version_id
         and l.status = 'active' and r.status = 'active'
         and l.normalized_label like '% %'
         and length(replace(l.normalized_label, ' ', '')) >= 3
    ) as compact
   where not exists (
     -- **The collision guard, kept although nothing collides today.** A compact
     -- form already belonging to another concept must be left alone: hanging a
     -- second name on somebody else's concept is how nine artists once became
     -- one.
     select 1 from ontology.concept_labels taken
      where taken.ontology_version_id = new_version_id
        and taken.status = 'active'
        and taken.normalized_label = compact.normalized
        and taken.concept_id <> compact.concept_id)
     and not exists (
       select 1 from (
         select replace(l2.normalized_label, ' ', '') as normalized, l2.concept_id
           from ontology.concept_labels l2
          where l2.ontology_version_id = new_version_id and l2.status = 'active'
            and l2.normalized_label like '% %'
       ) as sibling
        where sibling.normalized = compact.normalized
          and sibling.concept_id <> compact.concept_id)
   order by compact.normalized, compact.concept_id
  on conflict do nothing;
  get diagnostics compact_added = row_count;

  -- 2. The three script spellings, authored from the measurement.
  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, c.id, authored.label, authored.normalized,
         authored.locale, 'alternate', 'curated', 1.0, 'active',
         jsonb_build_object('source', 'authored_script_spelling')
    from (values
      ('genre:k_pop',     '케이팝',  '케이팝',  'ko'),
      ('creator:jo_yuri', '조유리',  '조유리',  'ko'),
      ('creator:jo_yuri', 'チョユリ', 'チョユリ', 'ja')
    ) as authored(concept_key, label, normalized, locale)
    join ontology.concepts c on c.concept_key = authored.concept_key
   where not exists (
     select 1 from ontology.concept_labels taken
      where taken.ontology_version_id = new_version_id
        and taken.status = 'active'
        and taken.normalized_label = authored.normalized
        and taken.concept_id <> c.id)
  on conflict do nothing;
  get diagnostics scripts_added = row_count;

  -- 3. What must hold before this is published.
  select count(*) into duplicated
    from (
      select normalized_label
        from ontology.concept_labels
       where ontology_version_id = new_version_id and status = 'active'
       group by normalized_label having count(distinct concept_id) > 1
    ) as ambiguous;
  if duplicated <> ambiguous_before then
    raise exception '0196: ambiguity went from % label(s) to % — this added %',
      ambiguous_before, duplicated, duplicated - ambiguous_before;
  end if;

  if compact_added = 0 then
    raise exception '0196: no compact spelling was added, which is not the measured state';
  end if;

  perform ontology.publish_version(new_version_id);

  -- **Read back through the vocabulary, not through the insert.** The question
  -- is whether a tag resolves, and only a lookup answers it.
  select r.preferred_label into probe
    from ontology.concept_labels l
    join ontology.versions v on v.id = l.ontology_version_id and v.status = 'published'
    join ontology.concept_revisions r
      on r.ontology_version_id = v.id and r.concept_id = l.concept_id
   where l.normalized_label = 'kpop' and l.status = 'active' and r.status = 'active';
  if probe is distinct from 'K-Pop' then
    raise exception '0196: the tag kpop resolves to %, expected K-Pop', coalesce(probe, '(nothing)');
  end if;

  select r.preferred_label into probe
    from ontology.concept_labels l
    join ontology.versions v on v.id = l.ontology_version_id and v.status = 'published'
    join ontology.concept_revisions r
      on r.ontology_version_id = v.id and r.concept_id = l.concept_id
   where l.normalized_label = 'joyuri' and l.status = 'active' and r.status = 'active';
  if probe is distinct from 'JO YURI' then
    raise exception '0196: the tag joyuri resolves to %, expected JO YURI', coalesce(probe, '(nothing)');
  end if;

  select r.preferred_label into probe
    from ontology.concept_labels l
    join ontology.versions v on v.id = l.ontology_version_id and v.status = 'published'
    join ontology.concept_revisions r
      on r.ontology_version_id = v.id and r.concept_id = l.concept_id
   where l.normalized_label = '케이팝' and l.status = 'active' and r.status = 'active';
  if probe is distinct from 'K-Pop' then
    raise exception '0196: the tag 케이팝 resolves to %, expected K-Pop', coalesce(probe, '(nothing)');
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': compact and script spellings'
         ) into enqueued;

  raise notice '0196: % published, % compact spelling(s), % script spelling(s), % recompute job(s)',
    next_version, compact_added, scripts_added, enqueued;
end;
$$;

commit;
