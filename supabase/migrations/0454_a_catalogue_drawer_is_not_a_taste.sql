-- 0454 — a catalogue drawer is not a taste, and YouTube's drawers are drawers.
--
-- **Where "Entertainment" on a person came from.** YouTube stamps its
-- Wikipedia-derived topic slugs on nearly everything: 150 of one user's
-- liked videos carry `Entertainment`, 132 carry `Performing_arts` (every
-- music video does), 20 carry `Hobby`. Each is a permitted III.E.4 read,
-- and each contributes a sliver — so the umbrella accumulated strength
-- 0.87 from sheer frequency while `subject:physics`, stamped on almost
-- nothing but meaning something, starved at 0.04. The score measured how
-- often YouTube said the word, which for a taxonomy ceiling is frequency,
-- not taste.
--
-- **The remedy is the one `genre:apple_19` already named** (score.py, the
-- assertability note): said in the ontology, on the concept, where one
-- correction serves every reader. `explicit_only` — a person may claim
-- this, the system may never infer it: still scored, still a climb node
-- and evidence for its children, never a claim about anybody. The five
-- below are YouTube's top-level drawers; `lifestyle` and `music` carry no
-- assertion yet and would fire on the next person the same way.
--
-- **The standing assertions are demoted here, not left to the re-score** —
-- a rule that only withholds arrives too late for exactly the rows it was
-- written for. The recompute this migration enqueues then recomputes them
-- under the policy and keeps them candidate.
--
-- Asserted as a transformation: on a database with no published ontology
-- or none of these concepts, every statement is a no-op and the same
-- migration replays clean.

begin;

do $$
declare
  current_version text;
  current_version_id uuid;
  next_version text;
  new_version_id uuid;
  umbrella_keys text[] := array[
    'subject:entertainment', 'subject:performing_arts', 'subject:hobby',
    'subject:lifestyle', 'subject:music'];
  changed integer;
  wrong integer;
begin
  select version, id into current_version, current_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    return;  -- an empty database has nothing to retype; the replay is clean
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (gen_random_uuid(), next_version, current_version_id, 'draft',
          '0454: YouTube umbrella subjects become explicit_only — a drawer, not a taste.')
  returning id into new_version_id;

  perform ontology.copy_forward_version(current_version_id, new_version_id);

  update ontology.concept_revisions r
     set inference_policy = 'explicit_only'
    from ontology.concepts c
   where c.id = r.concept_id
     and r.ontology_version_id = new_version_id
     and c.concept_key = any(umbrella_keys);
  get diagnostics changed = row_count;

  -- The transformation, asserted: every one of these keys that exists at
  -- the new version now carries the policy. Zero existing is a clean replay.
  select count(*) into wrong
    from ontology.concept_revisions r
    join ontology.concepts c on c.id = r.concept_id
   where r.ontology_version_id = new_version_id
     and c.concept_key = any(umbrella_keys)
     and r.inference_policy <> 'explicit_only';
  if wrong > 0 then
    raise exception '0454: % umbrella concept(s) still inferable', wrong;
  end if;

  perform ontology.publish_version(new_version_id);

  -- Demote the standing claims the rule was written for.
  update semantic_private.user_assertions a
     set machine_state = 'candidate', updated_at = now()
    from ontology.concepts c
   where c.id = a.concept_id
     and c.concept_key = any(umbrella_keys)
     and a.machine_state = 'eligible';

  -- 0396: the published version asks for the recompute that will read it.
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || changed
    || ' umbrella subject(s) set explicit_only');
end $$;

commit;
