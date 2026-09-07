-- 0471 — television has a family.
--
-- **The owner's question (2026-09-07): "would Qwen's current rules be able
-- to recognise TV shows — not TV series, but reality shows and
-- documentaries? And would they have recognised them as reality shows or
-- documentaries?"** No, and the enum itself was the reason: the wire's
-- families held anime, book, game, music_work and album under
-- `cardinal:work`, and nothing for television. A reality show could only
-- be filed as `work`, or as `franchise` whenever a person was said to
-- belong to it — which is exactly how SBS Inkigayo and M Countdown
-- arrived (0469). The only television typing the ontology ever held came
-- from Wikidata's instance-of on the handful of titles the dictionary
-- bridge matched: one `tv_series` in the whole published version.
--
-- The wire and the workbook moved in `mention_extract_v6`; this is the
-- half that lives here, in 0332's shape, carried into the four places the
-- database states the family vocabulary. Three families, all rooted at
-- `cardinal:work`, all stored as kind `work` with their own `work_type`,
-- the same shape anime already has:
--
--     tv_series    a scripted television series (drama, comedy)
--     tv_show      an unscripted programme: reality, variety, talk, game
--                  or music show
--     documentary  a documentary film or series
--
-- The line the owner drew — a show is not a series — is the line between
-- the first two; a documentary is its own family because it is factual
-- by intent and can be either a film or a series. Reality versus
-- documentary is therefore answered by the family; finer genre (dating
-- show, cooking competition, nature documentary) stays where §2.21 puts
-- every classification: a `broader` edge to the genre vocabulary 0346
-- imported, never an entity.
--
-- Nothing is retyped here. The works already standing keep whatever
-- `work_type` they carry; the next extraction run under v6 is what files
-- new sightings under the new families, and a later re-sort may read the
-- dictionary back as 0469 did. Widening a check constraint needs no
-- version publish and enqueues no recompute: no score's inputs moved.
begin;

-- ---------------------------------------------------------------------------
-- 1. The dictionary's check constraint.
-- ---------------------------------------------------------------------------
alter table semantic_private.presumed_terms
  drop constraint if exists presumed_terms_family_check;

alter table semantic_private.presumed_terms
  add constraint presumed_terms_family_check check (family in (
    'activity','album','anime','art','book','channel','culture','documentary',
    'event','event_type','field','franchise','game','game_category','group',
    'hub','music_recording','music_work','organization','person','place',
    'platform','sport','tour','tv_series','tv_show','work','unknown'
  ));

-- ---------------------------------------------------------------------------
-- 1b. The provisional's check — the same vocabulary, without `unknown`, as
--     0332 left it.
-- ---------------------------------------------------------------------------
alter table semantic_private.provisional_entities
  drop constraint if exists provisional_entities_family_check;

alter table semantic_private.provisional_entities
  add constraint provisional_entities_family_check check (family in (
    'activity','album','anime','art','book','channel','culture','documentary',
    'event','event_type','field','franchise','game','game_category','group',
    'hub','music_recording','music_work','organization','person','place',
    'platform','sport','tour','tv_series','tv_show','work'
  ));

-- ---------------------------------------------------------------------------
-- 1c. The role catalog's check (0407), with `unknown`.
-- ---------------------------------------------------------------------------
alter table semantic_private.provisional_projection_families
  drop constraint if exists provisional_projection_families_family_check;

alter table semantic_private.provisional_projection_families
  add constraint provisional_projection_families_family_check
  check (family = any (array[
    'activity','album','anime','art','book','channel','culture','documentary',
    'event','event_type','field','franchise','game','game_category','group',
    'hub','music_recording','music_work','organization','person','place',
    'platform','sport','tour','tv_series','tv_show','work','unknown']));

-- ---------------------------------------------------------------------------
-- 2. The kind -> root map. `rationale` is not null, deliberately (0291).
-- ---------------------------------------------------------------------------
insert into ontology.cardinal_root_map (concept_kind, root_id, rationale)
values
  ('tv_series', 'cardinal:work',
   'A scripted television series is a bounded released creation, the same '
   'shape as anime; stored as kind work with work_type tv_series.'),
  ('tv_show', 'cardinal:work',
   'An unscripted programme - reality, variety, talk, game or music show - '
   'is a released creation with a title of its own, not the event of one '
   'taping and not a franchise; stored as kind work with work_type tv_show.'),
  ('documentary', 'cardinal:work',
   'A documentary film or series is a released creation; the thing it '
   'documents takes its own family. Stored as kind work with work_type '
   'documentary.')
on conflict (concept_kind) do update
  set root_id = excluded.root_id, rationale = excluded.rationale;

-- ---------------------------------------------------------------------------
-- 3. The pin 0300 held and 0332 restated, restated once more on the
--    vocabulary that now stands. History is not edited.
-- ---------------------------------------------------------------------------
do $$
declare
  wire_map constant jsonb := '{
    "person": "person", "group": "group", "organization": "organization",
    "franchise": "franchise", "work": "work", "anime": "work",
    "tv_series": "work", "tv_show": "work", "documentary": "work",
    "book": "work", "game": "work", "music_work": "work", "album": "work",
    "sport": "activity", "activity": "activity",
    "art": "concept", "field": "concept",
    "place": "none", "culture": "concept", "event": "event", "tour": "event"
  }'::jsonb;
  entry record;
  ontology_root text;
begin
  for entry in select * from jsonb_each_text(wire_map) loop
    select coalesce(replace(m.root_id, 'cardinal:', ''), 'none')
      into ontology_root
      from ontology.cardinal_root_map m
     where m.concept_kind = entry.key;
    if not found then
      raise exception '0471: the ontology map does not know family %', entry.key;
    end if;
    if ontology_root <> entry.value then
      raise exception '0471: family % is % on the wire and % in the ontology',
        entry.key, entry.value, ontology_root;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Proven both ways, on real rows, inside this transaction — 0332's
--    probe, on the widened check. The probe rows are rolled back by the
--    sub-block's raise, never deleted (`presumed_terms_no_delete`).
-- ---------------------------------------------------------------------------
do $$
declare
  admitted boolean := false;
  refused  boolean := false;
begin
  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin)
    values ('0471 probe tv_show', '0471 probe tv_show', 'tv_show', 'inferred');
    admitted := true;
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then
      null;
    when check_violation then
      raise exception '0471: the widened check refused tv_show';
  end;

  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin)
    values ('0471 probe idea', '0471 probe idea', 'idea', 'inferred');
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when check_violation then
      refused := true;
    when sqlstate 'P0001' then
      null;
  end;

  if not admitted then
    raise exception '0471: tv_show was not admitted';
  end if;
  if not refused then
    raise exception '0471: a family nothing compiles was admitted';
  end if;
  raise notice '0471: the family check answered both ways';
end;
$$;

commit;
