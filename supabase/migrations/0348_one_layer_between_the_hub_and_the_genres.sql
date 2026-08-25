-- 0348 — the hardcoded layer between a hub and its genres (owner, 2026-08-25).
--
-- **The owner's direction: one authored layer — film/TV genres, music genres,
-- art styles — between the hubs and the individual headings.** After `0346` a
-- hub like `hub:music` holds three-hundred-odd genre children directly, mixed
-- with whatever else hangs from the hub; the layer says *which of a hub's
-- children are its genre system*, which is what a selection pass, a Memories
-- grouping, and a person reading the tree all want to know.
--
-- **`medium:` is the prefix, and it is precedent rather than invention** —
-- `medium:television` has sat under `hub:film_video` since the catalogue
-- gained it, kind `medium` is in the revisions check constraint, and the
-- prefix is on `0337`'s allowed list. Kind `medium` is deliberately absent
-- from `list_assertions`' allowlist, so a layer node can never surface as an
-- assertion — it is structure, not a claim about anybody.
--
-- **Block-neutral, by `0190`'s own ladder.** `concept_block` walks authored
-- blocks, then the nearest `genre:*` ancestor, then the hub. A genre still
-- blocks to itself with a medium node above it; a movement still falls past
-- the medium node to its hub. Nothing anybody sees moves.
--
-- **And the layer is never a placement target.** The candidate queries
-- exclude `medium:` alongside `era|sphere|scene` (companion edit in
-- `aws/worker/overlay.py` and `tools/ris_build_items.py`): a term is filed
-- under a genre or not at all, and offering "Music genres" as a destination
-- would recreate the hub-dump one level down.

begin;

do $$
declare
  current_version  text;
  next_version     text;
  old_version_id   uuid;
  new_version_id   uuid;
  ambiguous_before integer;
  ambiguous_after  integer;
  repointed_music  integer;
  repointed_screen integer;
  repointed_game   integer;
  repointed_art    integer;
  stragglers       integer;
  probe_block      text;
  enqueued         integer;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';

  select count(*) into ambiguous_before
    from (select l.normalized_label
            from ontology.concept_labels l
           where l.ontology_version_id = old_version_id and l.status = 'active'
           group by l.normalized_label having count(distinct l.concept_id) > 1) as already;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'One authored layer between each hub and its genre system.');
  select id into new_version_id from ontology.versions where version = next_version;

  perform ontology.copy_forward_version(old_version_id, new_version_id);

  -- The four layer nodes. Labels name the *collection*, not the medium —
  -- "Music genres", never "Music", which is the hub's label and would trip
  -- the ambiguity assertion below for the good reason that it should.
  insert into ontology.concepts (id, concept_key)
  values
    (extensions.gen_random_uuid(), 'medium:music_genres'),
    (extensions.gen_random_uuid(), 'medium:screen_genres'),
    (extensions.gen_random_uuid(), 'medium:game_genres'),
    (extensions.gen_random_uuid(), 'medium:art_styles')
  on conflict (concept_key) do nothing;

  insert into ontology.concept_revisions (
    ontology_version_id, concept_id, preferred_label, concept_kind,
    definition, sensitivity, inference_policy, status, metadata)
  select new_version_id, c.id, node.label, 'medium', node.definition,
         'ordinary', 'review_required', 'active',
         jsonb_build_object('origin', '0348_genre_layer')
    from (values
      ('medium:music_genres',  'Music genres',
       'The genre system of hub:music: every music genre hangs here.'),
      ('medium:screen_genres', 'Film & TV genres',
       'The genre system of hub:film_video: film and television genres.'),
      ('medium:game_genres',   'Game genres',
       'The genre system of hub:games_play.'),
      ('medium:art_styles',    'Art styles & movements',
       'The style system of hub:arts_live: the movement:* inventory.')
    ) as node(key, label, definition)
    join ontology.concepts c on c.concept_key = node.key
  on conflict (ontology_version_id, concept_id) do nothing;

  insert into ontology.concept_labels (
    ontology_version_id, concept_id, label, normalized_label, locale,
    label_type, provenance_type, confidence, status, external_ref)
  select new_version_id, c.id, node.label, node.normalized, 'en',
         'preferred', 'curated', 1.0, 'active',
         jsonb_build_object('origin', '0348_genre_layer')
    from (values
      ('medium:music_genres',  'Music genres',          'music genres'),
      ('medium:screen_genres', 'Film & TV genres',      'film tv genres'),
      ('medium:game_genres',   'Game genres',           'game genres'),
      ('medium:art_styles',    'Art styles & movements','art styles movements')
    ) as node(key, label, normalized)
    join ontology.concepts c on c.concept_key = node.key
  on conflict do nothing;

  insert into ontology.concept_edges (
    ontology_version_id, subject_concept_id, predicate_key, object_concept_id,
    confidence, provenance_type, provenance, status)
  select new_version_id, child.id, 'broader', parent.id, 1.0, 'curated',
         jsonb_build_object('source', '0348_genre_layer'), 'active'
    from (values
      ('medium:music_genres',  'hub:music'),
      ('medium:screen_genres', 'hub:film_video'),
      ('medium:game_genres',   'hub:games_play'),
      ('medium:art_styles',    'hub:arts_live')
    ) as pair(child_key, parent_key)
    join ontology.concepts child on child.concept_key = pair.child_key
    join ontology.concepts parent on parent.concept_key = pair.parent_key
  on conflict do nothing;

  -- ---------------------------------------------------------------------
  -- Re-point: a genre's broader edge moves from the hub to the layer node.
  -- An UPDATE on the new version's copied edges, never on history — the old
  -- version keeps its shape, which is what versions are for.
  -- ---------------------------------------------------------------------
  update ontology.concept_edges e
     set object_concept_id = (select id from ontology.concepts
                               where concept_key = 'medium:music_genres')
    from ontology.concept_revisions r
   where e.ontology_version_id = new_version_id
     and e.predicate_key = 'broader' and e.status = 'active'
     and e.object_concept_id = (select id from ontology.concepts
                                 where concept_key = 'hub:music')
     and r.ontology_version_id = new_version_id
     and r.concept_id = e.subject_concept_id
     and r.concept_kind = 'genre';
  get diagnostics repointed_music = row_count;

  update ontology.concept_edges e
     set object_concept_id = (select id from ontology.concepts
                               where concept_key = 'medium:screen_genres')
    from ontology.concept_revisions r
   where e.ontology_version_id = new_version_id
     and e.predicate_key = 'broader' and e.status = 'active'
     and e.object_concept_id = (select id from ontology.concepts
                                 where concept_key = 'hub:film_video')
     and r.ontology_version_id = new_version_id
     and r.concept_id = e.subject_concept_id
     and r.concept_kind = 'genre';
  get diagnostics repointed_screen = row_count;

  update ontology.concept_edges e
     set object_concept_id = (select id from ontology.concepts
                               where concept_key = 'medium:game_genres')
    from ontology.concept_revisions r
   where e.ontology_version_id = new_version_id
     and e.predicate_key = 'broader' and e.status = 'active'
     and e.object_concept_id = (select id from ontology.concepts
                                 where concept_key = 'hub:games_play')
     and r.ontology_version_id = new_version_id
     and r.concept_id = e.subject_concept_id
     and r.concept_kind = 'genre';
  get diagnostics repointed_game = row_count;

  -- Movements are keyed, not kinded: their kind is `topic`, shared with
  -- subjects and eras, so the selector is the `movement:` prefix.
  update ontology.concept_edges e
     set object_concept_id = (select id from ontology.concepts
                               where concept_key = 'medium:art_styles')
    from ontology.concepts subject
   where e.ontology_version_id = new_version_id
     and e.predicate_key = 'broader' and e.status = 'active'
     and e.object_concept_id = (select id from ontology.concepts
                                 where concept_key = 'hub:arts_live')
     and subject.id = e.subject_concept_id
     and subject.concept_key like 'movement:%';
  get diagnostics repointed_art = row_count;

  -- ---------------------------------------------------------------------
  -- What must hold before this is published
  -- ---------------------------------------------------------------------
  if repointed_music = 0 or repointed_screen = 0
     or repointed_game = 0 or repointed_art = 0 then
    raise exception
      '0348: a layer re-pointed nothing (music %, screen %, game %, art %) — an empty layer is a lie about the tree',
      repointed_music, repointed_screen, repointed_game, repointed_art;
  end if;

  -- No genre remains directly under the four hubs; the layer is the layer.
  select count(*) into stragglers
    from ontology.concept_edges e
    join ontology.concept_revisions r
      on r.ontology_version_id = new_version_id and r.concept_id = e.subject_concept_id
    join ontology.concepts hub on hub.id = e.object_concept_id
   where e.ontology_version_id = new_version_id
     and e.predicate_key = 'broader' and e.status = 'active'
     and r.concept_kind = 'genre'
     and hub.concept_key in ('hub:music', 'hub:film_video', 'hub:games_play');
  if stragglers > 0 then
    raise exception '0348: % genre(s) still hang directly from a layered hub', stragglers;
  end if;

  select count(*) into ambiguous_after
    from (select l.normalized_label
            from ontology.concept_labels l
           where l.ontology_version_id = new_version_id and l.status = 'active'
           group by l.normalized_label having count(distinct l.concept_id) > 1) as now_ambiguous;
  if ambiguous_after <> ambiguous_before then
    raise exception '0348: ambiguity went from % to %', ambiguous_before, ambiguous_after;
  end if;

  perform ontology.publish_version(new_version_id);

  -- **Block-neutrality, proven on the published version rather than argued.**
  -- A genre still blocks to itself through the new layer; a movement still
  -- falls past the medium node to its hub.
  select semantic_private.concept_block(c.id, new_version_id) into probe_block
    from ontology.concept_labels l
    join ontology.concepts c on c.id = l.concept_id
   where l.ontology_version_id = new_version_id and l.status = 'active'
     and l.normalized_label = 'film noir';
  if probe_block is distinct from 'genre:film_noir' then
    raise exception '0348: film noir blocks to %, the layer moved a block', coalesce(probe_block, '(nothing)');
  end if;

  select semantic_private.concept_block(c.id, new_version_id) into probe_block
    from ontology.concept_labels l
    join ontology.concepts c on c.id = l.concept_id
   where l.ontology_version_id = new_version_id and l.status = 'active'
     and l.normalized_label = 'cubism';
  if probe_block is distinct from 'hub:arts_live' then
    raise exception '0348: cubism blocks to %, the layer moved a block', coalesce(probe_block, '(nothing)');
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'ontology ' || next_version || ': the genre layer'
         ) into enqueued;

  raise notice '0348: % published — repointed music %, screen %, game %, art %; % recompute job(s)',
    next_version, repointed_music, repointed_screen, repointed_game, repointed_art, enqueued;
end;
$$;

commit;
