-- 0207 — two vocabularies in one column.
--
-- ## What is wrong
--
-- `semantic_private.observation_mentions.mention_role` holds 73,126 rows written
-- by the legacy resolver, using roles like `album`, `composer`, `genre` and
-- `source_work` — which are really *the payload field a string came from*.
--
-- The compiled contract declares a different fifteen for the same column:
-- `primary_subject`, `featured_person`, `performing_group`, `incidental_context`
-- and so on — *what part a mention plays in the item*. When `extract_mentions`
-- ships it writes those.
--
-- **Neither column has a check constraint.** Any string is accepted, the two
-- vocabularies are disjoint but nothing says so, and a reader joining on
-- `mention_role` would silently mix a field name with a semantic role. That is
-- this repository's named recurring defect wearing a new coat, and the failure
-- mode is the one it always is: silence.
--
-- ## Why this does not enumerate the legacy roles
--
-- The obvious constraint — list every permitted role — is the wrong instrument
-- here and would have been a live outage. `resolve.py` can emit **sixteen**
-- roles, not the six present in the data: the YouTube ones (`provider_topic`,
-- `uploader_tag`, `title_work`, `written_title_tag`, `channel_identity`,
-- `title_hashtag`, `uploader_tag_work`) have never been written because no
-- YouTube observation has been mined, and `era`, `scene` and `sphere` are axes
-- the scorer reads and never asserts. A constraint built from *what is in the
-- table* would have refused the first YouTube distillation after the source
-- came back, at write time, inside the resolver.
--
-- So the rule is stated the way it can be stated completely:
--
--   * **`extraction_method` is closed** — three values, and it is the
--     discriminator. The legacy path hardcodes `projection_field` in its insert.
--   * **The contract's fifteen roles belong to the contract's lanes, and to
--     nothing else.** A `projection_field` row may use any role it likes except
--     one of those fifteen; an `exact_rule` or `model_proposed` row must use one
--     of them and nothing else.
--
-- That needs no list of legacy roles at all, cannot break a lane that has not
-- run yet, and still makes the two vocabularies unmixable. The sixteen legacy
-- roles and the fifteen contract roles are disjoint today, and this is what
-- keeps them so.
--
-- ## The copy, and what makes it safe
--
-- The fifteen are written out here, which is a second copy of a fact the
-- contract owns — the same tension as `provisional_entities.family` in `0203`,
-- and permitted for the same reason: a check constraint is the only mechanism
-- the database has. It is made safe the same way, by
-- `tools/compile_semantic_contract.py --check-database` reading it back and
-- refusing to agree the contract compiles if the two have drifted. The contract
-- is the authority; this is its enforcement.

begin;

-- **Closed, and `projection_field` is first because it is all there is today.**
-- `exact_rule` is the deterministic lane the contract calls `exact_only`;
-- `model_proposed` is the Qwen lane, which stays unreachable while
-- `semantic_qwen_overlay` is false — the value exists so the constraint does not
-- have to change on the day the overlay is enabled, which is a day nobody should
-- also be debugging a check constraint.
alter table semantic_private.observation_mentions
  add constraint observation_mentions_extraction_method_check
  check (extraction_method in ('projection_field', 'exact_rule', 'model_proposed'));

alter table semantic_private.observation_mentions
  add constraint observation_mentions_role_vocabulary_check
  check (
    case extraction_method
      when 'projection_field' then
        -- The legacy lane may name any field it reads and may not borrow a
        -- semantic role it does not mean.
        mention_role not in (
          'primary_subject', 'featured_person', 'performing_group',
          'work_or_franchise', 'creator_identity', 'channel_core_topic',
          'durable_activity_or_idea', 'publisher', 'uploader',
          'incidental_context', 'tag_roster', 'format_token',
          'generic_action', 'analogy', 'unresolved_generic')
      else
        -- Both contract lanes speak the contract's vocabulary and only that.
        mention_role in (
          'primary_subject', 'featured_person', 'performing_group',
          'work_or_franchise', 'creator_identity', 'channel_core_topic',
          'durable_activity_or_idea', 'publisher', 'uploader',
          'incidental_context', 'tag_roster', 'format_token',
          'generic_action', 'analogy', 'unresolved_generic')
    end
  );

comment on column semantic_private.observation_mentions.mention_role is
  'Two disjoint vocabularies discriminated by extraction_method. '
  '`projection_field` rows carry the legacy resolver''s field names (album, '
  'composer, genre, source_work, and the YouTube and axis roles that have not '
  'been written yet). `exact_rule` and `model_proposed` rows carry the fifteen '
  'roles the compiled contract declares. 0207 keeps them apart; the contract is '
  'the authority for the fifteen and --check-database compares them.';

do $$
declare
  legacy integer;
  template uuid;
  refusals integer := 0;
begin
  -- 1. The rows that already exist still satisfy it. A constraint added to a
  --    populated table validates on the way in, so reaching here proves it —
  --    but say the number, because "it applied" and "it applied to something"
  --    are different facts.
  select count(*) into legacy from semantic_private.observation_mentions
   where extraction_method = 'projection_field';
  raise notice '0207: % existing projection_field mention(s) satisfy the rule', legacy;

  -- 2. **The predicate, answering both ways over a real row.** A constraint that
  --    has only ever accepted has not been shown to discriminate.
  --
  --    The probe copies an existing mention and varies only the two columns
  --    under test. Writing the other eighteen by hand failed twice — first on
  --    the guard that refuses private-source observations from the generic
  --    mention lane, then on `observation_mentions_recency_v02_check`, because
  --    the recency fields are a closed vocabulary this migration has no business
  --    knowing. Copying a row that is already accepted means every constraint
  --    except the new one is satisfied by construction, which is the only way to
  --    be sure the refusal below is *this* rule refusing.
  select m.id into template
    from semantic_private.observation_mentions m
    join semantic_private.observations o on o.id = m.observation_id
   where m.extraction_method = 'projection_field'
     and o.lifecycle_state = 'active'
   limit 1;

  if template is null then
    raise notice '0207: no mention to copy; the rule is unexercised on this database';
  else
    begin
      -- a. The legacy lane may not borrow a contract role.
      begin
        insert into semantic_private.observation_mentions
          (observation_id, user_id, mention_text, normalized_text, mention_role,
           locale, type_hint, source_field, extraction_method, confidence,
           safe_for_global_mining, safe_for_external_resolution, evidence_weight,
           recency_weight, recency_quality, recency_policy_version,
           recency_rule_id, recency_status, recency_timestamp_quality,
           recency_as_of)
        select m.observation_id, m.user_id, 'probe', 'probe', 'primary_subject',
               m.locale, m.type_hint, m.source_field, 'projection_field',
               m.confidence, m.safe_for_global_mining,
               m.safe_for_external_resolution, m.evidence_weight,
               m.recency_weight, m.recency_quality, m.recency_policy_version,
               m.recency_rule_id, m.recency_status, m.recency_timestamp_quality,
               m.recency_as_of
          from semantic_private.observation_mentions m where m.id = template;
        raise exception '0207: the legacy lane accepted a contract role';
      exception when check_violation then
        refusals := refusals + 1;
      end;

      -- b. A contract lane may not use a legacy field name.
      begin
        insert into semantic_private.observation_mentions
          (observation_id, user_id, mention_text, normalized_text, mention_role,
           locale, type_hint, source_field, extraction_method, confidence,
           safe_for_global_mining, safe_for_external_resolution, evidence_weight,
           recency_weight, recency_quality, recency_policy_version,
           recency_rule_id, recency_status, recency_timestamp_quality,
           recency_as_of)
        select m.observation_id, m.user_id, 'probe', 'probe', 'composer',
               m.locale, m.type_hint, m.source_field, 'exact_rule',
               m.confidence, m.safe_for_global_mining,
               m.safe_for_external_resolution, m.evidence_weight,
               m.recency_weight, m.recency_quality, m.recency_policy_version,
               m.recency_rule_id, m.recency_status, m.recency_timestamp_quality,
               m.recency_as_of
          from semantic_private.observation_mentions m where m.id = template;
        raise exception '0207: a contract lane accepted a legacy field name';
      exception when check_violation then
        refusals := refusals + 1;
      end;

      -- c. An extraction method nobody declared.
      begin
        insert into semantic_private.observation_mentions
          (observation_id, user_id, mention_text, normalized_text, mention_role,
           locale, type_hint, source_field, extraction_method, confidence,
           safe_for_global_mining, safe_for_external_resolution, evidence_weight,
           recency_weight, recency_quality, recency_policy_version,
           recency_rule_id, recency_status, recency_timestamp_quality,
           recency_as_of)
        select m.observation_id, m.user_id, 'probe', 'probe', 'primary_subject',
               m.locale, m.type_hint, m.source_field, 'vibes',
               m.confidence, m.safe_for_global_mining,
               m.safe_for_external_resolution, m.evidence_weight,
               m.recency_weight, m.recency_quality, m.recency_policy_version,
               m.recency_rule_id, m.recency_status, m.recency_timestamp_quality,
               m.recency_as_of
          from semantic_private.observation_mentions m where m.id = template;
        raise exception '0207: an undeclared extraction method was accepted';
      exception when check_violation then
        refusals := refusals + 1;
      end;

      -- d. And the thing it must *permit*: the new lane writing a contract role.
      insert into semantic_private.observation_mentions
        (observation_id, user_id, mention_text, normalized_text, mention_role,
         locale, type_hint, source_field, extraction_method, confidence,
         safe_for_global_mining, safe_for_external_resolution, evidence_weight,
         recency_weight, recency_quality, recency_policy_version,
         recency_rule_id, recency_status, recency_timestamp_quality,
         recency_as_of)
      select m.observation_id, m.user_id, 'probe', 'probe', 'primary_subject',
             m.locale, m.type_hint, m.source_field, 'exact_rule',
             m.confidence, m.safe_for_global_mining,
             m.safe_for_external_resolution, m.evidence_weight,
             m.recency_weight, m.recency_quality, m.recency_policy_version,
             m.recency_rule_id, m.recency_status, m.recency_timestamp_quality,
             m.recency_as_of
        from semantic_private.observation_mentions m where m.id = template;

      if refusals <> 3 then
        raise exception '0207: expected three refusals, counted %', refusals;
      end if;

      raise exception using errcode = 'YY001', message = 'probe complete';
    exception
      when sqlstate 'YY001' then
        null;
    end;

    raise notice '0207: refused three wrong shapes and accepted the right one';
  end if;
end;
$$;

commit;
