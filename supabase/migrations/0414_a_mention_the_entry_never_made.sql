-- 0414 — a mention the entry never made.
--
-- **Found by the owner's trace, 2026-08-27: Timi's One Piece row rests on
-- 21 `model_proposed` mentions of the literal text "One Piece" attached
-- to Mandopop ballads** (会不会是月光, 凄美地, 踮起腳尖愛) whose entries
-- contain nothing of the kind. Not a relation error and not propagation:
-- the model injected a term into entries that never said it, and the
-- exact-label resolver then faithfully resolved the injection. §2.22's
-- grounding rule therefore descends one level: **a model-lane mention
-- whose text appears nowhere in its own entry is a fabrication.**
--
-- The audit is local and deterministic — mention text against the
-- observation's own stated fields — and scoped honestly: an observation
-- whose projection carries no text (YouTube's sanitized rows) cannot be
-- judged here and is left to the corpus-side validator, which sees the
-- raw titles. The invalidation is a superseding resolution on the same
-- `exact_label` route: `ambiguous` with the reason recorded — a hold,
-- so nothing re-provisions the fabrication — which
-- `current_mention_resolutions` prefers by evaluated version, and the
-- next aggregation drops the support. Ends with the recompute enqueue.

begin;

create or replace function semantic_private.audit_ungrounded_model_mentions()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  published_version uuid;
  invalidated integer := 0;
begin
  select id into published_version from ontology.versions
   where status = 'published';

  with entry_text as (
    select o.id as observation_id, o.user_id,
           lower(btrim(concat_ws(' ',
             o.normalized_payload ->> 'title',
             o.normalized_payload ->> 'album',
             o.normalized_payload ->> 'artist',
             o.normalized_payload ->> 'primary_performer',
             o.normalized_payload ->> 'creator',
             o.normalized_payload ->> 'composer'))) as text
      from semantic_private.observations o
     where o.lifecycle_state = 'active'
  ),
  fabricated as (
    select mn.id as mention_id, mn.user_id
      from semantic_private.observation_mentions mn
      join entry_text et on et.observation_id = mn.observation_id
       and et.user_id = mn.user_id
     where mn.extraction_method in ('model_proposed', 'model_inferred')
       and length(et.text) > 0
       and position(lower(btrim(mn.mention_text)) in et.text) = 0
       and position(lower(btrim(mn.normalized_text)) in et.text) = 0
       -- Only mentions whose current exact-label answer filed an identity
       -- need superseding; an already-held mention is already harmless.
       and exists (
         select 1 from semantic_private.current_mention_resolutions cr
          where cr.mention_id = mn.id and cr.route_id = 'exact_label'
            and cr.resolution not in ('ambiguous', 'unresolved'))
  )
  insert into semantic_private.mention_resolutions
    (user_id, mention_id, resolution, ontology_version_id, concept_id,
     provisional_entity_id, route_id, resolver_version, confidence,
     abstention_reason, evaluated_ontology_version_id)
  select f.user_id, f.mention_id, 'ambiguous', null, null, null,
         'exact_label', 'grounding-audit-v1', 0.0,
         'ungrounded_model_mention', published_version
    from fabricated f;
  get diagnostics invalidated = row_count;

  return jsonb_build_object('invalidated', invalidated);
end;
$function$;

revoke execute on function semantic_private.audit_ungrounded_model_mentions()
  from public, anon, authenticated;
grant execute on function semantic_private.audit_ungrounded_model_mentions()
  to semantic_worker;

do $$
declare receipt jsonb;
begin
  select semantic_private.audit_ungrounded_model_mentions() into receipt;
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0414: ungrounded model mentions held — ' || (receipt ->> 'invalidated')
    || ' resolution(s) superseded');
  raise notice '0414: %', receipt;
end;
$$;

commit;
