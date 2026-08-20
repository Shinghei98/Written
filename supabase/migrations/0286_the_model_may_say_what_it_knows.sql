-- 0286 — the model may say what it knows, and the schema learns a fourth
-- extraction method for it.
--
-- `0284`/`0285` built the dictionary and it can only be fed by terms the model
-- **read**. The owner's directive is that dictionary building does not need
-- that guard: hallucination is acceptable because users validate, and the
-- weight decides what survives. So a mention may now be *inferred* — "One
-- Piece" from a title that says 路飛 — and it needs somewhere to live.
--
-- **An inferred mention is an `observation_mention` like any other.** That is
-- the whole reason for a new `extraction_method` rather than a parallel table:
-- resolution, provisioning, candidacy, review, keep and mint all key on that
-- column, so a fourth value inherits the entire pipeline. The cost is that
-- **every place keying on `model_proposed` fails silently if missed** — a term
-- that reaches no join simply never appears, which is the failure `0255` was
-- itself written to fix. They are enumerated here and each is patched from the
-- deployed text rather than restated.
--
-- What does *not* move: the fifteen-role vocabulary (the check's `else` branch
-- already binds any non-`projection_field` method to it), and every guard on
-- the extracted path. An inferred mention is a different kind of claim, not a
-- weaker one — it still names its invocation item, still belongs to one
-- account, still carries its lineage.

-- ---------------------------------------------------------------------------
-- 1. The method vocabulary.
-- ---------------------------------------------------------------------------

alter table semantic_private.observation_mentions
  drop constraint observation_mentions_extraction_method_check;

alter table semantic_private.observation_mentions
  add constraint observation_mentions_extraction_method_check
  check (extraction_method in (
    'projection_field', 'exact_rule', 'model_proposed', 'model_inferred'));

comment on constraint observation_mentions_extraction_method_check
  on semantic_private.observation_mentions is
  'projection_field is the legacy resolver, exact_rule the deterministic lane, '
  'model_proposed a term read out of the source text, and model_inferred one '
  'the model asserted from its own knowledge (0286). The last two are both '
  'model output and are treated alike everywhere except that an inferred '
  'mention has no span.';

-- ---------------------------------------------------------------------------
-- 2. Lineage. An inferred mention must still say which call made it.
-- ---------------------------------------------------------------------------
--
-- `0237`'s guard refuses `model_invocation_item_id` on anything that is not
-- `model_proposed`, so without this an inferred mention would be forbidden
-- from naming the invocation that produced it — provenance lost for exactly
-- the mentions that need it most, since they cannot be checked against a
-- source string.

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.guard_model_mention_lineage()'::regprocedure);

  patched := replace(body,
    E'if new.extraction_method <> ''model_proposed'' then',
    E'if new.extraction_method not in (''model_proposed'', ''model_inferred'') then');
  if patched = body then
    raise exception '0286: the lineage guard is not the one 0237 wrote';
  end if;
  body := patched;

  patched := replace(body,
    E'raise exception ''a model_proposed mention must name its invocation item'';',
    E'raise exception ''a % mention must name its invocation item'', new.extraction_method;');
  if patched = body then
    raise exception '0286: the lineage guard no longer demands an invocation item';
  end if;

  execute patched;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Provisioning. The join that would silently drop the new method.
-- ---------------------------------------------------------------------------
--
-- `0255` exists because a role→family catalogue join dropped every model
-- mention and nothing reported it. Its filters name `model_proposed` in six
-- places; an inferred mention missing from any of them would provision no
-- entity, produce no candidate, and reach no review card — invisible in the
-- same way, for the same reason.

do $$
declare
  body text;
  patched text;
  hits integer;
begin
  body := pg_get_functiondef(
    'semantic_private.provision_exact_misses(uuid, uuid)'::regprocedure);

  hits := (length(body) - length(replace(body, '''model_proposed''', '')))
          / length('''model_proposed''');
  if hits < 4 then
    raise exception '0286: expected the model-method filters 0255 wrote, found %', hits;
  end if;

  patched := replace(body,
    E'm.extraction_method <> ''model_proposed''',
    E'm.extraction_method not in (''model_proposed'', ''model_inferred'')');
  patched := replace(patched,
    E'm.extraction_method = ''model_proposed''',
    E'm.extraction_method in (''model_proposed'', ''model_inferred'')');
  patched := replace(patched,
    E'm.extraction_method in (''projection_field'', ''model_proposed'')',
    E'm.extraction_method in (''projection_field'', ''model_proposed'', ''model_inferred'')');

  if patched = body then
    raise exception '0286: provisioning was not widened';
  end if;
  execute patched;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The armer's work test, widened by name exactly as 0244 widened it.
-- ---------------------------------------------------------------------------

do $$
declare
  body text;
  patched text;
begin
  body := pg_get_functiondef(
    'semantic_private.arm_candidate_overlay(uuid, text)'::regprocedure);

  patched := replace(body,
    E'extraction_method in (''projection_field'', ''model_proposed'')',
    E'extraction_method in (''projection_field'', ''model_proposed'', ''model_inferred'')');
  if patched = body then
    raise notice '0286: the armer names no model-method literal; nothing to widen';
  else
    execute patched;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Both ways.
-- ---------------------------------------------------------------------------

do $$
declare
  def text;
begin
  -- The method is admitted, and the vocabulary is still closed.
  def := pg_get_constraintdef((
    select c.oid from pg_constraint c
      join pg_class t on t.oid = c.conrelid
      join pg_namespace n on n.oid = t.relnamespace
     where n.nspname = 'semantic_private' and t.relname = 'observation_mentions'
       and c.conname = 'observation_mentions_extraction_method_check'));
  if position('model_inferred' in def) = 0 then
    raise exception '0286: the fourth method is not admitted';
  end if;
  if position('vibes' in def) > 0 then
    raise exception '0286: the method vocabulary is no longer closed';
  end if;

  -- Lineage is demanded of both model methods and refused to the others.
  def := regexp_replace(
           pg_get_functiondef(
             'semantic_private.guard_model_mention_lineage()'::regprocedure),
           '--[^\n]*', '', 'g');
  if position('''model_proposed'', ''model_inferred''' in def) = 0 then
    raise exception '0286: an inferred mention cannot name its invocation item';
  end if;

  -- Provisioning sees the new method everywhere it saw the old one.
  def := regexp_replace(
           pg_get_functiondef(
             'semantic_private.provision_exact_misses(uuid, uuid)'::regprocedure),
           '--[^\n]*', '', 'g');
  if (length(def) - length(replace(def, 'model_inferred', '')))
     / length('model_inferred')
     <> (length(def) - length(replace(def, 'model_proposed', '')))
        / length('model_proposed') then
    raise exception
      '0286: provisioning names the two model methods a different number of times';
  end if;
end;
$$;
