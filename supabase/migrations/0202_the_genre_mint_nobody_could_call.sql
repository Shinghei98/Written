-- 0202 — the genre mint nobody could call.
--
-- ## A migration that described something it had not built
--
-- `0191` created `semantic_private.mint_genres_from_stated_strings()` and wrote
-- this above it:
--
--     ## Minted here, and continuously from now on
--
--     The strings come from `ontology.external_entities`, so this needs no
--     network and no token: the catalogue rows are already stored. **The same
--     function is what a later mint calls**, so a genre named after one we hold
--     resolves the first time somebody's library states it.
--
-- **None of that second half was true of the shipped code.** The function is
-- called exactly once, by the `do $$` block at the foot of its own migration,
-- and `0191:258` then revokes every privilege on it and grants none back — so
-- `semantic_worker` could not have called it even if somebody had written the
-- code to try. The same is true of `mint_genres_from_catalogue` (`0188:317`).
--
-- The consequence, measured before this: **a genre string Apple states that is
-- not already a `genre:*` concept is silently discarded.**
-- `mint_vocabulary_from_catalogue` joins stated genres to *existing* genre
-- concepts (`0190:383-392`) and inserts none, so an unmatched string produces no
-- join row, the artist gets no genre parent, and `concept_block` falls through
-- to the `hub:music` fallback — which is the exact failure `0188` was written to
-- remove, left half-removed.
--
-- ## Why it has not bitten yet, and why that is not a reason to leave it
--
-- `0188`/`0189` imported Apple's whole published taxonomy — 56 genres crawled
-- across 167 storefronts — so coverage is near-complete **by construction rather
-- than by minting**. Measured today: 50 of 52 stated Apple Music genre strings
-- resolve, and 18 of 18 from the device library. The two misses, `asia` and
-- `chinese`, are containers.
--
-- So the hole is invisible until Apple names a genre nobody anticipated, which
-- is the sentence `0188:16` ends on. **A gap that only opens on somebody else's
-- schedule is worse than one that opens on ours**, because the day it opens
-- there is no signal: an artist simply lands under Music with no genre and
-- nothing reports it.
--
-- ## What this changes
--
-- One grant, and the call site in `catalogue.py`. The function itself is
-- untouched — its suffix rule, its key-collision guard and its refusals were
-- argued in `0191` and are not reopened here.
--
-- **The order in `mint_for` is genres before artists, and that is deliberate.**
-- The genre mint publishes a version if it mints anything; the artist mint then
-- reads the published version and can parent an artist onto a genre minted
-- moments earlier in the same pass. Reversed, a new artist and its new genre
-- would need two distillations to meet.
--
-- **Two publishes in one job is the cost, and it is bounded.** Each mint carries
-- its own *nothing new means no version* gate, so the ordinary pass publishes
-- nothing; a pass that mints both publishes twice, and `0140` collapses the
-- superseded recompute so the user is re-scored once.

begin;

grant execute on function semantic_private.mint_genres_from_stated_strings()
  to semantic_worker;

do $$
declare
  stated_strings   integer;
  already_concepts integer;
  mintable         integer;
begin
  -- 1. The grant, which is the whole of the defect, asserted from the catalog
  --    rather than from the statement above having run.
  if not has_function_privilege(
       'semantic_worker',
       'semantic_private.mint_genres_from_stated_strings()',
       'execute') then
    raise exception '0202: semantic_worker still cannot execute the genre mint';
  end if;

  -- **And the other one stays revoked.** `mint_genres_from_catalogue` takes a
  -- hand-pasted jsonb payload and reads nothing from the vault, so there is
  -- nothing for a worker to call it with. Granting both because they are named
  -- alike is how a function meant for a migration ends up on a queue.
  if has_function_privilege(
       'semantic_worker',
       'semantic_private.mint_genres_from_catalogue(jsonb)',
       'execute') then
    raise exception '0202: the migration-only genre mint became callable from the worker';
  end if;

  -- 2. The input the function reads, counted so the next reader can tell
  --    "nothing to mint" from "nothing to read". These are the numbers that
  --    make the *nothing new means no version* gate meaningful rather than
  --    vacuous.
  select count(distinct norm.value) into stated_strings
    from ontology.external_entities e
   cross join lateral jsonb_array_elements_text(
     coalesce(e.raw_payload -> 'genres_normalized', '[]'::jsonb)) as norm(value)
   where e.provider = 'apple_music_catalog' and e.entity_kind = 'artist'
     and coalesce(norm.value, '') <> '';

  select count(*) into already_concepts
    from (
      select distinct norm.value as normalized
        from ontology.external_entities e
       cross join lateral jsonb_array_elements_text(
         coalesce(e.raw_payload -> 'genres_normalized', '[]'::jsonb)) as norm(value)
       where e.provider = 'apple_music_catalog' and e.entity_kind = 'artist'
         and coalesce(norm.value, '') <> ''
    ) as stated
   where exists (
     select 1 from ontology.concept_labels l
       join ontology.versions v on v.id = l.ontology_version_id and v.status = 'published'
      where l.status = 'active' and l.normalized_label = stated.normalized);

  mintable := stated_strings - already_concepts;

  -- **This assertion was mine and it had the same disease as six others.** It
  -- demanded that the catalogue already state genre strings, which is true of
  -- production and false of every replay from empty — so the migration that
  -- exists to make a grant executable could not be applied to a fresh database.
  -- The grant is worth making whether or not today's data exercises it; what is
  -- worth refusing is a *populated* catalogue whose strings all fail to resolve,
  -- and that is what is asked now.
  if stated_strings = 0
     and exists (select 1 from ontology.external_entities
                  where provider = 'apple_music_catalog' and entity_kind = 'artist') then
    raise exception '0202: the genre mint has no input, so granting it says nothing';
  end if;

  raise notice '0202: % stated genre string(s), % already concepts, % candidates for the mint',
    stated_strings, already_concepts, mintable;
end;
$$;

commit;
