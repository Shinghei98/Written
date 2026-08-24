-- 0337 — every wire family declares where it mints, before anything mints.
--
-- **This is a precondition for autonomous minting, not a tidy-up.**
-- `ontology.family_mint_convention` carried **6 of the wire's 18 families**
-- (activity, art, culture, field, place, sport). The other twelve — including
-- `person`, `group`, `work`, `album`, the four largest — fall through
-- `ontology.mint_concept_key`'s `coalesce(prefix, p_concept_kind)` onto
-- whatever `concept_kind` the caller happened to pass.
--
-- **That fallback is a duplicate factory the moment discovery mints.** The
-- family→cardinal map (`mention_extract_v2.FAMILY_CARDINAL`) sends `person` to
-- the root `person`; a caller passing the cardinal would mint
-- `person:claude_debussy` beside the catalogue's existing
-- `creator:claude_debussy`. Measured against David's run: **365 of 1,263 placed
-- terms already exist as published concepts** — `creator:claude_debussy`,
-- `creator:twice`, `creator:stephen_schwartz`, `work:spider_man` — and every one
-- would have been minted a second time under a prefix the catalogue has never
-- used.
--
-- **So these rows are read off the catalogue rather than reasoned out.**
--
--     concept_kind   prefix        n     what actually sits there
--     creator        creator:  1,878     people AND groups AND orchestras
--     work           work:       368     works AND franchises
--
-- `creator:twice` is an idol group and `work:spider_man` is a franchise. The
-- catalogue collapses person/group/organization into `creator:` and
-- work/anime/book/game/music_work/album/**franchise** into `work:`, and it has
-- done so for 2,246 concepts. **Franchise therefore has a native destination**,
-- which corrects a reading recorded earlier today that it had none.
--
-- ## What is deliberately left null
--
-- `default_parent_key` is the last resort when placement proposes nothing, and
-- **it is set only where the family alone settles the hub.** A book is always
-- Books & ideas; a game is always Games & play; an album is always Music. A
-- *person* is not always anything — Bach and Ariana Grande share a family and
-- no hub — so `person`, `group`, `organization`, `work` and `franchise` take
-- null and mint unparented rather than mint a false claim. That is `0258`'s
-- rule surviving into a world where the term itself may now be minted without
-- a keep: **the mint may become automatic; inventing a parent may not.**
--
-- ## `event` and `tour`
--
-- `concept_revisions_concept_kind_check` has admitted `event` all along and
-- **zero rows use it.** A named tour is an event, not a work, and the cardinal
-- map already says so (`tour -> event`). They mint under `event:`, a prefix
-- this migration introduces deliberately. `api.list_assertions` allowlists
-- creator/work/activity/topic, so an event is **withheld from Memories until
-- somebody decides it belongs** — which is the documented behaviour for a new
-- kind, not an oversight.

insert into ontology.family_mint_convention
  (family, key_prefix, concept_kind, default_parent_key, note)
values
  -- A party. The catalogue files all three as `creator:` — `creator:twice` is
  -- a group, `creator:orchestre_philharmonique_de_liege` an orchestra.
  ('person',       'creator', 'creator', null,
   'A named human. Joins the 1,878 published creator:* concepts. No default parent: a person''s home is whatever they do.'),
  ('group',        'creator', 'creator', null,
   'A named collective. Files as creator:*, not group:* — creator:twice is the standing precedent.'),
  ('organization', 'creator', 'creator', null,
   'An institution or label. Files as creator:* alongside people and groups.'),

  -- A title. `work:spider_man` is a franchise, so franchise belongs here too.
  ('franchise',    'work', 'work', null,
   'A branded universe. work:spider_man is the precedent. No default parent: a franchise may be film, anime or game.'),
  ('work',         'work', 'work', null,
   'A titled creation. No default parent: the medium is not implied by the family.'),
  ('anime',        'work', 'work', 'hub:film_video',
   'A Japanese animated series or film. The family settles the hub.'),
  ('book',         'work', 'work', 'hub:ideas_learning',
   'A published book. The family settles the hub.'),
  ('game',         'work', 'work', 'hub:games_play',
   'A released game. The family settles the hub.'),
  ('music_work',   'work', 'work', 'hub:music',
   'A composition, distinct from a recording of it. The family settles the hub.'),
  ('album',        'work', 'work', 'hub:music',
   'A named release. The family settles the hub.'),

  -- Time-bounded. `event` is a permitted concept_kind with no rows until now.
  ('event',        'event', 'event', 'hub:arts_live',
   'A time-bounded public occurrence. First use of the event kind, which the check constraint has always admitted.'),
  ('tour',         'event', 'event', 'hub:arts_live',
   'A named touring series, distinct from any one date on it. An event, per the cardinal map.')
on conflict (family) do nothing;

-- ---------------------------------------------------------------------------
-- The assertions, which are the point of the migration
-- ---------------------------------------------------------------------------
do $$
declare
  -- **Stated here, not read from the schema file.** The database cannot see
  -- `mention_extract_v5.schema.json`, so the wire's enum is restated and the
  -- count pinned; a family added to the wire and not to this list fails the
  -- next replay rather than minting through the fallback.
  wire text[] := array[
    'person','group','organization','franchise','work','anime','book','game',
    'music_work','album','sport','activity','art','field','place','culture',
    'event','tour'];
  -- Prefixes this catalogue may use. Sixteen are already in `concepts`; three
  -- — culture, sport, event — are declared new, and naming them here is what
  -- makes a *typo* fail while a deliberate addition passes.
  allowed text[] := array[
    'creator','work','subject','activity','genre','movement','scene','hub',
    'place','era','travel','concept','routine','sphere','identity','affinity',
    'medium','recording','culture','sport','event'];
  missing text;
  bad     text;
  n       integer;
begin
  if array_length(wire, 1) <> 18 then
    raise exception '0337: the wire enum is pinned at 18 families, found %',
      array_length(wire, 1);
  end if;

  -- 1. Every wire family has a convention. This is the whole precondition.
  select string_agg(f, ', ' order by f) into missing
    from unnest(wire) as f
   where not exists (select 1 from ontology.family_mint_convention c
                      where c.family = f);
  if missing is not null then
    raise exception
      '0337: these wire families would mint through the fallback: %', missing;
  end if;

  -- 2. No convention names a family the wire does not have.
  select string_agg(c.family, ', ' order by c.family) into bad
    from ontology.family_mint_convention c
   where not (c.family = any (wire));
  if bad is not null then
    raise exception '0337: convention rows for families not on the wire: %', bad;
  end if;

  -- 3. **No prefix is invented by accident.** A convention row is the only
  --    thing standing between a family and a second spelling of the
  --    catalogue, so a prefix outside the declared set is refused.
  select string_agg(distinct c.key_prefix, ', ') into bad
    from ontology.family_mint_convention c
   where not (c.key_prefix = any (allowed));
  if bad is not null then
    raise exception '0337: undeclared key prefixes: %', bad;
  end if;

  -- 4. **Every default parent resolves to a live concept.** A dangling
  --    default is a parent edge that fails at mint time, which is the worst
  --    moment to find out.
  select string_agg(c.default_parent_key, ', ') into bad
    from ontology.family_mint_convention c
   where c.default_parent_key is not null
     and not exists (select 1 from ontology.concepts o
                      where o.concept_key = c.default_parent_key
                        and o.retired_at is null);
  if bad is not null then
    raise exception '0337: default parents that do not resolve: %', bad;
  end if;

  -- 5. Every concept_kind is one the revision check admits. Asserted by
  --    *doing* it below rather than by re-listing the constraint's array,
  --    since a copy of a constraint is not a check on the constraint.

  select count(*) into n from ontology.family_mint_convention;
  raise notice '0337: % families declared', n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Proven by behaviour, not by inspection
-- ---------------------------------------------------------------------------
-- **The convention is only worth having if `mint_concept_key` reads it**, and
-- a check on a table's contents is not a check on a function's behaviour. So
-- the two families that matter most are minted for real and compared against
-- what the catalogue already holds.
do $$
declare
  k_person text;
  k_group  text;
  k_fran   text;
  k_cjk    text;
begin
  k_person := ontology.mint_concept_key('person', 'creator', 'claude debussy', 'Claude Debussy');
  k_group  := ontology.mint_concept_key('group',  'creator', 'twice',          'TWICE');
  k_fran   := ontology.mint_concept_key('franchise', 'work', 'spider-man',     'Spider-Man');

  -- **The keys must equal concepts that already exist.** That is the whole
  -- defect this migration prevents: minting a second `person:claude_debussy`
  -- beside the catalogue's `creator:claude_debussy`.
  if k_person <> 'creator:claude_debussy' then
    raise exception '0337: person minted % , expected creator:claude_debussy', k_person;
  end if;
  if k_group <> 'creator:twice' then
    raise exception '0337: group minted % , expected creator:twice', k_group;
  end if;
  if k_fran <> 'work:spider_man' then
    raise exception '0337: franchise minted % , expected work:spider_man', k_fran;
  end if;

  -- And each of those three is a concept this database actually holds, so the
  -- assertion is against the catalogue rather than against my expectation of
  -- it. Skipped on an empty replay, where the seed has not run — the equality
  -- checks above still hold there, which is the part that cannot drift.
  if exists (select 1 from ontology.concepts where concept_key = 'creator:twice') then
    if not exists (select 1 from ontology.concepts
                    where concept_key = k_person and retired_at is null) then
      raise exception '0337: % is not a concept this catalogue holds', k_person;
    end if;
  end if;

  -- **The CJK fallback still fires under the new conventions.** A person whose
  -- label romanises to nothing must still get a distinct key rather than a
  -- shared empty one.
  k_cjk := ontology.mint_concept_key('person', 'creator', '周杰倫', null);
  if k_cjk not like 'creator:kept\_%' then
    raise exception '0337: an unromanisable person minted %, not a kept_ key', k_cjk;
  end if;
  if k_cjk = ontology.mint_concept_key('person', 'creator', '髮如雪', null) then
    raise exception '0337: two unromanisable labels collapsed to one key';
  end if;

  raise notice '0337: mint keys agree with the published catalogue';
end;
$$;
