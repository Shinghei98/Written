-- 0332 — `idea` leaves the family vocabulary; `art` and `field` join it.
--
-- The owner's decisions of 2026-08-24, carried into the four places the
-- database states the family vocabulary. The wire and the workbook moved in
-- `qwen_extractor_v17` / `mention_extract_v5`; this is the half that lives here.
--
-- **`idea` is removed rather than forbidden**, and that is only safe because it
-- was never used: **0 rows in `presumed_terms`, 0 concepts with an `idea:`
-- key**, measured 2026-08-24. `music_recording` took the other route — kept in
-- the ontology, refused on the wire — because it *had* rows. A family with no
-- rows and no concepts is removable; one with either is not.
--
-- **The ten authored `idea:*` terms were not lost, they were duplicates.**
-- `idea:mathematics`, `idea:statistics`, `idea:neuroscience`,
-- `idea:bioinformatics`, `idea:architecture`, `idea:machine_learning`,
-- `idea:investing` and `idea:science` all name concepts this database already
-- publishes as `subject:*`; `idea:anime` duplicates `genre:anime`. They were
-- deleted from the workbook rather than retyped, because minting a name already
-- held under another splits one interest across two concepts.
--
-- **`art` and `field` are mapped onto vocabulary that already exists**, which is
-- the whole point of the shape they were given:
--
--     art   -> concept_kind topic, topic_axis movement   93 published movement:*
--     field -> concept_kind topic, topic_axis field     294 published subject:*
--
-- Neither gets a `concept_kind` of its own. That is deliberate: `topic` is
-- already on `api.list_assertions`'s allowlist, so these terms can be *seen*.
-- A kind of their own would have been truer to the taxonomy and invisible on
-- Memories until somebody noticed, which is the failure mode the allowlist has
-- by design — *"an internal kind appearing on a profile is worse than a
-- nameable one being missed, because only the first is invisible to whoever
-- added it."*

-- ---------------------------------------------------------------------------
-- 1. The dictionary's check constraint.
-- ---------------------------------------------------------------------------
alter table semantic_private.presumed_terms
  drop constraint if exists presumed_terms_family_check;

alter table semantic_private.presumed_terms
  add constraint presumed_terms_family_check check (family in (
    'activity','album','anime','art','book','channel','culture','event',
    'event_type','field','franchise','game','game_category','group','hub',
    'music_recording','music_work','organization','person','place','platform',
    'sport','tour','work'
  ));

-- ---------------------------------------------------------------------------
-- 1b. The provisional's check, which is the same vocabulary in a fourth place.
-- ---------------------------------------------------------------------------
-- **Found by the compiled-contract gate, not by reading.** The first draft of
-- this migration moved `presumed_terms` and stopped, and
-- `tools/replay_contracts.sh` refused the chain with three lines naming exactly
-- what was wrong: `provisional_entities.family permits 'idea', which no family
-- mapping declares`, and `art`/`field` declared but refused. Four tables state
-- this vocabulary — the wire schema, the workbook, `presumed_terms` and here —
-- and the gate is the only thing that compares them.
--
-- Safe for the same reason as `presumed_terms`: **0 provisionals carry `idea`**,
-- measured 2026-08-24.
alter table semantic_private.provisional_entities
  drop constraint if exists provisional_entities_family_check;

alter table semantic_private.provisional_entities
  add constraint provisional_entities_family_check check (family in (
    'activity','album','anime','art','book','channel','culture','event',
    'event_type','field','franchise','game','game_category','group','hub',
    'music_recording','music_work','organization','person','place','platform',
    'sport','tour','work'
  ));

-- ---------------------------------------------------------------------------
-- 2. The kind -> root map.
-- ---------------------------------------------------------------------------
delete from ontology.cardinal_root_map where concept_kind = 'idea';

-- `rationale` is `not null` on this table, and deliberately so: a kind's root
-- is a claim, and `0291` made every row state why. A null root is permitted
-- (five kinds have one); a null reason is not.
insert into ontology.cardinal_root_map (concept_kind, root_id, rationale)
values
  ('art', 'cardinal:concept',
   'An art form or style is an abstract subject, not the artwork and not the '
   'artist. Keyed movement:* to join the 93 published movements.'),
  ('field', 'cardinal:concept',
   'A field of study is an abstract discipline. Keyed subject:* to join the '
   '294 published subjects rather than mint a parallel set.')
on conflict (concept_kind) do update
  set root_id = excluded.root_id, rationale = excluded.rationale;

-- ---------------------------------------------------------------------------
-- 3. The pin `0300` holds, restated.
-- ---------------------------------------------------------------------------
-- `0300` asserts a hard-coded seventeen-entry map and is now wrong by two
-- entries. It is history and is not edited; this replaces the assertion it
-- makes, on the vocabulary that now stands.
do $$
declare
  wire_map constant jsonb := '{
    "person": "person", "group": "group", "organization": "organization",
    "franchise": "franchise", "work": "work", "anime": "work", "book": "work",
    "game": "work", "music_work": "work", "album": "work",
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
      raise exception '0332: the ontology map does not know family %', entry.key;
    end if;
    if ontology_root <> entry.value then
      raise exception '0332: family % is % on the wire and % in the ontology',
        entry.key, entry.value, ontology_root;
    end if;
  end loop;

  if exists (select 1 from ontology.cardinal_root_map where concept_kind = 'idea') then
    raise exception '0332: idea is still in the root map';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Proven both ways, on real rows, inside this transaction.
-- ---------------------------------------------------------------------------
-- **A constraint is not believed until it has been seen answering both ways.**
-- The widening must admit `art`, and it must still refuse a family nothing
-- compiles — otherwise a check that admits everything would pass every
-- assertion above.
-- **The probe rows are rolled back, never deleted.**
-- `presumed_terms_no_delete` refuses every delete — *"presumed terms are a
-- dictionary; weight one down, never delete it"* — and the first draft of this
-- block tried to tidy up after itself and was refused by that trigger, which is
-- the trigger working. A plpgsql sub-block is an implicit savepoint, so raising
-- out of it undoes the insert while leaving the variable set: the constraint is
-- exercised on a real row and the dictionary keeps nothing.
do $$
declare
  admitted boolean := false;
  refused  boolean := false;
begin
  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin)
    values ('0332 probe art', '0332 probe art', 'art', 'inferred');
    admitted := true;
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then
      null;                                   -- the insert is undone; `admitted` stands
    when check_violation then
      raise exception '0332: the widened check refused art';
  end;

  begin
    insert into semantic_private.presumed_terms
      (normalized_label, canonical_label, family, origin)
    values ('0332 probe idea', '0332 probe idea', 'idea', 'inferred');
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when check_violation then
      refused := true;                        -- refused, which is the point
    when sqlstate 'P0001' then
      null;                                   -- it was admitted: caught below
  end;

  if not admitted then
    raise exception '0332: art was not admitted';
  end if;
  if not refused then
    raise exception '0332: idea is still storable';
  end if;
end;
$$;
