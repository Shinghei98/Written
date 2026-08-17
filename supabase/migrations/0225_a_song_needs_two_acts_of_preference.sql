-- 0225 — a song needs two acts of preference.
--
-- ## The question
--
-- `0221` took recordings out of the versioned ontology because **owning a track
-- is not a trait**: 560 recordings averaged 1.31 observations and topped out at
-- `strength` 0.148. That argument is about *presence in a library* and it does
-- not settle a narrower one — a song somebody **rated**, or that is their **top
-- track**, or that they **play repeatedly**, is evidence of a different kind.
-- Presence says the file is there. Preference says something about the person.
--
-- So this is the one route by which a song could legitimately become a claim,
-- and it is deliberately **not** a reversal of `0221`: nothing is minted, the
-- ontology is untouched, and identity still lives in `external_entities`.
--
-- ## Measured first, and the answer is zero
--
-- Over both live libraries, 1,345 (account, ISRC) pairs:
--
--   * **679** carry at least one act of preference — `rating` (0.880),
--     `top_track` (0.780), `recently_played` (0.780), `heavy_rotation`;
--   * **0** carry two *distinct* such acts;
--   * **0** clear the 0.25 `work` relief on preference evidence alone, the
--     strongest reaching weight 0.70 and therefore `strength` **0.104**;
--   * **0** clear it even counting *every* observation, presence included —
--     and the strongest song in the database reaches **0.227**.
--
-- **That last number is the one to be careful about.** The single most-attested
-- song across both accounts falls 0.023 short of the bar, which is exactly the
-- shape of evidence that invites moving a threshold to admit it. It is not moved
-- here and the near-miss is recorded so that a later reader knows it was seen
-- and refused rather than never noticed. A bar that admits the best row in the
-- current data is a bar fitted to the current data.
--
-- ## Why two *distinct* acts rather than more of one
--
-- The independence unit for a genre is the artist and for a work the performer;
-- for a song it is **the kind of act**. Playing something forty times is one
-- relationship with it observed repeatedly — the same reason forty tracks by one
-- ensemble are one opinion about baroque. Rating it *and* playing it are two
-- different statements. `recently_played` is capped by the API window anyway, so
-- counting plays would measure how recently somebody opened the app.
--
-- ## Registered, not built
--
-- Same machinery as `work_independence_v1`, deliberately: the rule is frozen
-- before the population exists, qualifiers are recorded as `eligible_shadow`
-- rather than minted, evaluation is gated, and publication needs a separate
-- attestation that can be withdrawn. The shadow set is **empty today**, which is
-- a legitimate result and not a failure — an empty pre-registration still fixes
-- the rule before the data can influence it.

begin;

insert into semantic_private.vocabulary_experiments
  (experiment_key, hypothesis, rule, rule_digest, population_gate, measurements, notes)
values (
  'song_preference_v1',
  'A song becomes a claim about somebody only where the evidence is preference '
  || 'rather than presence. Measured over both live libraries: 679 of 1,345 '
  || '(account, ISRC) pairs carry one act of preference, none carry two, none '
  || 'clear the 0.25 work relief on preference evidence alone (strongest 0.104), '
  || 'and none clear it counting presence too — the strongest song in the '
  || 'database reaching 0.227. The bar is not moved to admit it.',
  jsonb_build_object(
    'unit', 'act_of_preference',
    'preference_actions', jsonb_build_array('rating', 'top_track', 'recently_played', 'heavy_rotation'),
    'minimum_distinct_preference_actions', 2,
    'identity', 'isrc',
    'weight_condition', 'accumulated weight from preference actions alone clears the work relief',
    'observation_filter', 'lifecycle_state = active and action_weight > 0',
    'scope', 'within one account',
    'excluded_as_presence', jsonb_build_array('library_song', 'library_album', 'recently_added',
                                              'saved_track', 'saved_album', 'playlist_item'),
    'derivation',
      'Provenance, not the rule. The preference set is the acts whose weight '
      || 'exceeds library_song (0.480) because they record something the person '
      || 'did rather than something they have: rating 0.880, top_track 0.780, '
      || 'recently_played 0.780. saved_track (0.600) is deliberately excluded — '
      || 'saving is acquisition, which is the presence 0221 already ruled out at '
      || 'a higher number. Two distinct acts rather than repetition of one, '
      || 'because repetition of one act is a single relationship observed twice, '
      || 'and recently_played is bounded by the API window rather than by the '
      || 'person.'
  ),
  encode(extensions.digest(
    jsonb_build_object(
      'unit', 'act_of_preference', 'minimum_distinct_preference_actions', 2,
      'identity', 'isrc', 'scope', 'within one account')::text, 'sha256'), 'hex'),
  5,
  jsonb_build_object(
    'm1_qualifying_songs_per_user', 'count of eligible_shadow per account',
    'm2_recurrence_across_users', 'distinct accounts per qualifying isrc',
    'm3_precision_after_review', 'kept / shown; null until review data exists',
    'm4_evidence_independence', 'distinct preference actions behind each qualifier',
    'm5_growth_per_useful_assertion', 'songs that would be minted / those clearing the bar'
  ),
  'Frozen 2026-08-17. Shadow set is empty on current data and that is a result, '
  || 'not a failure. Near-miss recorded deliberately: the strongest song reaches '
  || '0.227 against a 0.25 bar and the bar is not moved. A superseding rule takes '
  || 'a new key.'
)
on conflict (experiment_key) do nothing;

-- ---------------------------------------------------------------------------
-- What the frozen rule selects today.
-- ---------------------------------------------------------------------------
--
-- Written as a real query rather than skipped on the knowledge that it returns
-- nothing: a selection that has only ever been reasoned about is not one to
-- believe, and this must keep working when a library that *does* qualify
-- arrives.

insert into semantic_private.vocabulary_experiment_candidates
  (experiment_key, user_id, normalized_text, state, evidence)
select 'song_preference_v1', q.user_id, q.isrc, 'eligible_shadow',
       jsonb_build_object('preference_actions', q.acts,
                          'preference_weight', round(q.w_pref::numeric, 3),
                          'observations', q.observations)
  from (
    select o.user_id,
           upper(o.normalized_payload ->> 'isrc') as isrc,
           count(distinct o.action_type)
             filter (where o.action_type in ('rating','top_track','recently_played','heavy_rotation'))
             as acts,
           sum(1.0 * s.default_reliability
               * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0))
             filter (where o.action_type in ('rating','top_track','recently_played','heavy_rotation'))
             as w_pref,
           count(*) as observations
      from semantic_private.observations o
      join semantic_private.sources s on s.source_code = o.source_code
     where o.lifecycle_state = 'active'
       and o.action_weight > 0
       and coalesce(o.normalized_payload ->> 'isrc', '') <> ''
     group by o.user_id, upper(o.normalized_payload ->> 'isrc')
  ) q
 where q.acts >= 2
   and coalesce(q.w_pref, 0.0) / (coalesce(q.w_pref, 0.0) + 6) >= 0.25
on conflict (experiment_key, user_id, normalized_text) do nothing;

-- ---------------------------------------------------------------------------
-- Prove it.
-- ---------------------------------------------------------------------------

do $$
declare
  shadow      integer;
  one_act     integer;
  best        double precision;
  status      jsonb;
begin
  select count(*) into shadow
    from semantic_private.vocabulary_experiment_candidates
   where experiment_key = 'song_preference_v1';

  -- **The rule ran and selected nothing**, which is different from the rule not
  -- having run. The two counts below are what tell them apart: there is
  -- abundant single-act evidence, and none of it reaches two acts.
  select count(*) into one_act
    from (
      select o.user_id, upper(o.normalized_payload ->> 'isrc') as isrc
        from semantic_private.observations o
       where o.lifecycle_state = 'active' and o.action_weight > 0
         and coalesce(o.normalized_payload ->> 'isrc', '') <> ''
         and o.action_type in ('rating','top_track','recently_played','heavy_rotation')
       group by 1, 2) q;

  select max(w / (w + 6)) into best
    from (
      select sum(1.0 * s.default_reliability
                 * coalesce((s.action_weights ->> o.action_type)::double precision, 0.0)) as w
        from semantic_private.observations o
        join semantic_private.sources s on s.source_code = o.source_code
       where o.lifecycle_state = 'active' and o.action_weight > 0
         and coalesce(o.normalized_payload ->> 'isrc', '') <> ''
       group by o.user_id, upper(o.normalized_payload ->> 'isrc')) per_song;

  -- **Conditional on there being songs at all**, so this replays from empty.
  if one_act > 0 and shadow > 0 then
    raise exception
      '0225: % song(s) qualified where the measurement said none could', shadow;
  end if;

  -- **The bar was not moved**, asserted rather than promised. If the strongest
  -- song ever clears 0.25 it will be because its evidence grew, and this
  -- assertion is what makes that visible instead of a quiet edit to a constant.
  if best is not null and best >= 0.25 and shadow = 0 then
    raise exception
      '0225: a song reaches strength %, at or above the bar, and none qualified — '
      'the preference rule and the bar disagree', round(best::numeric, 3);
  end if;

  status := semantic_private.vocabulary_experiment_status('song_preference_v1');
  if (status ->> 'publication_ready')::boolean then
    raise exception '0225: a freshly registered experiment reports publication_ready';
  end if;
  if (status ->> 'population_gate_open')::boolean
     and not (status ->> 'measurement_complete')::boolean
     and (status -> 'measurement_blockers') = '[]'::jsonb then
    raise exception '0225: measurement is incomplete with no blocker named';
  end if;

  raise notice
    '0225: song_preference_v1 frozen; % shadow, % single-act song(s), best strength %, ready=%',
    shadow, one_act, coalesce(round(best::numeric, 3), 0), status ->> 'publication_ready';
end;
$$;

commit;
