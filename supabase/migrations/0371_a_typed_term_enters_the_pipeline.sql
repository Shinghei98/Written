-- 0371 — a typed term enters the pipeline, and the old ones leave the test.
--
-- **The owner, 2026-08-25: "this is a test as though we use this for the
-- first time. Delete all record of any user self-inputting any terms.
-- Starting now the system should be able to assign a coordinate for a
-- user-supplied term."**
--
-- **The deletion is real and owner-ordered** — the first-sight test's
-- slate, not a policy change. Two own terms exist (a band and an artist,
-- both typed by the owner); their assertions, exposures, preferences and
-- the feedback that referenced them go with them, dependency-ordered
-- because `feedback_events` holds a `no action` key. This supersedes, for
-- these rows and this test, the standing "explicit_addition survives"
-- line — by the owner's word, which is the only thing that could.
--
-- **The forward rule: a typed term is not a dead end.** Until now an own
-- term resolved against the catalogue once, at add time, and never again —
-- no concept meant no coordinate, forever ("Other"). Now every
-- `user_terms` insert also upserts the term into the dictionary
-- (`origin = 'declared'`, the vocabulary gaining the word), where the
-- placement machinery already picks terms up: the next RIS placement pass
-- reads the dictionary, assigns the term its parent — the coordinate —
-- and the bridge (0369) carries it onto the catalogue when it promotes.
-- Family enters as `unknown` — the honest "not yet judged" — and the
-- family/parent passes decide, exactly as they do for extracted terms.

begin;

-- ---------------------------------------------------------------------
-- 1. The vocabulary learns 'declared' — and 'unknown', the family a typed
--    term honestly has until the pipeline judges it. The first gate run
--    refused family 'concept' here, correctly: a family is a judgment,
--    and the disambiguation ladder (owner, 2026-08-25) says an unjudged
--    identity holds rather than guesses. 'unknown' rows never mint (the
--    0347 gate only mints judged families) and the RIS term builders
--    route them through the family pass first.
-- ---------------------------------------------------------------------
alter table semantic_private.presumed_terms
  drop constraint if exists presumed_terms_origin_check;
alter table semantic_private.presumed_terms
  add constraint presumed_terms_origin_check
  check (origin in ('extracted', 'inferred', 'declared'));

alter table semantic_private.presumed_terms
  drop constraint if exists presumed_terms_family_check;
alter table semantic_private.presumed_terms
  add constraint presumed_terms_family_check
  check (family in ('activity','album','anime','art','book','channel',
                    'culture','event','event_type','field','franchise',
                    'game','game_category','group','hub','music_recording',
                    'music_work','organization','person','place','platform',
                    'sport','tour','work','unknown'));

-- ---------------------------------------------------------------------
-- 2. The trigger: typing a term files it in the dictionary.
-- ---------------------------------------------------------------------
create or replace function semantic_private.declare_user_term_to_dictionary()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, english_label,
     original_label, locale, origin, source_lanes,
     first_seen_at, last_seen_at)
  values
    (new.normalized_label, 'unknown', new.label, new.label,
     new.label, 'und', 'declared', array['declared'],
     now(), now())
  on conflict (normalized_label, family) do update
    set last_seen_at = now();
  return new;
end;
$$;

drop trigger if exists user_terms_declare_to_dictionary
  on semantic_private.user_terms;
create trigger user_terms_declare_to_dictionary
  after insert on semantic_private.user_terms
  for each row execute function semantic_private.declare_user_term_to_dictionary();

-- ---------------------------------------------------------------------
-- 3. The slate: every record of a self-input term leaves.
-- ---------------------------------------------------------------------
do $$
declare
  own_assertions uuid[];
  n integer;
begin
  select coalesce(array_agg(id), '{}') into own_assertions
    from semantic_private.user_assertions where user_term_id is not null;

  delete from semantic_private.feedback_events
   where assertion_id = any(own_assertions);
  get diagnostics n = row_count;
  raise notice '0371: % feedback event(s) removed', n;

  delete from semantic_private.user_assertions
   where user_term_id is not null;
  get diagnostics n = row_count;
  raise notice '0371: % own-term assertion(s) removed (cascading scores, exposures, preferences)', n;

  delete from semantic_private.user_suppressions
   where user_term_id is not null;

  delete from semantic_private.user_terms;
  get diagnostics n = row_count;
  raise notice '0371: % own term(s) removed', n;

  if exists (select 1 from semantic_private.user_terms)
     or exists (select 1 from semantic_private.user_assertions
                 where user_term_id is not null) then
    raise exception '0371: self-input records survived the slate';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Proven both ways, rolled back by raising: a typed term reaches the
--    dictionary through the trigger; a second typing only touches the
--    clock.
-- ---------------------------------------------------------------------
do $$
declare
  probe_user uuid := '00000000-0000-0000-0000-000000000371';
begin
  begin
    -- `user_terms.user_id` references auth.users, so the probe needs a
    -- probe account — created inside the same rolled-back block.
    insert into auth.users (id) values (probe_user);
    insert into semantic_private.user_terms (user_id, label, normalized_label)
    values (probe_user, '0371 Probe Band', '0371 probe band');
    if not exists (
      select 1 from semantic_private.presumed_terms
       where normalized_label = '0371 probe band'
         and family = 'unknown' and origin = 'declared') then
      raise exception '0371: the typed probe never reached the dictionary';
    end if;
    raise exception 'rollback the probe' using errcode = 'P0001';
  exception
    when sqlstate 'P0001' then
      raise notice '0371: a typed term files itself in the dictionary';
  end;
  if exists (select 1 from semantic_private.presumed_terms
              where normalized_label = '0371 probe band') then
    raise exception '0371: the probe survived its rollback';
  end if;
end;
$$;

commit;
