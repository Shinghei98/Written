-- 0148 — a typed term finds its mother concept.
--
-- **`add_assertion` has always taken either a concept or a label, and the app
-- has only ever sent the label.** Its signature is
-- `(p_target_concept_id, p_new_label)` with a `num_nonnulls(...) <> 1` guard, so
-- attaching a typed term to real vocabulary needed no new write path — it
-- needed a way to *find* the concept, which nothing offered. Every term
-- somebody typed therefore became a `user_term`: a private string with no
-- concept, no kind, no block and no relationship to the identical concept the
-- machine may already assert about them.
--
-- That is visible on the page. A typed `Hearthstone` and an inferred
-- `work:hearthstone` would sit as two unrelated rows, and `0145`'s blocks put
-- the typed one under "Other" — because a `user_term` has no `broader` edge to
-- walk.
--
-- ## Exact matches only, which is this codebase's standing rule
--
-- `resolve_alias`'s `SequenceMatcher` fallback burned a 300-second Lambda on
-- arbitrary tags and every result was discarded anyway, since the fuzzy path
-- returns only `CANDIDATE`; `0078`'s resolver model records
-- `whole_tag_only, fuzzy: false`. The same discipline applies with more force
-- here, because this match is acted on immediately and silently: a fuzzy hit
-- would file somebody's term under a concept they did not name.
--
-- So the match is on `normalized_label`, whole, case-folded, against the
-- published version's **active** labels. Anything else comes back empty and the
-- caller falls through to `p_new_label`, which is the behaviour that exists
-- today — this is strictly additive.
--
-- ## Restricted to the kinds Memories draws, which is a kindness rather than a
-- ## limitation
--
-- `list_assertions` shows `creator`, `work` and `activity`. If typing `K-pop`
-- resolved to `genre:k_pop`, the assertion would be created, be perfectly
-- valid, and **never appear** — the person would watch their term vanish and
-- conclude the feature is broken. A `user_term` at least draws. So a genre
-- match is deliberately not offered, and the term stays theirs.
--
-- ## The block is a hint, never a constraint
--
-- The caller passes the block whose card was tapped, and it only breaks ties:
-- a term matching two concepts prefers the one already under that heading.
-- **It cannot move a term.** Typing `Bach` under Games & Play resolves to
-- `creator:johann_sebastian_bach` and the row appears under Music, because the
-- ontology decides where a concept lives and a tap on a card is not an argument
-- about that. The alternative — letting the tapped card place the term — would
-- make the same word mean different things depending on where somebody happened
-- to be scrolling.

begin;

create or replace function api.resolve_term_for_addition(
  p_text text,
  p_block_key text default null
)
returns table(concept_id uuid, concept_key text, label text, block_key text)
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_version_id uuid;
  v_needle text;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  -- The same gate every other Memories read passes, so a surface that is off
  -- cannot be probed for vocabulary through the back door.
  perform semantic_private.assert_surface_allowed('memories');

  v_needle := lower(btrim(coalesce(p_text, '')));
  if char_length(v_needle) < 2 then
    return;
  end if;

  select id into v_version_id from ontology.versions where status = 'published';
  if v_version_id is null then
    return;
  end if;

  -- **One row per concept, not per label.** A concept may carry several
  -- aliases that normalize to the same string — `creator:kazuha` holds both
  -- `Kazuha` and `kazuha`, which case-fold identically — so the join produces
  -- one row per matching *label* and the caller would be offered the same
  -- concept twice. Caught by the probe below, which expected one match and got
  -- two; a picker showing a name twice is precisely the confusion this lookup
  -- exists to prevent.
  --
  -- `distinct on` needs its leading order to be the key it dedupes by, so the
  -- ranking happens outside: inside, keep the best label per concept; outside,
  -- rank the concepts.
  return query
  select matched.id, matched.key, matched.display, matched.block
  from (
    select distinct on (c.id)
           c.id as id,
           c.concept_key as key,
           revision.preferred_label as display,
           semantic_private.concept_block(c.id, v_version_id) as block,
           (label.label_type = 'preferred') as is_preferred
    from ontology.concept_labels as label
    join ontology.concepts as c on c.id = label.concept_id
    join ontology.concept_revisions as revision
      on revision.concept_id = c.id
     and revision.ontology_version_id = v_version_id
    where label.ontology_version_id = v_version_id
      and label.status = 'active'
      and lower(label.normalized_label) = v_needle
      -- The same three kinds `list_assertions` draws. A match the page would
      -- refuse to show is worse than no match at all.
      and revision.concept_kind in ('creator', 'work', 'activity')
      -- The same eligibility `add_assertion` demands of a concept, asked here
      -- so the caller is never offered something the write would then refuse.
      and revision.status = 'active'
      and revision.sensitivity <> 'sensitive'
      and revision.inference_policy <> 'prohibited'
    order by c.id, (label.label_type = 'preferred') desc
  ) as matched
  order by
    -- The block hint, breaking ties only.
    (matched.block is not distinct from p_block_key) desc,
    -- Then a preferred label over an alias: `Kazuha` typed exactly should find
    -- the concept named Kazuha rather than one that merely lists it.
    matched.is_preferred desc,
    matched.key
  limit 5;
end;
$function$;

revoke all on function api.resolve_term_for_addition(text, text) from public;
revoke all on function api.resolve_term_for_addition(text, text) from anon;
grant execute on function api.resolve_term_for_addition(text, text) to authenticated;

do $$
declare
  hits integer;
  chosen text;
  blocked text;
  probe_user uuid;
begin
  -- **The probe has to be somebody**, because the function refuses an
  -- unauthenticated caller and a migration runs as none. `auth.uid()` reads
  -- `request.jwt.claims`, so the claim is set for this transaction only —
  -- `set_config(..., true)` is local and unwinds at commit, and the id is read
  -- from the table rather than written here so this cannot outlive the accounts
  -- it names.
  select id into probe_user from public.users order by created_at limit 1;
  if probe_user is null then
    raise notice 'no account to probe with; the lookup is unverified here';
    return;
  end if;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', probe_user::text)::text, true);

  -- **Proved by calling it, both ways, over real vocabulary.** `0102` asserted
  -- that a function *mentions* a flag and `0117` asserted a predicate over an
  -- empty table; both passed while being wrong.
  select count(*) into hits
  from api.resolve_term_for_addition('Kazuha', null);
  if hits <> 1 then
    raise exception 'an exact creator label resolved to % rows, expected 1', hits;
  end if;

  -- A genre must not be offered, or the term is added and never drawn.
  select count(*) into hits
  from api.resolve_term_for_addition('K-Pop', null);
  if hits <> 0 then
    raise exception 'a genre was offered for addition (% rows)', hits;
  end if;

  -- Nonsense resolves to nothing, which is the path that keeps today's
  -- behaviour: the caller falls back to a free label.
  select count(*) into hits
  from api.resolve_term_for_addition('qzxwv not a concept', null);
  if hits <> 0 then
    raise exception 'a nonsense string matched % concepts', hits;
  end if;

  -- And no fuzz: a near miss is a miss.
  select count(*) into hits
  from api.resolve_term_for_addition('Kazuh', null);
  if hits <> 0 then
    raise exception 'a partial label matched; this lookup must be exact';
  end if;

  -- The block comes back with the concept, so the caller never has to guess
  -- where the row will land.
  select concept_key, block_key into chosen, blocked
  from api.resolve_term_for_addition('Kripparrian', 'hub:music');
  if chosen is distinct from 'creator:kripparrian' then
    raise exception 'Kripparrian resolved to %, not creator:kripparrian', chosen;
  end if;
  -- **The hint did not move it.** Asked under Music, it still answers Games —
  -- the ontology decides where a concept lives.
  if blocked is distinct from 'hub:games_play' then
    raise exception
      'the block hint moved a term: Kripparrian came back under % ', blocked;
  end if;
end
$$;

commit;
