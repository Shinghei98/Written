-- 0271 — the Memory a keep produces speaks the context vocabulary.
--
-- `confirm_kept_memory` writes a `feedback_events` row whose context carries
-- `origin` and `mint_request_id`, and `guard_feedback_event_fidelity` admits
-- exactly two keys: `surface`, and `linked_observation_count` on an
-- `explicit_add`. So every mint died on its last statement — after the
-- concept was minted and the assertion written — with `feedback context
-- contains unsupported fields`, and the request stayed pending.
--
-- The guard is right and the writer was wrong, which is the same shape as
-- `0269`'s invented `reason` words: a closed vocabulary exists, and the new
-- code said something outside it. Both keys were redundant anyway —
-- `client_event_id` is already the mint request's id, so the provenance the
-- context was trying to add is in the row twice over.
--
-- Only the context expression moves; every other line of the function is as
-- `0260` wrote it, and it is patched by regexp for that reason rather than
-- restated in full.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.confirm_kept_memory(uuid, uuid, uuid)'::regprocedure);

  patched := replace(body,
    $q$jsonb_build_object('surface', 'memories',
                       'origin', 'user_kept_qwen_discovery',
                       'mint_request_id', p_mint_request_id)$q$,
    $q$jsonb_build_object('surface', 'memories')$q$);

  if patched = body then
    raise exception '0271: the context expression is not the one 0260 wrote';
  end if;
  execute patched;
end;
$$;

do $$
declare
  body text;
begin
  body := regexp_replace(
            pg_get_functiondef(
              'semantic_private.confirm_kept_memory(uuid, uuid, uuid)'::regprocedure),
            '--[^\n]*', '', 'g');
  if position('user_kept_qwen_discovery' in body) > 0
     or position('''mint_request_id''' in body) > 0 then
    raise exception '0271: the Memory event still writes keys the guard refuses';
  end if;

  -- **And the guard still refuses them**, which is the half that matters:
  -- the repair is the writer speaking the vocabulary, never the vocabulary
  -- widening to admit whatever was written.
  if position('linked_observation_count' in
              pg_get_functiondef(
                'semantic_private.guard_feedback_event_fidelity()'::regprocedure)) = 0 then
    raise exception '0271: the context guard has been loosened';
  end if;
end;
$$;
