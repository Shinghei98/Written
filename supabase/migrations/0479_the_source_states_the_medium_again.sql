-- 0479 — the source states the medium, again, and a title is not a person.
--
-- Wikidata's instance-of slices (film, anime_film, tv_series, anime_tv, song, single, album, video_game),
-- fetched by class on 2026-09-08 and intersected with the vocabulary on the
-- laptop (0198's egress rule). Three rules, each a refusal — a work still
-- untyped takes the medium; a franchise the v7 corpus named keeps it (the
-- owner: Persona 5 is a franchise though its class is video game); a
-- creator is
-- never retyped by name (a person's name is a title's name too often);
-- ambiguity stamps nothing. Counts: {'no_catalogue_answer': 2032, 'creator_name_is_a_title': 44, 'work->movie': 16, 'work->game': 14, 'work->anime': 11, 'work->tv_series': 11, 'labels_disagree': 7, 'work->album': 5, 'work->song': 4}.
--
-- The concept keys keep their historical prefix: a key is identity, not
-- vocabulary. A retyped creator's assertions stand; the readers judge them
-- by the new kind on the next recompute, which this enqueues.
begin;

do $$
declare
  current_version text;
  next_version    text;
  old_version_id  uuid;
  new_version_id  uuid;
  stamped         integer := 0;
begin
  select version, id into current_version, old_version_id
    from ontology.versions where status = 'published';
  if old_version_id is null then
    raise notice '0479: no published version; nothing to stamp';
    return;
  end if;

  create temporary table _media (concept_key text primary key, new_kind text, work_type text) on commit drop;
  insert into _media (concept_key, new_kind, work_type) values
    ('work:a3', 'work', 'game'),
    ('work:a_i_artificial_intelligence', 'work', 'movie'),
    ('work:angry_birds', 'work', 'game'),
    ('work:animal_crossing', 'work', 'game'),
    ('work:bocchi_the_rock', 'work', 'anime'),
    ('work:boys_over_flowers', 'work', 'tv_series'),
    ('work:brat', 'work', 'album'),
    ('work:crazy_about_you', 'work', 'song'),
    ('work:crazy_stone', 'work', 'movie'),
    ('work:dancing_with_the_stars', 'work', 'game'),
    ('work:dhoom_2', 'work', 'movie'),
    ('work:dororo', 'work', 'anime'),
    ('work:extraordinary_you', 'work', 'tv_series'),
    ('work:fight_for_my_way', 'work', 'tv_series'),
    ('work:final_fantasy_ii', 'work', 'game'),
    ('work:final_fantasy_vii_advent_children', 'work', 'anime'),
    ('work:high_school_musical', 'work', 'album'),
    ('work:honkai_impact_3rd', 'work', 'game'),
    ('work:honkai_star_rail', 'work', 'game'),
    ('work:idol_producer', 'work', 'tv_series'),
    ('work:jojo_s_bizarre_adventure', 'work', 'anime'),
    ('work:legally_blonde', 'work', 'movie'),
    ('work:little_shop_of_horrors', 'work', 'movie'),
    ('work:little_women', 'work', 'anime'),
    ('work:love_doctor', 'work', 'tv_series'),
    ('work:love_live_nijigasaki_high_school_idol_club', 'work', 'anime'),
    ('work:love_live_school_idol_festival', 'work', 'game'),
    ('work:love_yourself', 'work', 'song'),
    ('work:midnights', 'work', 'album'),
    ('work:my_dress_up_darling', 'work', 'anime'),
    ('work:naruto', 'work', 'anime'),
    ('work:nirvana_in_fire', 'work', 'tv_series'),
    ('work:office', 'work', 'movie'),
    ('work:office_space', 'work', 'movie'),
    ('work:one_spring_night', 'work', 'tv_series'),
    ('work:paganini', 'work', 'movie'),
    ('work:peer_gynt', 'work', 'movie'),
    ('work:persona_5', 'work', 'game'),
    ('work:pok_mon', 'work', 'anime'),
    ('work:run_on', 'work', 'tv_series'),
    ('work:s_t_a_l_k_e_r_shadow_of_chernobyl', 'work', 'game'),
    ('work:say_my_name', 'work', 'song'),
    ('work:sister_act', 'work', 'movie'),
    ('work:st_louis_blues', 'work', 'movie'),
    ('work:starry_sky', 'work', 'game'),
    ('work:super_mario_bros_2', 'work', 'game'),
    ('work:symphony_no_1', 'work', 'album'),
    ('work:teri_baaton_mein_aisa_uljha_jiya', 'work', 'movie'),
    ('work:the_big_bang_theory', 'work', 'tv_series'),
    ('work:the_hobbit', 'work', 'game'),
    ('work:the_hunger_games', 'work', 'movie'),
    ('work:the_idolmaster', 'work', 'anime'),
    ('work:the_little_prince', 'work', 'movie'),
    ('work:the_nutcracker', 'work', 'movie'),
    ('work:the_rap_of_china', 'work', 'tv_series'),
    ('work:till_we_meet_again', 'work', 'movie'),
    ('work:tokyo_ghoul', 'work', 'anime'),
    ('work:uta_no_prince_sama', 'work', 'game'),
    ('work:wannabe', 'work', 'song'),
    ('work:young_sheldon', 'work', 'tv_series'),
    ('work:zootopia', 'work', 'album');

  if not exists (
    select 1 from _media m join ontology.concepts c on c.concept_key = m.concept_key
    join ontology.concept_revisions r on r.concept_id = c.id and r.ontology_version_id = old_version_id and r.status = 'active'
    where r.concept_kind <> m.new_kind or r.metadata ->> 'work_type' is distinct from m.work_type)
  then
    raise notice '0479: every medium already stands; no version published';
    return;
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (extensions.gen_random_uuid(), next_version, old_version_id, 'draft',
          'The source states the medium, again, and a title is not a person.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(old_version_id, new_version_id);

  update ontology.concept_revisions r
     set concept_kind = m.new_kind,
         metadata = coalesce(r.metadata, '{}'::jsonb)
                    || jsonb_build_object('work_type', m.work_type,
                                          'work_type_source', 'wikidata_p31',
                                          'medium_bridge', '0479')
                    || case when r.concept_kind <> m.new_kind
                            then jsonb_build_object('kind_before', r.concept_kind, 'resorted_by', '0479')
                            else '{}'::jsonb end
    from _media m
    join ontology.concepts c on c.concept_key = m.concept_key
   where r.concept_id = c.id and r.ontology_version_id = new_version_id and r.status = 'active';
  get diagnostics stamped = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || stamped || ' medium(s) stamped from Wikidata; titles are not persons');
  raise notice '0479: % published — % stamped', next_version, stamped;
end $$;

commit;

