-- 0302 — a foreign term reads in English and its own language(s), whatever
-- kind of thing it is, and one identity is one card.
--
-- 0297 composed `english (original)` from a single row and only where a
-- provisional had both. Two things were wrong with that, and the owner named
-- both (2026-08-21):
--
--   * **It stopped at people.** A work, a franchise, a show is as foreign as a
--     person: 路人超能100 should read `Mob Psycho 100 (モブサイコ100)`. The rule
--     is about the term, not about its family.
--   * **The native is the entity's own language, never the script the surface
--     happened to be written in.** That Chinese title is a Japanese work, so
--     the native form is モブサイコ100 and 路人超能100 is merely how one uploader
--     wrote it. The same rule keeps 金采源 out of `Kim Chaewon (김채원)`: it is
--     neither her English name nor her native one, so it merges for identity
--     and weight and never displays.
--
-- Both fall out of one decision: **the natives are the `original_label`s the
-- model stated**, gathered across the identity cluster 0301 built — never a
-- variant's own surface. A model that has no native form for a term states
-- none, and the label reads bare, which is the honest rendering of a term
-- nobody has told us a native name for.
--
-- The card also stops showing an identity twice. `review_item_is_coarse` now
-- refuses a candidate whose dictionary row is a non-canonical variant: the
-- canonical's card stands for the cluster, and the keep it earns is tallied
-- across every variant by 0301's pointer.

create or replace function semantic_private.integrated_term_label(p_term_id uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $$
  with canonical as (
    select coalesce(p.canonical_term_id, p.id) as id
      from semantic_private.presumed_terms p
     where p.id = p_term_id
  ),
  head as (
    select coalesce(nullif(btrim(p.english_label), ''), p.canonical_label)
             as english
      from semantic_private.presumed_terms p
      join canonical c on c.id = p.id
  ),
  -- **Only what was stated as an original.** A variant's own label is not a
  -- native form — it is a spelling somebody used — and the difference is the
  -- whole of the 金采源 case.
  natives as (
    select distinct btrim(v.original_label) as native
      from semantic_private.presumed_terms v
      join canonical c on coalesce(v.canonical_term_id, v.id) = c.id
     where v.original_label is not null
       and btrim(v.original_label) <> ''
       and lower(btrim(v.original_label)) <> lower((select english from head))
  )
  select case
           when (select count(*) from natives) = 0
             then (select english from head)
           else (select english from head) || ' ('
                || (select string_agg(native, '/' order by native) from natives)
                || ')'
         end
$$;

-- The card reads the cluster's label and the cluster's weight.
do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef('api.begin_calibration(integer)'::regprocedure);

  if position('integrated_term_label' in body) > 0 then
    raise notice '0302: the card already reads the integrated label';
    return;
  end if;

  patched := replace(body,
    E'''label'', case\n'
    || E'          when pt.english_label is not null\n'
    || E'               and pt.english_label\n'
    || E'                   is distinct from coalesce(cr.preferred_label,\n'
    || E'                                             pe.canonical_label)\n'
    || E'          then pt.english_label || '' ('' ||\n'
    || E'               coalesce(pt.original_label, cr.preferred_label,\n'
    || E'                        pe.canonical_label) || '')''\n'
    || E'          else coalesce(cr.preferred_label, pe.canonical_label)\n'
    || E'        end,',
    E'''label'', coalesce(\n'
    || E'          semantic_private.integrated_term_label(\n'
    || E'            coalesce(pt.canonical_term_id, pt.id)),\n'
    || E'          cr.preferred_label, pe.canonical_label),\n'
    || E'        ''cluster_weight'', (\n'
    || E'          select round(cw.weight::numeric, 3)\n'
    || E'            from semantic_private.presumed_term_cluster_weights cw\n'
    || E'           where cw.canonical_term_id\n'
    || E'                 = coalesce(pt.canonical_term_id, pt.id)),');
  if patched = body then
    raise exception '0302: the label expression is not the one 0297 wrote';
  end if;
  execute patched;
end;
$$;

-- One identity, one card: a non-canonical variant is not shown, because its
-- canonical is.
create or replace function semantic_private.review_item_is_coarse(p_candidate_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((
    select case
             -- **A variant defers to its canonical.** 0301's pointer is what
             -- makes 사쿠라 and Sakura one thing; showing both would ask the
             -- same question twice and split the answer.
             when exists (
               select 1 from semantic_private.presumed_terms pt
                where pt.normalized_label = pe.normalized_label
                  and pt.family = pe.family
                  and pt.canonical_term_id is not null)
               then false
             when pe.family is not null
               then pe.family not in ('work', 'album', 'music_work')
             when utc.concept_id is not null
               then exists (
                 select 1 from ontology.concept_revisions kcr
                  where kcr.concept_id = utc.concept_id
                    and kcr.ontology_version_id =
                        (select id from ontology.versions where status = 'published')
                    and kcr.concept_kind <> 'work')
             else false
           end
      from semantic_private.user_term_candidates utc
      left join semantic_private.provisional_entities pe
        on pe.id = utc.provisional_entity_id
     where utc.id = p_candidate_id), false)
$$;

-- Both readings, over real rows: a term with no stated native reads bare; a
-- cluster with two stated natives reads with both, ordered deterministically;
-- a spelling that was never anyone's original never appears.
do $$
declare
  head_id uuid; ja_id uuid; ko_id uuid; zh_id uuid;
  rendered text;
begin
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, english_label, origin, source_lanes)
  values ('0302 test head', 'person', '0302 test head', 'Test Head',
          'extracted', '{}')
  returning id into head_id;

  rendered := semantic_private.integrated_term_label(head_id);
  if rendered <> 'Test Head' then
    raise exception '0302: a term with no native read %', rendered;
  end if;

  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, english_label, original_label,
     origin, source_lanes)
  values ('0302 test ja', 'person', '0302 test ja', 'Test Head', '宮脇咲良',
          'extracted', '{}')
  returning id into ja_id;
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, english_label, original_label,
     origin, source_lanes)
  values ('0302 test ko', 'person', '0302 test ko', 'Test Head', '사쿠라',
          'extracted', '{}')
  returning id into ko_id;
  -- The third-script spelling: merged, and never a native.
  insert into semantic_private.presumed_terms
    (normalized_label, family, canonical_label, origin, source_lanes)
  values ('0302 test zh', 'person', '金采源', 'extracted', '{}')
  returning id into zh_id;

  insert into semantic_private.presumed_term_links
    (variant_term_id, canonical_term_id, basis)
  values (ja_id, head_id, 'authored'), (ko_id, head_id, 'authored'),
         (zh_id, head_id, 'authored');

  rendered := semantic_private.integrated_term_label(ko_id);
  if rendered <> 'Test Head (사쿠라/宮脇咲良)' then
    raise exception '0302: the integrated label read %', rendered;
  end if;
  if position('金采源' in rendered) > 0 then
    raise exception '0302: a third-script spelling reached the label';
  end if;
  -- Asking through any member of the cluster gives the same answer.
  if semantic_private.integrated_term_label(head_id) <> rendered then
    raise exception '0302: the label depends on which variant was asked';
  end if;

  if position('integrated_term_label' in
       pg_get_functiondef('api.begin_calibration(integer)'::regprocedure)) = 0 then
    raise exception '0302: the card does not read the integrated label';
  end if;
  if position('canonical_term_id' in
       pg_get_functiondef(
         'semantic_private.review_item_is_coarse(uuid)'::regprocedure)) = 0 then
    raise exception '0302: a variant can still claim its own card';
  end if;
end;
$$;
