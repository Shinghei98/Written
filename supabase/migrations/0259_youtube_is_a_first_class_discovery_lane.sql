-- 0259 — YouTube is a first-class term-discovery lane.
--
-- The owner's interpretation of record (2026-08-20): YouTube's additional
-- terms permit use of their material for integrative app function, and the
-- three-lane integration contract (`Written_Ontology_Grammar_and_Three_Lane_
-- Integration_Contract.docx`) is the binding restatement — three source
-- lanes, one ontology; a noun's absence from the vocabulary routes to a
-- reviewable provisional and is never a reason to bar the source; a source
-- profile must not express YouTube as discover_known_terms_only.
--
-- What this migration moves: the armer's source wall and the evidence policy
-- map. What it deliberately does not move: the 30-day expiry on filed
-- evidence (already applied to every source), the display rule that one
-- user's YouTube-derived material is never shown to another, and every hard
-- invariant the contract states — a like is not a watch, a subscription is
-- not interest in every member, and `subscription`/`liked_video` rows enter
-- with their own action weights rather than being rewritten as anything
-- else. The request schema has carried a `youtube` source profile since v1;
-- `MODEL_INPUT_PROFILES` in overlay.py gains the matching row in the same
-- deploy, and the contract subtest that compares the two lists is what keeps
-- them agreeing.

create or replace function semantic_private.model_input_source_codes()
returns text[]
language sql
immutable
set search_path = ''
as $$
  -- Apple Music, its device library, podcasts — and YouTube, under the
  -- owner's interpretation of record (2026-08-20): the additional terms
  -- permit integrative app function, and the three-lane contract makes
  -- YouTube a first-class discovery lane. Spotify stays absent: IV.2.1.a
  -- forbids the model call and IV.2.5 closes the consent route. Calendar is
  -- licensed and still absent HERE — its titles reach the scorer through the
  -- classifier Lambda — pending the Events-lane work the same contract
  -- defines. HealthKit has no text.
  select array['apple_music', 'music_library', 'apple_podcasts', 'podcast',
               'youtube'];
$$;

-- The evidence policy map learns YouTube's weighted actions, by the same
-- derivation 0256 used: the source's own action_weights supply the pairs (an
-- unweighted action cannot hold a row), crossed with the authored role and
-- family allowlists. Absence still denies.
insert into semantic_private.mention_evidence_policy
  (source_code, action_type, mention_family, mention_role)
select s.source_code, a.key, fam.family, role.role
  from semantic_private.sources s,
       jsonb_each_text(s.action_weights) a,
       (values ('person'), ('group'), ('organization'), ('franchise'),
               ('work'), ('anime'), ('book'), ('game'), ('music_work'),
               ('album'), ('sport'), ('activity'), ('idea'), ('culture'),
               ('event'), ('tour')) as fam(family),
       (values ('primary_subject'), ('featured_person'), ('performing_group'),
               ('work_or_franchise'), ('creator_identity'),
               ('channel_core_topic'), ('durable_activity_or_idea')) as role(role)
 where s.source_code = 'youtube'
   and a.value::float > 0
on conflict do nothing;

do $$
declare
  n integer;
begin
  -- The wall now admits exactly five, and Spotify is still refused.
  if not ('youtube' = any (semantic_private.model_input_source_codes())) then
    raise exception '0259: youtube is not armable';
  end if;
  if 'spotify' = any (semantic_private.model_input_source_codes()) then
    raise exception '0259: spotify must never be armable';
  end if;
  if array_length(semantic_private.model_input_source_codes(), 1) <> 5 then
    raise exception '0259: expected exactly five armable sources';
  end if;

  -- The policy learned only weighted YouTube actions, and the denied roles
  -- stayed denied for it too.
  select count(*) into n from semantic_private.mention_evidence_policy p
   where p.source_code = 'youtube'
     and not exists (
       select 1 from semantic_private.sources s,
                     jsonb_each_text(s.action_weights) a
        where s.source_code = 'youtube'
          and a.key = p.action_type and a.value::float > 0);
  if n > 0 then
    raise exception '0259: % policy rows admit an unweighted youtube action', n;
  end if;
  select count(*) into n from semantic_private.mention_evidence_policy
   where source_code = 'youtube'
     and (mention_role in ('format_token', 'incidental_context', 'tag_roster',
                           'uploader', 'publisher', 'generic_action',
                           'analogy', 'unresolved_generic')
          or mention_family = 'place');
  if n > 0 then
    raise exception '0259: youtube policy admits a denied role or family';
  end if;
end;
$$;
