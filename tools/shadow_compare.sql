-- Old display terms against new assertions — §8's third Phase 2 bullet.
--
-- Run in the dashboard SQL editor, or through any connection that can see
-- `semantic_private`. Replace the id in `subject` below.
--
-- **A .sql file rather than a tool, and the first draft was the tool.** It grew
-- a Python client posting to `/pg/query`, an endpoint Supabase projects do not
-- have — `semantic_private` is readable by no client role, nothing is granted on
-- the schema, and no view exposes it, so PostgREST cannot reach any of this. A
-- script that cannot run is worse than a statement that can, and the posture it
-- ran into is the posture working.
--
-- **Diagnostics only.** §8 says so outright, and adds *"optimize precision and
-- useful coverage, not agreement with the old substring model"*. Disagreement is
-- the output rather than the failure: the two paths are meant to differ, and the
-- question is which is wrong about what.
--
-- **The old side is what was published, not a re-implementation.**
-- `Ontology.terms` and `Ontology.classify` are Swift and run on the phone, so
-- comparing against them would mean porting substring matching into SQL and then
-- comparing this project against a guess at itself. `discovery_cards.interests`
-- is what that path actually put in front of people.
--
-- ## Measured on the owner's library, 2026-08-12
--
--   60 legacy terms, 53 assertions, 16 shared, 44 legacy-only, 37 semantic-only
--
--   28  no alias in the ontology        every one a pipe-joined credit string
--   15  resolves, scored below the bar  thin but real evidence
--    1  withdrawn by the scorer         Emil Gilels, one album
--
-- **Half the old card was strings no ontology could ever carry** — "English
-- Baroque Soloists, Monteverdi Choir & John Eliot Gardiner", "Berlin
-- Philharmonic & Herbert von Karajan", "LE SSERAFIM & j-hope" — while the
-- semantic path splits the credits and asserts the parts (Berlin Philharmonic
-- 0.698, LE SSERAFIM at breadth 2). Reading either count alone misses that
-- entirely, which is the argument for the reason column rather than a number.
--
-- The 15 below-bar terms are the real coverage question: JENNIE 0.239 on six
-- mappings, ILLIT 0.164 on four, ABBA 0.128 on three. Thin libraries, and the
-- legacy card showed them because it ranks by count with no floor at all.
-- Hilary Hahn is 0.002 — two rows on one album, so the same album-breadth rule
-- that keeps Hadelich at 0.816 drops her. That is the rule working on this
-- library, and it is exactly why the threshold wants re-measuring on a second.

with subject as (
  select 'eb769605-5e2c-4175-8b9d-e3864ceaafb1'::uuid as user_id
), legacy as (
  select distinct lower(trim(e ->> 'subject')) as term
    from public.discovery_cards, lateral jsonb_array_elements(interests) e
   where user_id = (select user_id from subject)
), semantic as (
  -- `subject` is read as a scalar subquery throughout rather than joined in.
  -- Written `from user_assertions a, subject join ontology.concepts …` the
  -- join binds to `subject` and Postgres refuses with `invalid reference to
  -- FROM-clause entry for table "a"` — a comma and a JOIN in one FROM clause
  -- do not associate the way they read.
  select distinct lower(coalesce(cr.preferred_label, c.concept_key)) as term,
         c.concept_key
    from semantic_private.user_assertions a
    join ontology.concepts c on c.id = a.concept_id
    left join ontology.concept_revisions cr on cr.concept_id = c.id
   where a.user_id = (select user_id from subject) and a.machine_state = 'eligible'
), legacy_only as (
  select l.term from legacy l
   where not exists (select 1 from semantic s where s.term = l.term)
), reasoned as (
  select o.term,
         case
           when m.concept_key is null then 'no alias in the ontology'
           when exists (
             select 1 from semantic_private.user_assertions a
               join ontology.concepts c2 on c2.id = a.concept_id
              where c2.concept_key = m.concept_key
                and a.user_id = (select user_id from subject)
                and a.machine_state = 'inactive'
           ) then 'withdrawn by the scorer'
           else 'resolves, scored below the bar'
         end as reason
    from legacy_only o
    -- `normalized_label` is the alias table's own lowercased form, so this asks
    -- the resolver's question rather than a similar-looking one of our own.
    left join lateral (
      select c.concept_key from ontology.concept_labels lb
        join ontology.concepts c on c.id = lb.concept_id
       where lb.normalized_label = o.term limit 1
    ) m on true
)
select 'in both' as bucket, count(*)::text as n, null::text as terms
  from legacy l join semantic s on s.term = l.term
union all
select 'semantic only', count(*)::text,
       string_agg(s.term, ' | ' order by s.term)
  from semantic s where not exists (select 1 from legacy l where l.term = s.term)
union all
select 'legacy only: ' || reason, count(*)::text,
       string_agg(term, ' | ' order by term)
  from reasoned group by reason
order by 1;
