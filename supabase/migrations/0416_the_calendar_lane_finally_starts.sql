-- 0416 — the calendar lane finally starts.
--
-- **The owner's report, 2026-08-27: none of Timi's events contribute to
-- her Memories.** Measured: 894 active calendar observations, zero
-- classifications, zero candidates — `classify_calendar` is one of the
-- job types with no handler since the AWS worker died, so the lane's
-- first stage never ran for anyone. Meanwhile all 772 current calendar
-- texts sit readable under `ris_lab_plaintext_v1` (0309's one legitimate
-- plaintext, the owner-authorized testing bypass).
--
-- This is the deterministic first stage:
--
-- 1. **`calendar_class_patterns`** — authored, versioned pattern rows
--    (a registry like `sources`, not literals in a function): the three
--    eligible classes recognized by structural vocabulary (flights,
--    reservations, ticketed events — latin and CJK forms), and the
--    private classes (birthday, medical, funeral, meetings) recognized
--    so they are *excluded deterministically*, which is
--    privacy-protective, not just tidy.
-- 2. **A registered classifier**: `model_versions` row, role
--    `calendar_classifier`, `written-deterministic-rules` 0.1.0 — the
--    guard demands a registered active classifier, and a rule engine is
--    one, its parameters naming the pattern set. The model lane's Qwen
--    classifier, when it returns, takes the `review` residue; nothing
--    here occupies its role name.
-- 3. **`classify_calendar_events_deterministic()`**: for each active
--    private-calendar observation without a classification, reads its
--    CURRENT evidence text — **plaintext key version only; any other
--    key version is skipped and counted**, so the AWS lane's encrypted
--    rows wait for the worker that can read them, exactly as designed —
--    first matching pattern by priority wins, nothing matched refuses
--    to `review`/`unknown`. First match, never a guess.
--
-- Candidates and surfacing are the lane's next stages, after this
-- stage's output is inspected. Ends with the recompute enqueue.

begin;

create table semantic_private.calendar_class_patterns (
  id uuid primary key default gen_random_uuid(),
  pattern text not null,
  event_class text not null,
  disposition text not null
    check (disposition in ('eligible_private_semantics', 'excluded_private')),
  priority integer not null,
  pattern_set text not null default 'calendar-patterns-v1'
);
revoke all on semantic_private.calendar_class_patterns from public;
grant select on semantic_private.calendar_class_patterns to semantic_worker;

insert into semantic_private.calendar_class_patterns
  (pattern, event_class, disposition, priority) values
  ('(birthday|生日|생일|誕生日)', 'birthday', 'excluded_private', 10),
  ('(doctor|dentist|clinic|hospital|therap|physio|診所|醫院|医院|병원|치과)',
   'medical', 'excluded_private', 10),
  ('(funeral|memorial service|追悼|葬)', 'funeral_memorial', 'excluded_private', 10),
  ('(meeting|sync|stand-?up|1:1|one on one|interview|call with|会議|會議|회의)',
   'work_meeting', 'excluded_private', 20),
  ('(class$|class |lecture|seminar|office hours|exam|midterm|quiz|homework|課|강의)',
   'other_private', 'excluded_private', 20),
  ('(flight|boarding|airline|airport|itinerary|layover|航班|搭乘|高鐵|高铁|新幹線|列車|기차|비행기)',
   'travel_itinerary', 'eligible_private_semantics', 30),
  ('(concert|festival|world tour|ticketmaster|presale|fan ?meet|encore|live 20[0-9][0-9]|公演|演唱會|演唱会|콘서트|ライブ|フェス)',
   'public_ticketed_event', 'eligible_private_semantics', 30),
  ('(reservation|reserved|booking ref|booking confirm|opentable|resy|table for [0-9]|hotel|airbnb|check-?in|預約|预约|예약)',
   'commercial_reservation', 'eligible_private_semantics', 40);

do $$
begin
  if not exists (select 1 from ontology.model_versions
                  where model_role = 'calendar_classifier' and status = 'active') then
    insert into ontology.model_versions
      (id, model_key, version, model_role, status, parameters)
    values (extensions.gen_random_uuid(), 'written-deterministic-rules',
            '0.1.0', 'calendar_classifier', 'active',
            jsonb_build_object('pattern_set', 'calendar-patterns-v1',
              'note', 'first-match deterministic rules; unmatched refuses to review'));
  end if;
end;
$$;

create or replace function semantic_private.classify_calendar_events_deterministic()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  classifier_id uuid;
  published_version uuid;
  classified integer := 0;
  refused_to_review integer := 0;
  unreadable_skipped integer := 0;
begin
  select id into classifier_id from ontology.model_versions
   where model_role = 'calendar_classifier' and status = 'active'
   order by created_at desc limit 1;
  select id into published_version from ontology.versions
   where status = 'published';

  with unclassified as (
    select o.id as observation_id, o.user_id, s.revision
      from semantic_private.observations o
      join semantic_private.user_state_versions s on s.user_id = o.user_id
     where o.lifecycle_state = 'active'
       and semantic_private.is_private_calendar_source(o.source_code)
       and not exists (
         select 1 from semantic_private.calendar_event_classifications c
          where c.observation_id = o.id and c.user_id = o.user_id)
  ),
  readable as (
    select u.observation_id, u.user_id, u.revision,
           lower(convert_from(e.encrypted_text, 'utf8')) as text
      from unclassified u
      join semantic_private.source_text_evidence e
        on e.observation_id = u.observation_id and e.user_id = u.user_id
       and e.refresh_status = 'current' and e.deleted_at is null
     where e.encryption_key_version = 'ris_lab_plaintext_v1'
  ),
  verdicts as (
    select r.observation_id, r.user_id, r.revision,
           p.event_class, p.disposition
      from readable r
      left join lateral (
        select cp.event_class, cp.disposition
          from semantic_private.calendar_class_patterns cp
         where r.text ~* cp.pattern
         order by cp.priority, cp.id limit 1
      ) p on true
  )
  insert into semantic_private.calendar_event_classifications
    (observation_id, user_id, classifier_model_id, event_class, disposition,
     mapping_agreement, evidence_quality, ontology_version_id, input_revision)
  select v.observation_id, v.user_id, classifier_id,
         coalesce(v.event_class, 'unknown'),
         coalesce(v.disposition, 'review'),
         1.0, 1.0, published_version, v.revision
    from verdicts v;
  get diagnostics classified = row_count;

  select count(*) into refused_to_review
    from semantic_private.calendar_event_classifications c
   where c.classifier_model_id = classifier_id and c.disposition = 'review';

  select count(*) into unreadable_skipped
    from semantic_private.observations o
   where o.lifecycle_state = 'active'
     and semantic_private.is_private_calendar_source(o.source_code)
     and not exists (
       select 1 from semantic_private.calendar_event_classifications c
        where c.observation_id = o.id and c.user_id = o.user_id);

  return jsonb_build_object('classified', classified,
                            'refused_to_review', refused_to_review,
                            'unreadable_or_textless_skipped', unreadable_skipped);
end;
$function$;

revoke execute on function
  semantic_private.classify_calendar_events_deterministic()
  from public, anon, authenticated;
grant execute on function
  semantic_private.classify_calendar_events_deterministic()
  to semantic_worker;

do $$
declare receipt jsonb;
begin
  select semantic_private.classify_calendar_events_deterministic() into receipt;
  perform semantic_private.enqueue_recompute_on_analysis_change(
    '0416: the calendar lane starts — ' || (receipt ->> 'classified')
    || ' classification(s), ' || (receipt ->> 'unreadable_or_textless_skipped')
    || ' left for the lane that can read them');
  raise notice '0416: %', receipt;
end;
$$;

commit;
