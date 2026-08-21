-- 0297 — a foreign term reads English-first on the review card.
--
-- The owner's presentation rule: English first, original in parentheses —
-- "Jay Chou (周杰倫)". The model has emitted english_label/original_label
-- since v7 and the dictionary stores them; the review card never read them.
-- `begin_calibration` labeled a provisional with its canonical surface, which
-- for a CJK mention is the CJK string, so the suggested list showed 路飛
-- where it should show Luffy (路飛).
--
-- The card now joins the dictionary on the provisional's own key and composes
-- the reading, and also returns the two raw fields so the app can draw its
-- own rendering later without a second schema change. A term with no English
-- form — or whose English form is the label already — reads as before.
-- Concept-backed items keep `preferred_label`, which is already the English
-- vocabulary. Terms extracted before v7 have no dictionary labels and fall
-- through to the surface, honestly: a translation this system never received
-- is not invented here.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);

  if position('presumed_terms' in body) > 0 then
    raise notice '0297: the card already reads the dictionary';
    return;
  end if;

  patched := replace(body,
    E'        ''label'', coalesce(cr.preferred_label, pe.canonical_label),',
    E'        ''label'', case\n'
    || E'          when pt.english_label is not null\n'
    || E'               and pt.english_label\n'
    || E'                   is distinct from coalesce(cr.preferred_label,\n'
    || E'                                             pe.canonical_label)\n'
    || E'          then pt.english_label || '' ('' ||\n'
    || E'               coalesce(pt.original_label, cr.preferred_label,\n'
    || E'                        pe.canonical_label) || '')''\n'
    || E'          else coalesce(cr.preferred_label, pe.canonical_label)\n'
    || E'        end,\n'
    || E'        ''english_label'', pt.english_label,\n'
    || E'        ''original_label'', pt.original_label,');
  if patched = body then
    raise exception '0297: the label is not the one 0280 built';
  end if;
  body := patched;

  patched := replace(body,
    E'    left join semantic_private.provisional_entities pe\n'
    || E'      on pe.id = utc.provisional_entity_id',
    E'    left join semantic_private.provisional_entities pe\n'
    || E'      on pe.id = utc.provisional_entity_id\n'
    || E'    left join semantic_private.presumed_terms pt\n'
    || E'      on pt.normalized_label = pe.normalized_label\n'
    || E'     and pt.family = pe.family');
  if patched = body then
    raise exception '0297: the provisional join is not the one 0263 wrote';
  end if;
  execute patched;
end;
$$;

do $$
declare
  fn text;
begin
  fn := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);
  if position('presumed_terms' in fn) = 0
     or position('english_label' in fn) = 0 then
    raise exception '0297: the card still cannot read a term''s English name';
  end if;
end;
$$;
