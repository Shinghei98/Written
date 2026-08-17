-- 0222 — a catalogue drawer is not a taste.
--
-- ## What happened
--
-- `0220` shipped the genre rollup having written, and argued from, this:
--
--   > It also disposes of the container worry on its own: `genre:apple_19`
--   > ("Worldwide", the one real catalogue bucket here) reaches four artists and
--   > **does not cross**.
--
-- On the first real run it scored **0.391** and became an eligible assertion
-- about a live account. The prediction was made by counting artists, which is
-- the exact error the paragraph above it in that same migration warns against —
-- `w` is not the artist count, every mapping being multiplied by
-- `recency_weight`, `default_reliability` and `action_weight`. Having named the
-- mistake, the same file made it again two paragraphs later, in the argument for
-- removing the only guard against it.
--
-- **The removal still stands.** That guard silenced a parent wherever the account
-- held any child, which struck out `genre:pop` at 227 independent artists and
-- `genre:classical` at 98 while letting "Worldwide" through — the one case it
-- existed for. It was never the fix. What was wrong was the claim that nothing
-- needed to replace it.
--
-- ## Why this is in the ontology and not in the resolver
--
-- `0220` and `CLAUDE.md` both say a container genre is a vocabulary problem, and
-- that part was right. Nothing in a **key** separates `genre:apple_19` from
-- `genre:apple_1004` (Indie Rock) or `genre:apple_1263` (Bollywood). Nothing in
-- a **kind** separates it from `genre:baroque`. And **child count is measurably
-- useless**: "Worldwide" has 4 children, `baroque` has 45 and is a perfectly
-- good thing to say about somebody.
--
-- There is no derivable signal, so this is authored judgement — the same class
-- as the merge list in `0198`, and kept short for the same reason. What makes it
-- honest is *where* it is written: a property of the concept, in the ontology,
-- read by every consumer, rather than a list of literals inside one resolver
-- where **the failure mode of a deny-list is silence**.
--
-- ## `inference_policy` already had the word
--
-- The column has carried `inferable | review_required | explicit_only |
-- prohibited` since the schema was written, and four concepts already use
-- `explicit_only`. It means exactly what a container genre needs: **a person may
-- claim this about themselves; the system may never infer it.** So "Worldwide"
-- stays in the vocabulary, stays scored, stays available as a parent in the
-- graph and as evidence for its children — and stops being a claim about
-- anybody.
--
-- **`review_required` is deliberately not included** in what the scorer refuses.
-- 890 concepts carry it today and every one is assertable; treating it as a
-- refusal would silently empty most of the system. Only the two words that
-- already mean "not from inference" are honoured.
--
-- ## The two named, and the second is a debt
--
-- `genre:apple_19` — Apple's "Worldwide", a catalogue bucket.
--
-- `genre:asian_music` — recorded in `CLAUDE.md` as *"a container in all but
-- name, parent of four genres it scores alongside, and the hub rule cannot catch
-- it because its kind is `genre`"*. It has been a known gap since it was written
-- down and is eligible on a live account right now. It is the same defect and it
-- is fixed by the same line.
--
-- ## Retiring what is already asserted
--
-- A rule that only withholds arrives too late for exactly the rows it was
-- written for — a scorer that refuses to assert containers leaves standing
-- container assertions untouched. So the inferred ones are demoted to
-- `inactive`, which is what `api.list_assertions` filters on. **Retiring is not
-- deleting**, and `explicit_addition` rows are left alone: what somebody typed
-- about themselves is not what was read off their phone, and `explicit_only` is
-- precisely the policy that still permits it.

begin;

-- ---------------------------------------------------------------------------
-- 1. A new version, because a published one is immutable.
-- ---------------------------------------------------------------------------

do $$
declare
  old_version_id  uuid;
  new_version_id  uuid;
  current_version text;
  next_version    text;
  containers      constant text[] := array['genre:apple_19', 'genre:asian_music'];
  present         integer;
  changed         integer;
  carried         integer;
  before_count    integer;
begin
  select id, version into old_version_id, current_version
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise exception '0222: there is no published ontology version';
  end if;

  select count(*) into present
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = old_version_id
     and c.concept_key = any (containers);

  -- **Conditional on the vocabulary existing**, so this replays from empty.
  -- Asserting the transformation rather than the precondition is what `0173`
  -- and eight others had to be repaired to do.
  if present = 0 then
    raise notice '0222: no container genre in %; nothing to withhold', current_version;
    return;
  end if;

  select count(*) into before_count
    from ontology.concept_revisions where ontology_version_id = old_version_id;

  next_version := split_part(current_version, '.', 1) || '.'
               || (split_part(current_version, '.', 2)::integer + 1)::text || '.0';

  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'Container genres are explicit_only: a person may claim them, the '
          || 'system may not infer them. Copied forward from ' || current_version || '.');
  select id into new_version_id from ontology.versions where version = next_version;

  -- **The helper `0221` added, used by the migration immediately after it.**
  -- That is the point of it existing: the exclusion and the fifth table are
  -- carried without this file having to remember either.
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  select count(*) into carried
    from ontology.concept_revisions where ontology_version_id = new_version_id;
  if carried <> before_count then
    raise exception '0222: carried % revision(s) forward, expected %',
      carried, before_count;
  end if;

  update ontology.concept_revisions r
     set inference_policy = 'explicit_only'
    from ontology.concepts c
   where c.id = r.concept_id
     and r.ontology_version_id = new_version_id
     and c.concept_key = any (containers)
     and r.inference_policy <> 'explicit_only';
  get diagnostics changed = row_count;

  perform ontology.publish_version(new_version_id);

  raise notice '0222: published %, % container genre(s) set explicit_only',
    next_version, changed;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Scorer 0.16.0 — the code that honours it.
-- ---------------------------------------------------------------------------

insert into ontology.model_versions (id, model_key, version, model_role, code_hash, parameters, status)
select extensions.gen_random_uuid(), 'evidence_weighted_scorer', '0.16.0', 'scorer', null,
       old.parameters || jsonb_build_object(
         'inference_policy_withholding',
         'A concept whose revision carries inference_policy of explicit_only or '
         || 'prohibited is scored and never asserted: the score is written, the '
         || 'assertion state is candidate, and the refusal is counted as '
         || 'policy_withheld rather than skipped silently. review_required is '
         || 'deliberately not included — 890 concepts carry it and all are '
         || 'assertable, so honouring it would empty most of the system. This '
         || 'exists because genre:apple_19 (Apple''s "Worldwide", a catalogue '
         || 'bucket) scored 0.391 and was asserted about a real person, and '
         || 'nothing in a concept key, a kind or a child count separates a '
         || 'drawer from a taste: "Worldwide" has four children and genre:baroque '
         || 'has forty-five. The judgement is therefore authored, and it is '
         || 'written on the concept in the ontology where every reader sees it '
         || 'rather than as literals in a resolver.'
       ),
       'active'
  from (
    select * from ontology.model_versions
     where model_key = 'evidence_weighted_scorer'
     order by string_to_array(version, '.')::integer[] desc
     limit 1
  ) old
on conflict (model_key, version) do update
   set parameters = ontology.model_versions.parameters || excluded.parameters,
       status = 'active';

update ontology.model_versions set status = 'retired'
 where model_key = 'evidence_weighted_scorer'
   and status = 'active'
   and version <> '0.16.0';

-- ---------------------------------------------------------------------------
-- 3. Retire what is already standing.
-- ---------------------------------------------------------------------------
--
-- **Inferred only.** `explicit_addition` is the same fact as a `source = 'user'`
-- row — what somebody typed about themselves — and `explicit_only` is the policy
-- that still permits exactly that.

update semantic_private.user_assertions ua
   set machine_state = 'inactive'
  from ontology.concepts c
 where c.id = ua.concept_id
   and c.concept_key in ('genre:apple_19', 'genre:asian_music')
   and ua.assertion_origin = 'inferred'
   and ua.machine_state <> 'inactive';

-- ---------------------------------------------------------------------------
-- 4. Prove it, both ways.
-- ---------------------------------------------------------------------------

do $$
declare
  published_id uuid;
  withheld     integer;
  inferable    integer;
  standing     integer;
  actives      integer;
  enqueued     integer;
begin
  select count(*) into actives
    from ontology.model_versions
   where model_key = 'evidence_weighted_scorer' and status = 'active';
  if actives <> 1 then
    raise exception '0222: expected one active scorer, found %', actives;
  end if;

  select id into published_id from ontology.versions where status = 'published';

  select count(*) into withheld
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = published_id
     and c.concept_key in ('genre:apple_19', 'genre:asian_music')
     and r.inference_policy = 'explicit_only';

  -- **And the genres that must stay assertable, which is the other half.**
  -- A predicate that withheld everything would satisfy the check above and
  -- empty the product; `genre:baroque` has more children than "Worldwide" and
  -- is exactly what must survive.
  select count(*) into inferable
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = published_id
     and c.concept_key in ('genre:baroque', 'genre:pop', 'genre:classical')
     and r.inference_policy = 'inferable';

  if withheld > 0 and inferable = 0 then
    raise exception
      '0222: containers were withheld and no ordinary genre stayed inferable';
  end if;
  if withheld = 0 and exists (
       select 1 from ontology.concept_revisions r
        join ontology.concepts c on c.id = r.concept_id
       where r.ontology_version_id = published_id
         and c.concept_key = 'genre:apple_19') then
    raise exception '0222: genre:apple_19 is published and was not withheld';
  end if;

  select count(*) into standing
    from semantic_private.user_assertions ua
    join ontology.concepts c on c.id = ua.concept_id
   where c.concept_key in ('genre:apple_19', 'genre:asian_music')
     and ua.assertion_origin = 'inferred'
     and ua.machine_state <> 'inactive';
  if standing <> 0 then
    raise exception '0222: % inferred container assertion(s) still stand', standing;
  end if;

  select semantic_private.enqueue_recompute_on_analysis_change(
           'scorer 0.16.0: a catalogue drawer is not a taste'
         ) into enqueued;

  raise notice '0222: % container(s) withheld, % ordinary genre(s) still inferable, % job(s) enqueued',
    withheld, inferable, enqueued;
end;
$$;

commit;
