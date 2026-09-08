-- 0472 — the categories of work are closed.
--
-- **The owner's definition (2026-09-07).** A work is one of exactly eleven
-- things: song, movie, tv_series, anime, album, reality_show, documentary,
-- book, podcast_show, game, franchise — "and nothing more". A franchise is a
-- category of work: an integrated media intellectual property that spans
-- many works and work types (the MCU, Harry Potter), and it roots at
-- `cardinal:work` like the rest. Anything titled that fits none of the
-- eleven is `other`: it stays as evidence and as a conduit for weight, and
-- it is never a row on Memories or a term the matching surface names.
--
-- Why. 0469 measured the ontology's works at 1,065 with 706 minted as
-- "franchise" because the model used the word for anything a person
-- belonged to, and its re-sort still left 392 franchises, 266 games, 89
-- untyped works and 60 assorted others. Two extraction runs under v6
-- (2026-09-07) then showed the model stretching whatever family was
-- nearest onto restaurants, albums and channels. A closed, defined set with
-- a hidden remainder is the owner's answer: a category is shown only when
-- it clearly fits, and the cost of not fitting is invisibility, not a wrong
-- heading.
--
-- The wire and the workbook moved in `mention_extract_v7` / prompt
-- `qwen_extractor_v24` (song and reality_show replace music_work and
-- tv_show on the wire; movie and podcast_show arrive; music_work and
-- tv_show stay in the ontology and leave the model's vocabulary, as
-- music_recording did in 0221). This is the half that lives here:
--
-- 1. The four places the database states the family vocabulary gain song,
--    movie, reality_show and podcast_show; the root map roots them and
--    franchise at work; the 0300/0332/0471 pin is restated.
-- 2. `api.list_assertions` and `semantic_private.matching_terms` withhold an
--    inferred work whose type is `other`; a typed or kept term survives
--    whatever its type.
--
-- **What this deliberately does not do yet: re-sort the works that stand.**
-- The first draft did, and the dry run (2026-09-07) showed why the order
-- matters: 477 of 837 works would fall to other, among them Bleach, Sword
-- Art Online, Persona 5, Barbie and Chungking Express — not because they
-- fit no category but because the dictionary filed them as "franchise" or
-- plain "work", which was all the old prompt could say. Reading the
-- dictionary back rescued twelve. So the vocabulary is admitted here, the
-- v7 corpus is extracted and emitted next, and the re-sort follows as its
-- own migration reading the enriched dictionary — the dark window is the
-- one the ontology's own knowledge dictates, not one this file adds. Until
-- then the readers hide only a type that already says `other`, which
-- nothing carries today, so no page changes at this migration.
begin;

-- ---------------------------------------------------------------------------
-- 1. The vocabulary, in its four places, and the root map.
-- ---------------------------------------------------------------------------
alter table semantic_private.presumed_terms
  drop constraint if exists presumed_terms_family_check;
alter table semantic_private.presumed_terms
  add constraint presumed_terms_family_check check (family in (
    'activity','album','anime','art','book','channel','culture','documentary',
    'event','event_type','field','franchise','game','game_category','group',
    'hub','movie','music_recording','music_work','organization','person',
    'place','platform','podcast_show','reality_show','song','sport','tour',
    'tv_series','tv_show','work','unknown'
  ));

alter table semantic_private.provisional_entities
  drop constraint if exists provisional_entities_family_check;
alter table semantic_private.provisional_entities
  add constraint provisional_entities_family_check check (family in (
    'activity','album','anime','art','book','channel','culture','documentary',
    'event','event_type','field','franchise','game','game_category','group',
    'hub','movie','music_recording','music_work','organization','person',
    'place','platform','podcast_show','reality_show','song','sport','tour',
    'tv_series','tv_show','work'
  ));

alter table semantic_private.provisional_projection_families
  drop constraint if exists provisional_projection_families_family_check;
alter table semantic_private.provisional_projection_families
  add constraint provisional_projection_families_family_check
  check (family = any (array[
    'activity','album','anime','art','book','channel','culture','documentary',
    'event','event_type','field','franchise','game','game_category','group',
    'hub','movie','music_recording','music_work','organization','person',
    'place','platform','podcast_show','reality_show','song','sport','tour',
    'tv_series','tv_show','work','unknown']));

insert into ontology.cardinal_root_map (concept_kind, root_id, rationale)
values
  ('song', 'cardinal:work', 'A recorded or composed piece of music with a title of its own is a released creation; stored as kind work, work_type song.'),
  ('movie', 'cardinal:work', 'A released film is a bounded creation; stored as kind work, work_type movie.'),
  ('reality_show', 'cardinal:work', 'An unscripted programme - reality, survival, variety, talk, game or music show - is a released creation with a title, not the event of one taping; stored as kind work, work_type reality_show.'),
  ('podcast_show', 'cardinal:work', 'A named podcast series is a released creation; an episode is its evidence. Stored as kind work, work_type podcast_show.'),
  ('franchise', 'cardinal:work', 'The owner (2026-09-07): a franchise is a category of work - an integrated media intellectual property spanning many works and work types - and roots at work like the other ten.')
on conflict (concept_kind) do update
  set root_id = excluded.root_id, rationale = excluded.rationale;

do $$
declare
  wire_map constant jsonb := '{
    "person": "person", "group": "group", "organization": "organization",
    "song": "work", "movie": "work", "tv_series": "work", "anime": "work",
    "album": "work", "reality_show": "work", "documentary": "work",
    "book": "work", "podcast_show": "work", "game": "work",
    "franchise": "work", "work": "work",
    "sport": "activity", "activity": "activity",
    "art": "concept", "field": "concept",
    "place": "none", "culture": "concept", "event": "event", "tour": "event"
  }'::jsonb;
  entry record;
  ontology_root text;
begin
  for entry in select * from jsonb_each_text(wire_map) loop
    select coalesce(replace(m.root_id, 'cardinal:', ''), 'none') into ontology_root
      from ontology.cardinal_root_map m where m.concept_kind = entry.key;
    if not found then
      raise exception '0472: the ontology map does not know family %', entry.key;
    end if;
    if ontology_root <> entry.value then
      raise exception '0472: family % is % on the wire and % in the ontology', entry.key, entry.value, ontology_root;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. The readers: an inferred other work is withheld on Memories and on
--    matching. A typed or kept term survives whatever its type.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_assertions()
 RETURNS TABLE(assertion_id uuid, predicate_key text, label text, origin text, display_state text, strength double precision, confidence double precision, breadth integer, stability double precision, surfacing_score double precision, display_payload jsonb, assertion_score_version_id uuid, ontology_version_id uuid, block_key text, block_label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select
    assertion.id,
    assertion.predicate_key,
    -- 0364: the designated syntax — official name (original language
    -- name) — composed from the dictionary, which is the one store that
    -- knows both halves of a foreign term's identity.
    coalesce(coalesce(song.artist, song3.artist, song2.artist) || ' - ', '') ||
    case
      -- 0367: natively English — the dictionary's original IS the english
      -- (Loki/Loki) — reads as the english alone, whatever script the
      -- concept's own label happens to be in. 洛基 is a surface, not a name.
      when native.english_label is not null
           and native.english_label !~ '[^\x00-\x7F]'
           and native.original_label = native.english_label
      then native.english_label
      -- A foreign original beside a foreign-scripted preferred label:
      -- english leads, the original follows — Sword Art Online
      -- (ソードアート・オンライン).
      when coalesce(revision.preferred_label, user_term.label) ~ '[^\x00-\x7F]'
           and native.english_label is not null
           and native.english_label !~ '[^\x00-\x7F]'
           and native.original_label ~ '[^\x00-\x7F]'
           and native.english_label <> coalesce(revision.preferred_label, user_term.label)
      then native.english_label || ' ('
             || coalesce(revision.preferred_label, user_term.label) || ')'
      -- 0365's case: an English-named concept with a genuinely foreign
      -- original appends it — Jay Chou (周杰倫); a same-script echo never
      -- composes.
      when native.original_label is not null
           and native.original_label ~ '[^\x00-\x7F]'
           and native.original_label <> coalesce(revision.preferred_label, user_term.label)
      then coalesce(revision.preferred_label, user_term.label)
             || ' (' || native.original_label || ')'
      else coalesce(revision.preferred_label, user_term.label)
    end,
    assertion.assertion_origin,
    coalesce(preference.display_state, 'default'),
    score.strength,
    score.confidence,
    score.breadth,
    score.stability,
    score.surfacing_score,
    score.display_payload,
    score.id,
    coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'), assertion.created_ontology_version_id),
    block.concept_key,
    block_revision.preferred_label
  from semantic_private.user_assertions as assertion
  left join semantic_private.assertion_preferences as preference
    on preference.assertion_id = assertion.id
   and preference.user_id = assertion.user_id
  left join semantic_private.user_terms as user_term
    on user_term.id = assertion.user_term_id
   and user_term.user_id = assertion.user_id
  left join semantic_private.assertion_current_scores as current_score
    on current_score.assertion_id = assertion.id
   and current_score.user_id = assertion.user_id
  left join semantic_private.user_state_versions as user_state
    on user_state.user_id = assertion.user_id
  left join semantic_private.semantic_runs as score_run
    on score_run.id = current_score.semantic_run_id
   and score_run.user_id = assertion.user_id
   and score_run.status = 'succeeded'
   and score_run.input_revision = coalesce(user_state.revision, 0)
  left join semantic_private.assertion_score_versions as score
    on score.id = current_score.assertion_score_version_id
   and score.user_id = current_score.user_id
   and score.assertion_id = current_score.assertion_id
   and score.semantic_run_id = score_run.id
  left join ontology.concept_revisions as revision
    on revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
   and revision.concept_id = assertion.concept_id
   -- 0403: active only. A deprecated revision (a fold's loser, a retired
   -- fragment) must stop supplying the kind that passes the allowlist —
   -- Episode 25 stayed on the page because this join read its deprecated
   -- revision as happily as an active one.
   and revision.status = 'active'
  -- **The concept's own key, which the filter below needs and nothing here had.**
  -- A primary-key lookup, and `left` rather than `inner` because a user's own
  -- term has no concept at all and an inner join would delete every one of them.
  left join ontology.concepts as concept
    on concept.id = assertion.concept_id
  -- The block, and its label at the same version the term is read at, so a
  -- heading can never come from a different ontology than the row under it.
  left join lateral (
    select c.id, c.concept_key
      from ontology.concepts c
     where c.concept_key = coalesce(
             semantic_private.concept_block(
               assertion.concept_id,
               coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'),
                        assertion.created_ontology_version_id)),
             -- 0373: a trip with no edges files under the travel heading
             -- rather than "Other" — the card the parallel listing needs.
             case when concept.concept_key like 'travel:%'
                  then 'subject:travel' end)
  ) as block on true
  left join ontology.concept_revisions as block_revision
    on block_revision.concept_id = block.id
   and block_revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
   and block_revision.status = 'active'
  -- 0360: the topical hub this row buckets under, for the cutoff. Null for
  -- a user's own term (no concept) and for a concept outside every hub.
  left join lateral (
    select semantic_private.concept_hub(
             assertion.concept_id,
             coalesce(score.ontology_version_id, (select pv.id from ontology.versions pv where pv.status = 'published'),
                      assertion.created_ontology_version_id)) as hub_key
  ) as hub on true
  -- 0364: the entity's own-language name, from `presumed_terms` — reached
  -- by the promotion link where one exists, else by exact normalized-label
  -- match at this version. Only a name that genuinely differs is shown; an
  -- English-native term keeps its single name.
  -- 0367: both halves of the term's identity, from the dictionary. The
  -- contract's rule decides what is drawn: the original is the language the
  -- entity *belongs to*, not the script a title used — so a natively
  -- English entity's row has original = english and earns no parenthesis,
  -- while a foreign entity's original differs and is shown. Matched by
  -- promotion link, by identity (a concept whose preferred label IS the
  -- original), or by exact label.
  left join lateral (
    select t.original_label, t.english_label
      from semantic_private.presumed_terms t
     where t.original_label is not null
       and t.english_label is not null
       and (t.promoted_concept_id = assertion.concept_id
            or t.original_label = coalesce(revision.preferred_label, '')
            or exists (
              select 1 from ontology.concept_labels l
               where l.concept_id = assertion.concept_id
                 and l.status = 'active'
                 and l.ontology_version_id = coalesce(
                       score.ontology_version_id,
                       assertion.created_ontology_version_id)
                 and l.normalized_label = t.normalized_label))
     order by (t.original_label = coalesce(revision.preferred_label, '')) desc,
              (t.promoted_concept_id = assertion.concept_id) desc,
              t.mention_support desc nulls last, t.id
     limit 1
  ) as native on true
  -- 0373: the owner's song syntax — "performer - song name", composer for
  -- classical. A work row is a *song* exactly when an accepted mapping's
  -- own observation carries the row's label as its title; a franchise or
  -- film never does, so nothing else is prefixed. Classical is read off
  -- the row's own stated genres, the same asymmetry 0038 established.
  left join lateral (
    select case
             when o.normalized_payload -> 'genres' ? 'Classical'
                  and nullif(btrim(o.normalized_payload ->> 'composer'), '') is not null
             then btrim(o.normalized_payload ->> 'composer')
             else nullif(btrim(o.normalized_payload ->> 'primary_performer'), '')
           end as artist
      from semantic_private.observation_mappings m
      join semantic_private.observations o
        on o.id = m.observation_id and o.user_id = m.user_id
     where revision.concept_kind = 'work'
       and m.concept_id = assertion.concept_id
       and m.user_id = assertion.user_id
       and m.mapping_state = 'accepted'
       -- 0375: extraction rightly splits the artist out of an album title
       -- ("Kiroro No Ichiban..." names the work "Ichiban..."), so exact
       -- equality misses precisely the rows whose performer is best
       -- known. The match: the title IS the label, or the album field is,
       -- or the title contains the label and names the performer — the
       -- remainder accounted for, not guessed.
       and (lower(btrim(o.normalized_payload ->> 'title'))
              = lower(btrim(revision.preferred_label))
            or lower(btrim(coalesce(o.normalized_payload ->> 'album', '')))
              = lower(btrim(revision.preferred_label))
            or (position(lower(btrim(revision.preferred_label))
                  in lower(o.normalized_payload ->> 'title')) > 0
                and nullif(btrim(o.normalized_payload ->> 'primary_performer'), '') is not null
                and position(lower(split_part(o.normalized_payload ->> 'primary_performer', ' ', 1))
                  in lower(o.normalized_payload ->> 'title')) > 0))
     order by m.evidence_weight * m.recency_weight desc
     limit 1
  ) as song on true
  -- 0387: the performer fallback — YouTube evidence carries no
  -- primary_performer field, so a song kept off a decorated video title
  -- drew bare. The dictionary's own performed_by relation names the
  -- artist deterministically.
  left join lateral (
    select ot.canonical_label as artist
      from semantic_private.presumed_terms t
      join semantic_private.presumed_term_relations rel
        on rel.subject_term_id = t.id and rel.predicate = 'performed_by'
      join semantic_private.presumed_terms ot on ot.id = rel.object_term_id
     where revision.concept_kind = 'work'
       and song.artist is null
       and t.promoted_concept_id = assertion.concept_id
     -- 0390: the group is the song's performer. 0391: and where only a
     -- member was stated (a fancam relation), the member's own
     -- member_of_group resolves to the group — karina stands in for
     -- aespa only until the join runs.
     order by (ot.family = 'group') desc,
              rel.observed_count desc nulls last, ot.id
     limit 1
  ) as song2 on true
  left join lateral (
    select gt.canonical_label as artist
      from semantic_private.presumed_terms mt
      join semantic_private.presumed_term_relations mg
        on mg.subject_term_id = mt.id and mg.predicate = 'member_of_group'
      join semantic_private.presumed_terms gt on gt.id = mg.object_term_id
     where song2.artist is not null
       and mt.normalized_label = lower(btrim(song2.artist))
       and mt.family = 'person' and gt.family = 'group'
     order by mg.observed_count desc nulls last, gt.id
     limit 1
  ) as song3 on true
  where assertion.user_id = auth.uid()
    and assertion.machine_state in ('candidate', 'eligible')
    and coalesce(preference.display_state, 'default') <> 'suppressed'
    -- Nameable things only. A term the person typed has no concept and no kind,
    -- and is always theirs to see.
    --
    -- `topic` joins the allowlist, less the three axis families: an axis is
    -- something the scorer reasons with, not a claim anybody would make about
    -- themselves, and striking one off would silently reweigh everything else.
    --
    -- 0360: `genre` and `culture` join it, and that is the owner deciding
    -- they belong (2026-08-25) — the propagated tail's whole point is that
    -- genre:pop and culture:taiwan are terms a person keeps or strikes, and
    -- an allowlist that withheld them would hide exactly what the bootstrap
    -- exists to price. The axis exclusions stand; `medium` and `hub` stay
    -- out, being structure rather than taste.
    -- 0367: an entry is a specific entity — a person, an organization, a
    -- group (a channel represented by more than one person is a group), a
    -- work, or a franchise (owner, 2026-08-25). The summarizing parents —
    -- genres, subjects, cultures — are the cards' *titles*, drawn by the
    -- block machinery, never rows beside their own children. A term the
    -- person typed or kept stays theirs to see whatever its kind.
    and (
      assertion.user_term_id is not null
      or assertion.assertion_origin <> 'inferred'
      or (
        -- 0465: the owner decided organizations belong — the re-kinded
        -- labels were on this page as works and must not vanish for a
        -- taxonomy fix.
        revision.concept_kind in ('creator', 'work', 'organization')
        and concept.concept_key not like 'era:%'
        and concept.concept_key not like 'sphere:%'
        and concept.concept_key not like 'scene:%'
      )
      -- 0436: trips return, by their own key (owner, 2026-08-27) —
      -- "a trip is a term like any other" supersedes 0375's travel
      -- half. Narrow on purpose: 0367's entity ruling on other
      -- activity concepts is not reopened.
      or concept.concept_key like 'travel:%'
      -- 0438: the fields show as terms (owner, 2026-08-27) — the
      -- generalized subjects, structurally marked: a subject whose hub
      -- is ideas_learning is a field; music_labels, travel and
      -- content_creators live under other hubs and are untouched.
      or (concept.concept_key like 'subject:%'
          and hub.hub_key = 'hub:ideas_learning')
    )
    -- 0375: place, travel and culture are too broad a layer for Memories
    -- (owner, 2026-08-25) — cultural preference is internal marking. They
    -- keep their assertions and weights and leave the page, every origin
    -- included: an internal marking is internal whoever put it there.
    -- (Supersedes 0373's travel rows, same day, by the owner's word.)
    -- 0375's place/culture halves stand; its travel half is superseded
    -- (owner, 2026-08-27) — see the allowlist above.
    and coalesce(revision.concept_kind, '') not in ('place', 'culture')
    -- 0472: the categories of work are closed (owner, 2026-09-07): song,
    -- movie, tv_series, anime, album, reality_show, documentary, book,
    -- podcast_show, game, franchise. A work in none of them is `other` —
    -- kept as evidence and as a conduit, never a row on a page. A term the
    -- person typed or kept is theirs whatever its type.
    and not (
      revision.concept_kind = 'work'
      and assertion.user_term_id is null
      and assertion.assertion_origin = 'inferred'
      and revision.metadata ->> 'work_type' = 'other')
    -- 0437: for music, only persons and groups (owner, 2026-08-27). A
    -- work that resolves a performer or composer — through the same
    -- three laterals that compose its "artist - title" label — is a
    -- musical work, and its line on the page is the artist's, not its
    -- own. Films and franchises resolve no artist and stay. The strike
    -- cascade is the scorer's (0.23.0): a suppressed artist's works are
    -- derived-suppressed and demote on the next run.
    -- 0440: the artist test alone let generic classical recordings
    -- through ("Symphonies Nos. 5 & 7", "Requiem") — catalogue titles
    -- whose composer never resolves. The hub is the proof the title
    -- cannot give: an inferred work under hub:music is a musical work,
    -- and its line belongs to its composer or performer.
    and not (
      revision.concept_kind = 'work'
      and (coalesce(song.artist, song2.artist, song3.artist) is not null
           -- 0441: no origin qualifier — the ratings import stamped
           -- recordings 'explicit_addition', a data artifact, not a
           -- sentence anybody typed; typed terms are user_term rows
           -- and pass on their own branch.
           or hub.hub_key = 'hub:music')
      -- 0441: and containerhood exempts. Wicked is a musical with 36
      -- relations pointing INTO it — a thing other things belong to is
      -- an entity, not a recording; "Requiem" has no in-edges and is a
      -- library album. The in-degree is the structural line.
      and not exists (
        select 1 from ontology.concept_edges inbound
         where inbound.object_concept_id = assertion.concept_id
           and inbound.status = 'active'
           and inbound.ontology_version_id = coalesce(
                 score.ontology_version_id,
                 (select pv.id from ontology.versions pv
                   where pv.status = 'published'),
                 assertion.created_ontology_version_id))
    )
    -- 0438: and the specific channels leave the field blocks — the
    -- fields ruling's other half, the same inversion as music: the
    -- generalized term is the row, the specifics feed its weight.
    and not (
      assertion.assertion_origin = 'inferred'
      and revision.concept_kind = 'creator'
      and coalesce(hub.hub_key, '') = 'hub:ideas_learning'
    )
    -- 0439: be specific if possible (owner, 2026-08-27) — a field
    -- parent is withheld while a shown field child points at it
    -- through a broader edge: "French (language)" retires "Language
    -- learning", physics retires generic Science. The parent's
    -- assertion and weight stand; only the less specific line yields.
    and not (
      concept.concept_key like 'subject:%'
      and hub.hub_key = 'hub:ideas_learning'
      and exists (
        select 1
          from semantic_private.user_assertions child
          join ontology.concepts cc
            on cc.id = child.concept_id and cc.concept_key like 'subject:%'
          join ontology.concept_edges ce
            on ce.subject_concept_id = child.concept_id
           and ce.object_concept_id = assertion.concept_id
           and ce.predicate_key = 'broader' and ce.status = 'active'
           and ce.ontology_version_id = coalesce(
                 score.ontology_version_id,
                 (select pv.id from ontology.versions pv
                   where pv.status = 'published'),
                 assertion.created_ontology_version_id)
         where child.user_id = assertion.user_id
           and child.machine_state in ('candidate', 'eligible'))
    )
    and (
      assertion.assertion_origin <> 'inferred' or
      (
        score.id is not null
        and score_run.status = 'succeeded'
        and score_run.input_revision = coalesce(user_state.revision, 0)
      )
    )
    and not exists (
      select 1
      from semantic_private.user_suppressions as suppression
      where suppression.user_id = assertion.user_id
        and suppression.predicate_key = assertion.predicate_key
        and suppression.surface = 'memories'
        and suppression.active
        and (
          (assertion.concept_id is not null and suppression.concept_id = assertion.concept_id) or
          (assertion.user_term_id is not null and suppression.user_term_id = assertion.user_term_id)
        )
    )
    -- 0360: the cutoff. A display decision, per (user, hub), from the one
    -- active release. `coalesce(..., 1.0)` is deliberate twice over: a
    -- declared term has no score row and passes any cutoff at the top score
    -- (the same fallback the order by already uses), and a concept outside
    -- every hub resolves through the release default.
    and (coalesce(score.surfacing_score, 1.0)
        >= semantic_private.active_memories_cutoff(assertion.user_id, hub.hub_key)
      -- 0438: a field term passes at any score — the cutoff was fitted
      -- to leaf terms, and a generalized subject standing in for its
      -- hidden channels is shown because they were, not by its own
      -- propagated fraction.
      or (concept.concept_key like 'subject:%'
          and hub.hub_key = 'hub:ideas_learning'))
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$function$
;

CREATE OR REPLACE FUNCTION semantic_private.matching_terms(p_subject uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(term order by term ->> 'score' desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'label', coalesce(revision.preferred_label, user_term.label),
               'kind', revision.concept_kind,
               'score', coalesce(score.surfacing_score, 1.0),
               'category', case
                 when revision.concept_kind = 'work' then coalesce(
                   case semantic_private.work_medium_from_evidence(
                          assertion.user_id, assertion.concept_id)
                     when 'anime' then 'tv_series'
                     when 'film'  then 'movie'
                     when 'game'  then 'game'
                   end,
                   semantic_private.bio_category(
                     assertion.concept_id, climb.v, revision.concept_kind,
                     assertion.predicate_key, climb.blk, climb.hub))
                 else semantic_private.bio_category(
                   assertion.concept_id, climb.v, revision.concept_kind,
                   assertion.predicate_key, climb.blk, climb.hub)
               end,
               'hub', climb.hub,
               'block', climb.blk
             ) as term
        from semantic_private.user_assertions as assertion
        left join semantic_private.user_terms as user_term
          on user_term.id = assertion.user_term_id
         and user_term.user_id = assertion.user_id
        left join semantic_private.assertion_preferences as preference
          on preference.assertion_id = assertion.id
         and preference.user_id = assertion.user_id
        left join semantic_private.assertion_current_scores as current_score
          on current_score.assertion_id = assertion.id
         and current_score.user_id = assertion.user_id
        left join semantic_private.assertion_score_versions as score
          on score.id = current_score.assertion_score_version_id
         and score.user_id = current_score.user_id
         and score.assertion_id = current_score.assertion_id
        left join ontology.concept_revisions as revision
          on revision.ontology_version_id = coalesce(
               score.ontology_version_id, assertion.created_ontology_version_id
             )
         and revision.concept_id = assertion.concept_id
        cross join lateral (
          select v.v,
                 case when assertion.concept_id is null then null
                      else semantic_private.concept_block(assertion.concept_id, v.v)
                 end as blk,
                 case when assertion.concept_id is null then null
                      else semantic_private.concept_hub(assertion.concept_id, v.v)
                 end as hub
            from (select coalesce(score.ontology_version_id,
                                  assertion.created_ontology_version_id) as v) v
        ) as climb
       where assertion.user_id = p_subject
         and assertion.machine_state = 'eligible'
         -- 0472: an `other` work is never named or used across users either;
         -- hidden on Memories is hidden on matching (owner, 2026-09-07).
         and not (
           revision.concept_kind = 'work'
           and assertion.user_term_id is null
           and assertion.assertion_origin = 'inferred'
           and revision.metadata ->> 'work_type' = 'other')
         and coalesce(preference.display_state, 'default') <> 'suppressed'
         and not exists (
           select 1 from semantic_private.user_suppressions as suppression
            where suppression.user_id = assertion.user_id
              and suppression.predicate_key = assertion.predicate_key
              and suppression.surface in ('matching', 'bio')
              and suppression.active
              and (
                (assertion.concept_id is not null
                 and suppression.concept_id = assertion.concept_id)
                or (assertion.user_term_id is not null
                    and suppression.user_term_id = assertion.user_term_id)
              )
         )
         -- The witness, for exactly the terms approval does not cover:
         -- confirmed is the user's own witness; declared never needed
         -- one; a travel: concept's only possible source is the
         -- calendar, a non-video source by construction; an unconfirmed
         -- inferred term of any other shape still may not cross on
         -- video evidence alone.
         and (
           assertion.assertion_origin <> 'inferred'
           or assertion.concept_id is null
           or coalesce(preference.display_state, 'default') = 'confirmed'
           or exists (select 1 from ontology.concepts travel_concept
                       where travel_concept.id = assertion.concept_id
                         and travel_concept.concept_key like 'travel:%')
           or (current_score.semantic_run_id is not null
               and semantic_private.concept_has_non_video_witness(
                     current_score.semantic_run_id, assertion.concept_id))
         )
         -- 0457: the rollup dimensions cross to nobody. `list_assertions`
         -- withholds the `era:`, `sphere:` and `scene:` prefixes from the
         -- owner's own Memories page — "withheld until somebody decides it
         -- belongs" — and the matching surface may not be more permissive
         -- than the page that shows a person their own terms. A user's own
         -- typed term has no concept and survives, as it does there.
         and (assertion.concept_id is null or not exists (
           select 1 from ontology.concepts rollup_concept
            where rollup_concept.id = assertion.concept_id
              and (rollup_concept.concept_key like 'era:%'
                   or rollup_concept.concept_key like 'sphere:%'
                   or rollup_concept.concept_key like 'scene:%')))
         and coalesce(revision.preferred_label, user_term.label) is not null
    ) as permitted;
$function$
;

commit;
