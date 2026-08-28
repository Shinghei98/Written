-- 0467 — one song's echo is not a franchise claim.
--
-- **The owner's direction (2026-08-28), given over a live trace**: the
-- 0459 bar plus the 0462 conduction let a single Spotify top track
-- assert its whole film — Chungking Express arrived on a card from one
-- Faye Wong cover, correct in that instance and far too cheap as a
-- rule. A *derived* work now needs at least two distinct
-- directly-evidenced concepts agreeing (two Chungking Express-related
-- terms, in the owner's words) before it crosses the eligibility bar;
-- one source stays `candidate`, where Memories still shows it and a
-- second related term — or the person's own keep — promotes it.
--
-- Works only, and derived only: a directly-evidenced work keeps the
-- plain bar (the person played the thing itself), and a genre
-- accumulating one artist's library through `broader` is a different
-- shape of evidence. The scorer already counts distinct contributing
-- concepts per propagated arrival; the rule reads what was always
-- recorded.
--
-- Scorer 0.25.1 carries the parameter and asks for the recompute — the
-- re-score is what demotes the standing single-witness franchises, per
-- the rule that a change which only withholds arrives too late.

begin;

do $$
declare old_row ontology.model_versions%rowtype;
begin
  select * into old_row from ontology.model_versions
   where model_role = 'scorer' and status = 'active'
   order by created_at desc limit 1;
  if old_row.id is null then
    raise notice '0467: no active scorer stands; the model rows wait';
  else
    update ontology.model_versions set status = 'retired'
     where id = old_row.id;
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), old_row.model_key,
            '0.25.1', 'scorer', 'active',
            coalesce(old_row.parameters, '{}'::jsonb)
              || jsonb_build_object('derived_work_minimum_sources',
                   '2 — a propagation-only work needs two distinct '
                   || 'directly-evidenced concepts agreeing before it is '
                   || 'eligible; one stays candidate (owner 2026-08-28)'));
  end if;
end;
$$;

do $$
begin
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0467: a derived work needs two witnesses to cross the bar');
end;
$$;

commit;
