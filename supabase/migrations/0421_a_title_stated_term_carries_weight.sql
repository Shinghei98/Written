-- 0421 — a term the title states carries weight.
--
-- **The owner's standing rule, repeatedly emphasized and never fully
-- wired: title-derived terms feed the scorer.** The keep path honoured
-- it (`kept_confirmed_mapped` in every receipt); a model mention
-- resolving to an ALREADY-known concept did not — no keep was needed, so
-- no mapping was written, and 54 genuine One Piece title mentions scored
-- zero while the page row lived on borrowed franchise wires. The
-- resolver (same change) now writes an accepted `lexical` mapping for
-- every grounded, deterministically resolved model mention, with the
-- mention's own weight and the `written_title_tag` licensing on YouTube
-- rows — the keep path generalized to the case that needs no keep.
--
-- The resolver's behaviour changed, and a model version that lags its
-- code records parameters for behaviour that did not happen — so the
-- resolver row moves and the old one retires here, and the recompute
-- enqueues (a model activation is an analysis change, 0396's rule).

begin;

do $$
declare
  old_row record;
begin
  select * into old_row from ontology.model_versions
   where model_role = 'resolver' and status = 'active'
   order by created_at desc limit 1;
  if old_row.id is null then
    raise notice '0421: no active resolver stands; the model rows wait';
  else
    update ontology.model_versions set status = 'retired'
     where id = old_row.id;
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), old_row.model_key,
            '0.15.0', 'resolver', 'active',
            coalesce(old_row.parameters, '{}'::jsonb)
              || jsonb_build_object('grounded_title_mentions',
                   'model mentions grounded in their own evidence text and '
                   || 'resolved to existing concepts map as accepted lexical '
                   || 'evidence at the mention''s weight'));
  end if;
end;
$$;

do $$
declare n integer;
begin
  select semantic_private.enqueue_recompute_on_analysis_change(
    '0421: title-stated terms carry weight — resolver 0.15.0') into n;
  raise notice '0421: % rescore(s) enqueued', n;
end;
$$;

commit;
