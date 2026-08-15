-- 0197 — a topic can be named, unless it is an axis.
--
-- ## What this unblocks, and what it does not
--
-- `0108` filtered Memories to `creator`, `work` and `activity` on the owner's
-- reading that *"the terms shown should be well defined enough for user to
-- strike off or understand"*. That reading is right and is not being reversed.
-- What has changed is what the vocabulary is being asked to hold: archaeology,
-- architecture, pottery and Cubism are all things a person can name and strike
-- off, and not one of them is a creator, a work or an activity. `topic` is where
-- they land, and `topic` is filtered out.
--
-- The 14 `subject:*` concepts `0134` minted — bioinformatics, neuroscience,
-- statistics, machine learning — have been in exactly that position since the
-- day they were written, and `games_concepts.csv` records the workaround in its
-- own notes: Hearthstone is a `work` *"deliberately — `work` is both on that
-- allowlist and judged at the lower 0.25 bar."* A field of study has no such
-- dodge available.
--
-- **This makes nothing appear today, and that is worth stating plainly.**
-- Measured across both accounts before writing it:
--
--     topic assertions, prefix `scene:`      26      eligible
--     topic assertions, prefix `sphere:`      8      eligible
--     topic assertions, anything else         0
--     `subject:*` assertions, any state       0
--     `subject:*` concept scores            145, strongest 0.054
--
-- So the subjects are not withheld by their kind — they are two thirds of an
-- order of magnitude below the 0.35 bar, on 30 mappings. **Vocabulary was never
-- the binding constraint; evidence was**, and this migration does not pretend
-- otherwise. It removes the obstacle that would have made an imported breadth
-- slice invisible however well attested it turned out to be.
--
-- ## Why the exclusion is by key prefix and not by kind
--
-- Widening on `concept_kind` alone would have been a regression rather than an
-- improvement, and the measurement above is why: **every topic assertion that
-- exists today is a `scene:` or a `sphere:`**. All 34 of them are precisely what
-- `0108` removed — *"`sphere:anglophone` is a word this app invented, and `1990s
-- English-language` is not something anybody would say about themselves"* — so
-- the widening would have restored the entire set it was written to exclude and
-- added none of the set it is written to admit.
--
-- The kind cannot separate them, and `score.py` already says so, having reached
-- the same wall from the scorer's side:
--
--     **By key prefix rather than by kind**, because `era:`, `sphere:` and
--     `scene:` are all `concept_kind = 'topic'` — the kind cannot separate the
--     axis from the claim, and giving eras a kind of their own would rewrite
--     thirteen concepts that six migrations already reference.
--
-- That is `NEVER_ASSERTED_KEY_PREFIXES` in the scorer and this is its reader-side
-- twin, one prefix wider: `era:` is never asserted at all, while `sphere:` and
-- `scene:` are deliberately asserted and deliberately not nameable. The three
-- are excluded here by the same mechanism for the same reason.
--
-- **`genre` and `place` stay out, unchanged.** Genres are what the matching
-- surface reasons over and read as labels applied to somebody rather than terms
-- they would use; places were found invisible once already (`0157`) and are a
-- separate decision with a separate argument. This widens by one kind.
--
-- **No new eligibility bar.** `ELIGIBLE_STRENGTH_BY_KIND` keeps `work` at 0.25
-- and everything else at 0.35. A bar for `topic` would have to be set with no
-- labelled rows to set it from, which is the guess the `work` bar was careful
-- not to make: *"With both judged, 0.25 separates two labelled points rather
-- than guessing between two unlabelled ones."* There are no judged topics yet.
--
-- ## The rewrite
--
-- **`create or replace`, not a drop**, because the return type is unchanged —
-- fifteen columns, the same fifteen `0145` added `block_key` and `block_label`
-- to. `0145` had to drop the function and re-issue the grant; this does not, and
-- a grant that survives is one fewer way to ship a blank page.
--
-- The body below is `0145`'s, read back out of the live database first rather
-- than copied from the file, with exactly two differences: one join onto
-- `ontology.concepts` for the assertion's own key, and the `where` clause. The
-- `order by` is reproduced verbatim and asserted, because `0102` lost it doing
-- this and its own assertion counted columns, which cannot see ordering.

begin;

create or replace function api.list_assertions()
returns table(
  assertion_id uuid, predicate_key text, label text, origin text,
  display_state text, strength double precision, confidence double precision,
  breadth integer, stability double precision, surfacing_score double precision,
  display_payload jsonb, assertion_score_version_id uuid,
  ontology_version_id uuid, block_key text, block_label text
)
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  perform semantic_private.assert_surface_allowed('memories');
  return query
  select
    assertion.id,
    assertion.predicate_key,
    coalesce(revision.preferred_label, user_term.label),
    assertion.assertion_origin,
    coalesce(preference.display_state, 'default'),
    score.strength,
    score.confidence,
    score.breadth,
    score.stability,
    score.surfacing_score,
    score.display_payload,
    score.id,
    coalesce(score.ontology_version_id, assertion.created_ontology_version_id),
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
     where c.concept_key = semantic_private.concept_block(
             assertion.concept_id,
             coalesce(score.ontology_version_id,
                      assertion.created_ontology_version_id))
  ) as block on true
  left join ontology.concept_revisions as block_revision
    on block_revision.concept_id = block.id
   and block_revision.ontology_version_id = coalesce(
         score.ontology_version_id, assertion.created_ontology_version_id
       )
  where assertion.user_id = auth.uid()
    and assertion.machine_state in ('candidate', 'eligible')
    and coalesce(preference.display_state, 'default') <> 'suppressed'
    -- Nameable things only. A term the person typed has no concept and no kind,
    -- and is always theirs to see.
    --
    -- `topic` joins the allowlist, less the three axis families: an axis is
    -- something the scorer reasons with, not a claim anybody would make about
    -- themselves, and striking one off would silently reweigh everything else.
    and (
      assertion.user_term_id is not null
      or (
        revision.concept_kind in ('creator', 'work', 'activity', 'topic')
        and concept.concept_key not like 'era:%'
        and concept.concept_key not like 'sphere:%'
        and concept.concept_key not like 'scene:%'
      )
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
  order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at;
end;
$function$;

do $$
declare
  columns integer;
  version_id uuid;
  admitted integer;
  excluded_axis integer;
  unchanged integer;
begin
  select id into version_id from ontology.versions where status = 'published';

  -- The four properties this function has now lost once each between them: its
  -- column count, its ordering, its guard, and the escape hatch that keeps a
  -- user's own words on their own page. Asserted together every time it is
  -- replaced, as `0108` and `0145` both did.
  select count(*) into columns
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace,
       lateral unnest(coalesce(p.proargmodes, array[]::"char"[])) as mode
  where n.nspname = 'api' and p.proname = 'list_assertions' and mode = 't';
  if columns <> 15 then
    raise exception '0197: list_assertions returns % columns, expected 15', columns;
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'list_assertions'
       and pg_get_functiondef(p.oid) ilike
           '%order by coalesce(score.surfacing_score, 1.0) desc, assertion.created_at%'
  ) then
    raise exception '0197: list_assertions lost its order by in the rewrite';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'list_assertions'
       and pg_get_functiondef(p.oid) like '%assert_surface_allowed%'
  ) then
    raise exception '0197: list_assertions lost its surface guard';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'api' and p.proname = 'list_assertions'
       and pg_get_functiondef(p.oid) like '%assertion.user_term_id is not null%'
  ) then
    raise exception '0197: the kind filter would remove user-added terms';
  end if;

  -- **And the filter itself, answered both ways over the concepts that exist.**
  -- A check on a function's source text is not a check on its behaviour, and a
  -- predicate is not believed until it has been seen refusing something and
  -- accepting something else. So the clause is evaluated here against real rows
  -- rather than read back as a string: what it newly admits, what it still
  -- refuses, and what it leaves exactly as it was.
  select
    count(*) filter (
      where r.concept_kind = 'topic'
        and c.concept_key not like 'era:%'
        and c.concept_key not like 'sphere:%'
        and c.concept_key not like 'scene:%'),
    count(*) filter (
      where r.concept_kind = 'topic'
        and (c.concept_key like 'era:%'
          or c.concept_key like 'sphere:%'
          or c.concept_key like 'scene:%')),
    count(*) filter (where r.concept_kind in ('creator', 'work', 'activity'))
  into admitted, excluded_axis, unchanged
  from ontology.concept_revisions r
  join ontology.concepts c on c.id = r.concept_id
  where r.ontology_version_id = version_id and r.status = 'active';

  if admitted = 0 then
    raise exception '0197: the widened filter admits no topic, so it changes nothing';
  end if;
  if excluded_axis = 0 then
    raise exception '0197: no axis concept was refused, so the exclusion is untested';
  end if;
  if unchanged = 0 then
    raise exception '0197: the three original kinds resolve to nothing';
  end if;

  -- **It says nothing about what anybody will see, because today the answer is
  -- nothing.** Every topic assertion in the database is an axis, and the
  -- strongest `subject:*` score is 0.054 against a 0.35 bar. The change is a
  -- precondition for imported vocabulary, not a release of withheld terms, and
  -- a notice claiming otherwise would be the wrong record to leave behind.
  raise notice '0197: topic admitted — % nameable topic concept(s), % axis concept(s) still refused, % unchanged',
    admitted, excluded_axis, unchanged;
end
$$;

commit;
