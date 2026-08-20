-- 0277 — a declared term reads the vocabulary that stands, not the one that
-- stood when it was made.
--
-- `0272` parented every kept concept and the terms stayed under "Other".
-- Both facts were true at once: `concept_block(concept, published)` answered
-- `genre:classical`, and `api.list_assertions` answered null — because it
-- reads the block at `coalesce(score.ontology_version_id,
-- assertion.created_ontology_version_id)`, and these assertions were created
-- at `0.36.1` while the edges live in `0.36.3`. The term was placed in the
-- vocabulary and the claim was still reading the vocabulary as it was.
--
-- **For an inferred assertion that pinning is the currency rule and stays.** A
-- score computed against one version must not be drawn under a section from
-- another; `0145` and the revision discipline exist for that.
--
-- **For a declared one it is wrong.** An `explicit_addition` has no score, no
-- observations and no currency check by construction — it is what somebody
-- said about themselves, and its section is presentation rather than
-- evidence. Pinning it to the version standing at the moment it was made means
-- it can never reach a parent minted afterwards, which for a kept term is the
-- parent its own keep implied moments later.
--
-- So the fallback becomes the published version, and the creation version
-- remains behind it for a row that somehow has neither. One expression, twice,
-- patched from the deployed body rather than restated — the rule this feature
-- has now paid for four times.

do $$
declare
  body text;
  patched text;
  hits integer;
begin
  body := pg_get_functiondef('api.list_assertions()'::regprocedure);

  hits := (length(body) - length(replace(body,
            'coalesce(score.ontology_version_id', ''))) 
          / length('coalesce(score.ontology_version_id');
  if hits <> 2 then
    raise exception '0277: expected 2 block-version expressions, found %', hits;
  end if;

  patched := replace(body,
    'coalesce(score.ontology_version_id,',
    'coalesce(score.ontology_version_id,'
      || ' (select pv.id from ontology.versions pv where pv.status = ''published''),');
  if patched = body then
    raise exception '0277: the block-version expression is not the one 0197 published';
  end if;
  execute patched;
end;
$$;

do $$
declare
  body text;
begin
  body := pg_get_functiondef('api.list_assertions()'::regprocedure);
  if position('pv.status = ''published''' in body) = 0 then
    raise exception '0277: the reader still cannot see the standing vocabulary';
  end if;
  -- The currency rule survives: a scored assertion still reads its own version
  -- first, and only a row without a score falls through to the published one.
  if position('coalesce(score.ontology_version_id, (select pv.id' in body) = 0 then
    raise exception '0277: the score version is no longer preferred';
  end if;
end;
$$;
