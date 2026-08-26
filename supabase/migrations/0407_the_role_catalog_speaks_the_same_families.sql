-- 0407 — the role catalog speaks the same families as the dictionary.
--
-- **Found by the owner's question, 2026-08-26: the database still
-- recognized the obsolete `idea` and rejected `art` and `field`.**
-- True, in exactly one place: `provisional_projection_families`' check
-- constraint — the role catalog that decides which family a projection
-- mention's provisional gets — kept a pre-Cardinal vocabulary. `idea`
-- was allowed and used by nothing anywhere; `art`, `field` and 0371's
-- `unknown` were missing, so a role provisioning either modern family
-- could never be registered: a silent capability gap, not a data bug
-- (the six standing roles all use families both lists share).
--
-- The fix aligns the constraint verbatim with
-- `presumed_terms_family_check` — two vocabularies for one concept of
-- family is the drift this week keeps finding, and here they rejoin.
-- `idea` drops; no row carries it, so nothing moves.

begin;

alter table semantic_private.provisional_projection_families
  drop constraint provisional_projection_families_family_check;
alter table semantic_private.provisional_projection_families
  add constraint provisional_projection_families_family_check
  check (family = any (array[
    'activity','album','anime','art','book','channel','culture','event',
    'event_type','field','franchise','game','game_category','group','hub',
    'music_recording','music_work','organization','person','place',
    'platform','sport','tour','work','unknown']));

do $$
begin
  if exists (select 1 from semantic_private.provisional_projection_families
              where family = 'idea') then
    raise exception '0407: an idea row exists after all — this migration assumed none';
  end if;
  raise notice '0407: role catalog vocabulary aligned; idea retired unused';
end;
$$;

commit;
