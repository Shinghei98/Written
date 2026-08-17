-- 0191 — a genre named after one we hold.
--
-- ## What is left after Apple's taxonomy
--
-- `0188` imported Apple's own tree — 56 genres across 167 storefronts — and it
-- covers most of what libraries state. Nine strings still resolve to nothing,
-- because they appear only as free text on tracks and Apple exposes no genre
-- resource for them:
--
--     britpop · french pop · indie pop · chinese rock
--     bengali · big band · chinese hip hop · downtempo · hip hop
--
-- ## The rule, and it is a reading rather than a guess
--
-- **A genre whose name ends with a genre we already hold is a kind of it.**
-- `french pop` and `britpop` end with `pop`; `chinese rock` ends with `rock`.
-- That is Apple's own naming convention being read, not a judgement about the
-- music — the same class of act as `game_titles_in` reading a game out of an
-- album title.
--
-- **The longest suffix wins**, so a name ending in both `pop` and a longer
-- known genre takes the longer one, and the prefix must survive: a string that
-- *is* a known genre is not its own child.
--
-- ## What it refuses, and that it refuses them by itself
--
-- Five of the nine match no known suffix and are not minted: `bengali`,
-- `big band`, `downtempo`, `hip hop`, `chinese hip hop`. So are the four
-- non-music strings that reach `genreNames` from podcast rows in our own vault
-- — `drama`, `fiction literature`, `military history`, `spoken word`. **None of
-- them is named here.** They fall out because nothing they end with is a genre,
-- which is the difference between an allow-list and a list of exclusions
-- somebody has to keep current.
--
-- `hip hop` is the interesting refusal. We hold `Hip-Hop/Rap` as
-- `hip hop rap`, so `hip hop` is almost certainly the same genre under another
-- of Apple's spellings — but deciding that two names mean one thing is
-- synonymy, not suffixing, and a rule that guessed it would also merge
-- `indian` into `indian pop`. Four artists are affected. They stay unresolved
-- and visible rather than resolved and wrong.
--
-- ## Minted here, and continuously from now on
--
-- The strings come from `ontology.external_entities`, so this needs no network
-- and no token: the catalogue rows are already stored. The same function is
-- what a later mint calls, so a genre named after one we hold resolves the
-- first time somebody's library states it.

begin;

create or replace function semantic_private.mint_genres_from_stated_strings()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  to_mint  integer := 0;
  refused  integer := 0;
  parented integer := 0;
  enqueued integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    raise exception 'mint_genres_from_stated_strings: no published version';
  end if;

  drop table if exists stated_genre;
  drop table if exists stated_plan;

  -- **The stated string and its fold, zipped by position.** `genres` and
  -- `genres_normalized` are parallel arrays written together by
  -- `apple_catalog.py`; `with ordinality` is what keeps `Hip-Hop/Rap` beside
  -- `hip hop rap` rather than beside whichever entry sorted next to it.
  create temporary table stated_genre on commit drop as
  select distinct on (norm.value)
         norm.value as normalized,
         orig.value as name
    from ontology.external_entities e
   cross join lateral jsonb_array_elements_text(
     coalesce(e.raw_payload -> 'genres_normalized', '[]'::jsonb)
   ) with ordinality as norm(value, position)
   cross join lateral jsonb_array_elements_text(
     coalesce(e.raw_payload -> 'genres', '[]'::jsonb)
   ) with ordinality as orig(value, position)
   where e.provider = 'apple_music_catalog'
     and e.entity_kind = 'artist'
     and norm.position = orig.position
     and coalesce(norm.value, '') <> ''
   order by norm.value, orig.value;

  create temporary table stated_plan on commit drop as
  with known as (
    select l.normalized_label,
           min(l.concept_id::text)::uuid as concept_id,
           count(distinct l.concept_id) as concepts
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
      join ontology.concept_revisions r
        on r.ontology_version_id = v.id and r.concept_id = l.concept_id
     where l.status = 'active' and r.status = 'active'
       and r.concept_kind = 'genre'
     group by l.normalized_label
  ), any_label as (
    select distinct l.normalized_label
      from ontology.concept_labels l
      join ontology.versions v
        on v.id = l.ontology_version_id and v.version = current_version
     where l.status = 'active'
  )
  select s.normalized,
         s.name,
         'genre:' || replace(s.normalized, ' ', '_') as concept_key,
         parent.concept_id as parent_concept_id,
         parent.normalized_label as parent_label
    from stated_genre s
    left join lateral (
      -- The longest known genre this name ends with, and it must leave
      -- something in front of it.
      select k.normalized_label, k.concept_id
        from known k
       where k.concepts = 1
         and s.normalized <> k.normalized_label
         and s.normalized like '%' || k.normalized_label
         and length(k.normalized_label) >= 3
         and length(s.normalized) - length(k.normalized_label) >= 2
       order by length(k.normalized_label) desc
       limit 1
    ) as parent on true
   where not exists (select 1 from known k where k.normalized_label = s.normalized)
     and not exists (select 1 from any_label o where o.normalized_label = s.normalized)
     -- **The key must not already belong to something.** `hip hop` folds to the
     -- key `genre:hip_hop`, which is our hand-authored *Hip-Hop/Rap* — a
     -- different string, so the label guards above do not see it. Without this,
     -- `on conflict (concept_key) do nothing` would quietly hang a second name
     -- on somebody else's concept rather than refuse, which is how a constant
     -- fallback key once merged nine artists into one.
     and not exists (
       select 1 from ontology.concepts existing
        where existing.concept_key = 'genre:' || replace(s.normalized, ' ', '_'))
     and parent.concept_id is not null;

  select count(*) into to_mint from stated_plan;

  select count(*) into refused
    from stated_genre s
   where not exists (
     select 1 from stated_plan p where p.normalized = s.normalized)
     and not exists (
       select 1
         from ontology.concept_labels l
         join ontology.versions v
           on v.id = l.ontology_version_id and v.version = current_version
        where l.status = 'active' and l.normalized_label = s.normalized);

  if to_mint = 0 then
    return jsonb_build_object('minted', 0, 'refused', refused, 'published', false);
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Genres named after ones already held.');
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

  insert into ontology.concepts (id, concept_key)
  select extensions.gen_random_uuid(), p.concept_key from stated_plan p
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, p.name, 'genre',
         'Music genre as stated by the provider on the track; never inferred '
         || 'from a title.',
         'ordinary', 'inferable', 'active',
         jsonb_build_object('provider', 'apple_music_catalog',
                            'basis', 'named_after_' || p.parent_label)
    from stated_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
  on conflict do nothing;

  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, c.id, p.name, p.normalized, 'und',
         kind.label_type, 'provider', 1.0, 'active',
         -- `external_ref` is `not null`, and what belongs in it is the same
         -- thing the revision records: the provider whose string this is, and
         -- the genre its name ends with.
         jsonb_build_object('provider', 'apple_music_catalog',
                            'named_after', p.parent_label)
    from stated_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
   cross join (values ('preferred'), ('alternate')) as kind(label_type)
  on conflict do nothing;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select distinct new_version_id, c.id, 'broader', p.parent_concept_id, 1.0, 'provider',
         jsonb_build_object('source', 'mint_genres_from_stated_strings',
                            'provider', 'apple_music_catalog',
                            'named_after', p.parent_label),
         'active'
    from stated_plan p
    join ontology.concepts c on c.concept_key = p.concept_key
   where c.id <> p.parent_concept_id
  on conflict do nothing;
  get diagnostics parented = row_count;

  perform ontology.publish_version(new_version_id);

  select semantic_private.enqueue_recompute_on_analysis_change(
           'mint_genres_from_stated_strings: ' || next_version
         ) into enqueued;

  return jsonb_build_object(
    'minted', to_mint, 'refused', refused, 'parented', parented,
    'published', true, 'version', next_version, 'recomputes_enqueued', enqueued
  );
end;
$$;

revoke all on function semantic_private.mint_genres_from_stated_strings()
  from public, anon, authenticated;

do $$
declare
  receipt jsonb;
  britpop text;
  chinese text;
  leaked  integer;
  has_catalogue boolean;
begin
  -- **The mint names genres after strings the catalogue states, so a database
  -- with no catalogue has nothing to name.** The three outcome assertions below
  -- describe what production held on 2026-08-15 — four minted, britpop under
  -- pop, chinese rock under rock — and are demanded only where the input they
  -- describe exists. The refusal check at the foot is not conditioned, because
  -- "these must not appear" is answerable everywhere and is the half that shows
  -- the rule discriminates.
  select exists (
    select 1 from ontology.external_entities
     where provider = 'apple_music_catalog' and entity_kind = 'artist'
  ) into has_catalogue;

  receipt := semantic_private.mint_genres_from_stated_strings();
  raise notice '0191: % (catalogue present: %)', receipt, has_catalogue;

  if has_catalogue and (receipt ->> 'minted')::integer <> 4 then
    raise exception '0191: expected 4 genres named after ones we hold, got %',
      receipt ->> 'minted';
  end if;

  select p.concept_key into britpop
    from ontology.concept_edges e
    join ontology.versions v on v.id = e.ontology_version_id and v.status = 'published'
    join ontology.concepts c on c.id = e.subject_concept_id
    join ontology.concepts p on p.id = e.object_concept_id
   where c.concept_key = 'genre:britpop' and e.predicate_key = 'broader'
     and e.status = 'active';
  if has_catalogue and britpop is distinct from 'genre:pop' then
    raise exception '0191: britpop parents to %, expected genre:pop', britpop;
  end if;

  select p.concept_key into chinese
    from ontology.concept_edges e
    join ontology.versions v on v.id = e.ontology_version_id and v.status = 'published'
    join ontology.concepts c on c.id = e.subject_concept_id
    join ontology.concepts p on p.id = e.object_concept_id
   where c.concept_key = 'genre:chinese_rock' and e.predicate_key = 'broader'
     and e.status = 'active';
  if has_catalogue and chinese is distinct from 'genre:rock' then
    raise exception '0191: chinese rock parents to %, expected genre:rock', chinese;
  end if;

  -- **The refusals, asserted rather than assumed.** A rule that only ever says
  -- yes has not been shown to discriminate, and these are the ones whose
  -- admission would be a real error: four are not music at all.
  select count(*) into leaked
    from ontology.concepts c
    join ontology.versions v on v.status = 'published'
    join ontology.concept_revisions r
      on r.concept_id = c.id and r.ontology_version_id = v.id and r.status = 'active'
   where c.concept_key in ('genre:drama', 'genre:military_history',
                           'genre:spoken_word', 'genre:fiction_literature',
                           'genre:bengali');
  if leaked <> 0 then
    raise exception '0191: % refused string(s) were minted anyway', leaked;
  end if;

  -- **And the collision that would not have looked like one.** `hip hop` folds
  -- to `genre:hip_hop`, which is *Hip-Hop/Rap* and was authored by hand. The
  -- first draft of this assertion read that concept's existence as a leak; it
  -- is not, and the real question is whether this run hung a second name on it.
  -- Its preferred label answers that, and a merge would be invisible any other
  -- way.
  select count(*) into leaked
    from ontology.concept_revisions r
    join ontology.versions v on v.id = r.ontology_version_id and v.status = 'published'
    join ontology.concepts c on c.id = r.concept_id
   where c.concept_key = 'genre:hip_hop'
     and r.preferred_label <> 'Hip-Hop/Rap';
  if leaked <> 0 then
    raise exception '0191: genre:hip_hop was merged into rather than refused';
  end if;

  select count(*) into leaked
    from ontology.concept_labels l
    join ontology.versions v on v.id = l.ontology_version_id and v.status = 'published'
    join ontology.concepts c on c.id = l.concept_id
   where c.concept_key = 'genre:hip_hop' and l.normalized_label = 'hip hop';
  if leaked <> 0 then
    raise exception '0191: the string hip hop was aliased onto Hip-Hop/Rap';
  end if;
end;
$$;

commit;
