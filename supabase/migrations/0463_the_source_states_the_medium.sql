-- 0463 — the source states the medium, and the medium speaks first.
--
-- **The identity fact 0461 said this corpus could not derive is now
-- read, not derived.** Wikidata states `instance of` for films,
-- television series, anime, songs, singles, albums and video games —
-- the same kind of read as `topicDetails`: the source's own label.
-- `tools/wikidata_work_types.py` fetched the slices offline (0198's
-- egress rule: the query names the slice, never a user's string; the
-- matching against our labels happened on the laptop), and the
-- intersection with the vocabulary's active work concepts, ambiguity
-- refusing at every step — a name both sides carry stamps nothing, a
-- concept whose own labels disagree stamps nothing, anime beats game
-- per the owner's rule — is the 373 rows below: 269 games, 29 films,
-- 25 anime, 22 series, 28 recordings.
--
-- **`bio_category` reads the stamp first**, then the stated-parent and
-- block rules stand unchanged beneath it — and one new rule closes the
-- gap for works below Wikidata's radar: an untyped work carrying a
-- conducting `performed_by`/`composed_by` out-edge is a recording
-- (Tareefan gained hers in 0462), tested after the musicals and anime
-- blocks so a cast recording still names its musical, and before the
-- film regex so a fossil film parent cannot outrank the performance
-- the dictionary states. Mulan survives by her stamp; Tareefan falls
-- to the music frames; the two cannot be told apart any other way,
-- which is why the stamp speaks first.

begin;

create temporary table _work_types (concept_key text primary key, work_type text) on commit drop;
insert into _work_types (concept_key, work_type) values
  ('work:2048', 'game'),
  ('work:aashiqui_2', 'film'),
  ('work:agar_io', 'game'),
  ('work:age_of_empires', 'game'),
  ('work:age_of_empires_ii_the_age_of_kings', 'game'),
  ('work:age_of_empires_iii', 'game'),
  ('work:age_of_mythology', 'game'),
  ('work:ajab_prem_ki_ghazab_kahani', 'film'),
  ('work:alan_wake', 'game'),
  ('work:aldnoah_zero', 'anime'),
  ('work:alice_madness_returns', 'game'),
  ('work:all_shook_up', 'recording'),
  ('work:animal_crossing', 'game'),
  ('work:apex_legends', 'game'),
  ('work:apple', 'recording'),
  ('work:apple_1849120613', 'game'),
  ('work:assassin_s_creed_brotherhood', 'game'),
  ('work:assassin_s_creed_ii', 'game'),
  ('work:assassin_s_creed_iii', 'game'),
  ('work:assassin_s_creed_odyssey', 'game'),
  ('work:assassin_s_creed_origins', 'game'),
  ('work:assassin_s_creed_revelations', 'game'),
  ('work:assassin_s_creed_unity', 'game'),
  ('work:assassin_s_creed_valhalla', 'game'),
  ('work:attack_on_titan', 'anime'),
  ('work:august_rush', 'film'),
  ('work:baldur_s_gate', 'game'),
  ('work:baldur_s_gate_3', 'game'),
  ('work:bang_dream', 'anime'),
  ('work:bang_dream_ave_mujica', 'anime'),
  ('work:bang_dream_it_s_mygo', 'anime'),
  ('work:batman_arkham_asylum', 'game'),
  ('work:batman_arkham_city', 'game'),
  ('work:battlefield_1', 'game'),
  ('work:battlefield_2', 'game'),
  ('work:battlefield_3', 'game'),
  ('work:battlefield_4', 'game'),
  ('work:bestie', 'recording'),
  ('work:big_brother', 'tv_series'),
  ('work:bioshock', 'game'),
  ('work:bioshock_infinite', 'game'),
  ('work:black_myth_wukong', 'game'),
  ('work:bleach_thousand_year_blood_war', 'anime'),
  ('work:bloodborne', 'game'),
  ('work:boston', 'recording'),
  ('work:boys_over_flowers', 'tv_series'),
  ('work:brat', 'recording'),
  ('work:brawl_stars', 'game'),
  ('work:call_me_by_your_name', 'film'),
  ('work:call_of_duty', 'game'),
  ('work:call_of_duty_2', 'game'),
  ('work:call_of_duty_3', 'game'),
  ('work:call_of_duty_4_modern_warfare', 'game'),
  ('work:call_of_duty_advanced_warfare', 'game'),
  ('work:call_of_duty_black_ops', 'game'),
  ('work:call_of_duty_black_ops_ii', 'game'),
  ('work:call_of_duty_ghosts', 'game'),
  ('work:call_of_duty_modern_warfare_2', 'game'),
  ('work:call_of_duty_modern_warfare_3', 'game'),
  ('work:call_of_duty_world_at_war', 'game'),
  ('work:call_of_duty_wwii', 'game'),
  ('work:candy_crush_saga', 'game'),
  ('work:chainsaw_man', 'anime'),
  ('work:chic', 'recording'),
  ('work:china_blue', 'film'),
  ('work:chrono_trigger', 'game'),
  ('work:chungking_express', 'film'),
  ('work:cities_skylines', 'game'),
  ('work:civilization_iv', 'game'),
  ('work:civilization_v', 'game'),
  ('work:civilization_vi', 'game'),
  ('work:clash_of_clans', 'game'),
  ('work:clash_royale', 'game'),
  ('work:cloud_atlas', 'film'),
  ('work:club_penguin', 'game'),
  ('work:command_conquer_red_alert_2', 'game'),
  ('work:counter_strike', 'game'),
  ('work:counter_strike_2', 'game'),
  ('work:counter_strike_global_offensive', 'game'),
  ('work:counter_strike_source', 'game'),
  ('work:crash_bandicoot', 'game'),
  ('work:crazy_about_you', 'recording'),
  ('work:crazy_rich_asians', 'film'),
  ('work:crazy_stone', 'film'),
  ('work:crusader_kings_ii', 'game'),
  ('work:crysis', 'game'),
  ('work:cuphead', 'game'),
  ('work:dancing_with_the_stars', 'game'),
  ('work:dead_by_daylight', 'game'),
  ('work:death_stranding', 'game'),
  ('work:deltarune', 'game'),
  ('work:demon_slayer_kimetsu_no_yaiba', 'anime'),
  ('work:detroit_become_human', 'game'),
  ('work:deus_ex', 'game'),
  ('work:dhoom_2', 'film'),
  ('work:diablo_ii', 'game'),
  ('work:diablo_iii', 'game'),
  ('work:doki_doki_literature_club', 'game'),
  ('work:donkey_kong', 'game'),
  ('work:doom_3', 'game'),
  ('work:doom_ii', 'game'),
  ('work:dororo', 'anime'),
  ('work:dota_2', 'game'),
  ('work:dragon_age_inquisition', 'game'),
  ('work:dream_of_the_red_chamber', 'tv_series'),
  ('work:duck_hunt', 'game'),
  ('work:elden_ring', 'game'),
  ('work:empire_earth', 'game'),
  ('work:encore', 'recording'),
  ('work:euro_truck_simulator_2', 'game'),
  ('work:europa_universalis_iv', 'game'),
  ('work:eve_online', 'game'),
  ('work:extraordinary_you', 'tv_series'),
  ('work:face_to_fate', 'tv_series'),
  ('work:factorio', 'game'),
  ('work:fall_guys', 'game'),
  ('work:fallout_2', 'game'),
  ('work:fallout_3', 'game'),
  ('work:fallout_4', 'game'),
  ('work:fallout_new_vegas', 'game'),
  ('work:far_cry_2', 'game'),
  ('work:far_cry_3', 'game'),
  ('work:far_cry_4', 'game'),
  ('work:far_cry_5', 'game'),
  ('work:far_cry_6', 'game'),
  ('work:fate_stay_night', 'anime'),
  ('work:fifa_08', 'game'),
  ('work:fifa_18', 'game'),
  ('work:fifa_20', 'game'),
  ('work:fifa_23', 'game'),
  ('work:fight_for_my_way', 'tv_series'),
  ('work:final_fantasy', 'game'),
  ('work:final_fantasy_iv', 'game'),
  ('work:final_fantasy_ix', 'game'),
  ('work:final_fantasy_vi', 'game'),
  ('work:final_fantasy_vii', 'game'),
  ('work:final_fantasy_vii_rebirth', 'game'),
  ('work:final_fantasy_viii', 'game'),
  ('work:final_fantasy_x', 'game'),
  ('work:final_fantasy_xii', 'game'),
  ('work:final_fantasy_xiii', 'game'),
  ('work:final_fantasy_xiv', 'game'),
  ('work:flappy_bird', 'game'),
  ('work:fortnite', 'game'),
  ('work:gamer', 'film'),
  ('work:garry_s_mod', 'game'),
  ('work:genshin_impact', 'game'),
  ('work:geoguessr', 'game'),
  ('work:geometry_dash', 'game'),
  ('work:ghost_of_tsushima', 'game'),
  ('work:god_of_war_ii', 'game'),
  ('work:god_of_war_iii', 'game'),
  ('work:gran_turismo_4', 'game'),
  ('work:grand_theft_auto_2', 'game'),
  ('work:grand_theft_auto_advance', 'game'),
  ('work:grand_theft_auto_chinatown_wars', 'game'),
  ('work:grand_theft_auto_iii', 'game'),
  ('work:grand_theft_auto_iv', 'game'),
  ('work:grand_theft_auto_liberty_city_stories', 'game'),
  ('work:grand_theft_auto_san_andreas', 'game'),
  ('work:grand_theft_auto_v', 'game'),
  ('work:grand_theft_auto_vice_city', 'game'),
  ('work:grand_theft_auto_vice_city_stories', 'game'),
  ('work:half_life', 'game'),
  ('work:half_life_2', 'game'),
  ('work:half_life_2_episode_one', 'game'),
  ('work:half_life_blue_shift', 'game'),
  ('work:halo_2', 'game'),
  ('work:halo_3', 'game'),
  ('work:halo_combat_evolved', 'game'),
  ('work:hay_day', 'game'),
  ('work:hearthstone', 'game'),
  ('work:hearts_of_iron_iv', 'game'),
  ('work:heavy_rain', 'game'),
  ('work:high_school_musical', 'recording'),
  ('work:hitman_codename_47', 'game'),
  ('work:hogwarts_legacy', 'game'),
  ('work:hollow_knight', 'game'),
  ('work:honkai_impact_3rd', 'game'),
  ('work:horizon_zero_dawn', 'game'),
  ('work:ib', 'game'),
  ('work:idol_producer', 'tv_series'),
  ('work:if_the_world_was_ending', 'recording'),
  ('work:jojo', 'recording'),
  ('work:jujutsu_kaisen', 'anime'),
  ('work:kept_5391efb653bbcfc1', 'recording'),
  ('work:kept_d80b1eff34425b87', 'recording'),
  ('work:kept_e137a5ce5ac1babf', 'recording'),
  ('work:kept_e2710e8935fb83a5', 'recording'),
  ('work:kept_e8884bea20ca5196', 'recording'),
  ('work:kingdom_hearts', 'game'),
  ('work:kiss_you', 'recording'),
  ('work:l_a_noire', 'game'),
  ('work:league_of_legends', 'game'),
  ('work:left_4_dead_2', 'game'),
  ('work:legally_blonde', 'film'),
  ('work:life_is_strange', 'game'),
  ('work:little_shop_of_horrors', 'film'),
  ('work:little_women', 'anime'),
  ('work:love_doctor', 'tv_series'),
  ('work:love_in_the_time_of_money', 'film'),
  ('work:love_yourself', 'recording'),
  ('work:luka_chuppi', 'film'),
  ('work:m_countdown', 'tv_series'),
  ('work:mafia_ii', 'game'),
  ('work:major_lazer', 'tv_series'),
  ('work:mario_bros', 'game'),
  ('work:mario_kart_64', 'game'),
  ('work:mario_kart_7', 'game'),
  ('work:mario_kart_8', 'game'),
  ('work:mario_kart_ds', 'game'),
  ('work:mario_kart_wii', 'game'),
  ('work:mass_effect', 'game'),
  ('work:mass_effect_2', 'game'),
  ('work:mass_effect_3', 'game'),
  ('work:max_payne_2_the_fall_of_max_payne', 'game'),
  ('work:medieval_ii_total_war', 'game'),
  ('work:metal_gear_solid', 'game'),
  ('work:metal_gear_solid_3_snake_eater', 'game'),
  ('work:metro_2033', 'game'),
  ('work:midnights', 'recording'),
  ('work:minecraft', 'game'),
  ('work:minecraft_dungeons', 'game'),
  ('work:minesweeper', 'game'),
  ('work:mortal_kombat_11', 'game'),
  ('work:mortal_kombat_x', 'game'),
  ('work:mount_blade', 'game'),
  ('work:myst', 'game'),
  ('work:namaste_england', 'film'),
  ('work:naruto', 'anime'),
  ('work:need_for_speed_most_wanted', 'game'),
  ('work:need_for_speed_prostreet', 'game'),
  ('work:need_for_speed_the_run', 'game'),
  ('work:need_for_speed_undercover', 'game'),
  ('work:need_for_speed_underground', 'game'),
  ('work:need_for_speed_underground_2', 'game'),
  ('work:nirvana_in_fire', 'tv_series'),
  ('work:no_man_s_sky', 'game'),
  ('work:office', 'film'),
  ('work:office_space', 'film'),
  ('work:om_shanti_om', 'film'),
  ('work:one_piece', 'anime'),
  ('work:one_spring_night', 'tv_series'),
  ('work:one_way_ticket', 'recording'),
  ('work:outlast', 'game'),
  ('work:overlord_ii', 'game'),
  ('work:overwatch', 'game'),
  ('work:paganini', 'film'),
  ('work:papers_please', 'game'),
  ('work:party_4_u', 'recording'),
  ('work:peer_gynt', 'film'),
  ('work:persona_5', 'game'),
  ('work:persona_5_dancing_in_starlight', 'game'),
  ('work:plants_vs_zombies', 'game'),
  ('work:pok_mon', 'anime'),
  ('work:pok_mon_go', 'game'),
  ('work:pok_mon_yellow', 'game'),
  ('work:pong', 'game'),
  ('work:portal', 'game'),
  ('work:portal_2', 'game'),
  ('work:prince_of_persia', 'game'),
  ('work:promare', 'anime'),
  ('work:pubg_battlegrounds', 'game'),
  ('work:quake', 'game'),
  ('work:re_zero', 'anime'),
  ('work:red_dead_redemption', 'game'),
  ('work:red_dead_redemption_2', 'game'),
  ('work:resident_evil_2', 'game'),
  ('work:resident_evil_3_nemesis', 'game'),
  ('work:resident_evil_4', 'game'),
  ('work:resident_evil_5', 'game'),
  ('work:resident_evil_7_biohazard', 'game'),
  ('work:resident_evil_village', 'game'),
  ('work:roblox', 'game'),
  ('work:rocket_league', 'game'),
  ('work:rolling_stone', 'recording'),
  ('work:rome_total_war', 'game'),
  ('work:run_on', 'tv_series'),
  ('work:run_with_the_wind', 'anime'),
  ('work:runescape', 'game'),
  ('work:say_my_name', 'recording'),
  ('work:scent_of_a_woman', 'tv_series'),
  ('work:science_fiction', 'recording'),
  ('work:silent_hill_2', 'game'),
  ('work:sister_act', 'film'),
  ('work:smith', 'tv_series'),
  ('work:space_invaders', 'game'),
  ('work:spacewar', 'game'),
  ('work:spider_man', 'game'),
  ('work:splatoon', 'game'),
  ('work:splatoon_3', 'game'),
  ('work:spore', 'game'),
  ('work:star_wars_knights_of_the_old_republic', 'game'),
  ('work:starcraft', 'game'),
  ('work:stardew_valley', 'game'),
  ('work:starry_sky', 'game'),
  ('work:steins_gate', 'anime'),
  ('work:stellaris', 'game'),
  ('work:subway_surfers', 'game'),
  ('work:super_mario_3d_world', 'game'),
  ('work:super_mario_64', 'game'),
  ('work:super_mario_bros_3', 'game'),
  ('work:super_mario_bros_the_lost_levels', 'game'),
  ('work:super_mario_galaxy', 'game'),
  ('work:super_mario_kart', 'game'),
  ('work:super_mario_land', 'game'),
  ('work:super_mario_odyssey', 'game'),
  ('work:super_mario_world', 'game'),
  ('work:super_smash_bros_brawl', 'game'),
  ('work:super_smash_bros_ultimate', 'game'),
  ('work:sword_art_online', 'anime'),
  ('work:takt_op_destiny', 'anime'),
  ('work:tamagotchi', 'anime'),
  ('work:team_fortress_2', 'game'),
  ('work:tekken_3', 'game'),
  ('work:temple_run', 'game'),
  ('work:teri_baaton_mein_aisa_uljha_jiya', 'film'),
  ('work:terraria', 'game'),
  ('work:that_time_i_got_reincarnated_as_a_slime', 'anime'),
  ('work:the_battle_for_wesnoth', 'game'),
  ('work:the_big_bang_theory', 'tv_series'),
  ('work:the_boy', 'film'),
  ('work:the_elder_scrolls_iii_morrowind', 'game'),
  ('work:the_elder_scrolls_iv_oblivion', 'game'),
  ('work:the_elder_scrolls_v_skyrim', 'game'),
  ('work:the_hobbit', 'game'),
  ('work:the_hunger_games', 'film'),
  ('work:the_idol', 'tv_series'),
  ('work:the_idolmaster', 'anime'),
  ('work:the_last_of_us_part_ii', 'game'),
  ('work:the_legend_of_zelda', 'game'),
  ('work:the_legend_of_zelda_a_link_to_the_past', 'game'),
  ('work:the_legend_of_zelda_breath_of_the_wild', 'game'),
  ('work:the_legend_of_zelda_majora_s_mask', 'game'),
  ('work:the_legend_of_zelda_ocarina_of_time', 'game'),
  ('work:the_legend_of_zelda_twilight_princess', 'game'),
  ('work:the_little_prince', 'film'),
  ('work:the_nutcracker', 'film'),
  ('work:the_rap_of_china', 'tv_series'),
  ('work:the_sims', 'game'),
  ('work:the_sims_2', 'game'),
  ('work:the_sims_3', 'game'),
  ('work:the_sims_4', 'game'),
  ('work:the_tonight_show', 'tv_series'),
  ('work:the_voice_of_china', 'tv_series'),
  ('work:the_walking_dead_season_one', 'game'),
  ('work:the_witcher_2_assassins_of_kings', 'game'),
  ('work:the_witcher_3_wild_hunt', 'game'),
  ('work:till_we_meet_again', 'film'),
  ('work:tokyo_ghoul', 'anime'),
  ('work:tom_clancy_s_rainbow_six_siege', 'game'),
  ('work:travian', 'game'),
  ('work:uncharted_2_among_thieves', 'game'),
  ('work:uncharted_3_drake_s_deception', 'game'),
  ('work:uncharted_4_a_thief_s_end', 'game'),
  ('work:uncharted_drake_s_fortune', 'game'),
  ('work:undertale', 'game'),
  ('work:veere_di_wedding', 'film'),
  ('work:voices', 'recording'),
  ('work:voodoo', 'recording'),
  ('work:wannabe', 'recording'),
  ('work:war_thunder', 'game'),
  ('work:warcraft_iii_reign_of_chaos', 'game'),
  ('work:watch_dogs', 'game'),
  ('work:wii_sports', 'game'),
  ('work:wolfenstein_3d', 'game'),
  ('work:wordle', 'game'),
  ('work:world_of_tanks', 'game'),
  ('work:world_of_warcraft', 'game'),
  ('work:young_sheldon', 'tv_series'),
  ('work:zelda_ii_the_adventure_of_link', 'game'),
  ('work:zen', 'tv_series'),
  ('work:zootopia', 'recording');

do $$
declare
  current_version text;
  current_version_id uuid;
  next_version text;
  new_version_id uuid;
  stamped integer := 0;
begin
  select version, id into current_version, current_version_id
    from ontology.versions where status = 'published';
  if current_version is null then
    return;  -- nothing to stamp; the replay is clean
  end if;
  if not exists (
    select 1 from _work_types w
    join ontology.concepts c on c.concept_key = w.concept_key
    join ontology.concept_revisions cr on cr.concept_id = c.id
     and cr.ontology_version_id = current_version_id and cr.status = 'active'
   where coalesce(cr.metadata ->> 'work_type', '') <> w.work_type) then
    return;  -- already stamped; the replay is clean
  end if;

  next_version := split_part(current_version, '.', 1) || '.'
               || split_part(current_version, '.', 2) || '.'
               || (split_part(current_version, '.', 3)::integer + 1)::text;
  insert into ontology.versions (id, version, parent_version_id, status, description)
  values (gen_random_uuid(), next_version, current_version_id, 'draft',
          '0463: Wikidata states the medium for the works it knows.');
  select id into new_version_id from ontology.versions where version = next_version;
  perform ontology.copy_forward_version(current_version_id, new_version_id);

  update ontology.concept_revisions cr
     set metadata = coalesce(cr.metadata, '{}'::jsonb)
                    || jsonb_build_object('work_type', w.work_type,
                                          'work_type_source', 'wikidata_p31')
    from _work_types w
    join ontology.concepts c on c.concept_key = w.concept_key
   where cr.concept_id = c.id
     and cr.ontology_version_id = new_version_id
     and cr.status = 'active';
  get diagnostics stamped = row_count;

  perform ontology.publish_version(new_version_id);
  perform semantic_private.enqueue_recompute_on_analysis_change(
    'ontology ' || next_version || ': ' || stamped || ' work medium(s) stamped from Wikidata');
end;
$$;

CREATE OR REPLACE FUNCTION semantic_private.bio_category(target_concept_id uuid, target_version_id uuid, target_kind text, target_predicate text, block_key text, hub_key text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case
    when target_concept_id is null then 'other'
    when exists (select 1 from ontology.concepts c
                  where c.id = target_concept_id
                    and c.concept_key like 'travel:%') then 'travel'
    when target_predicate = 'participates_in_activity'
         and exists (select 1 from ontology.concepts c
                      where c.id = target_concept_id
                        and c.concept_key like 'activity:%')
      then 'sport_doing'
    when target_kind = 'creator' then
      case
        when block_key = 'genre:classical'
             or exists (select 1 from ontology.concept_edges e
                         where e.object_concept_id = target_concept_id
                           and e.predicate_key = 'composed_by'
                           and e.status = 'active'
                           and e.ontology_version_id = target_version_id)
          then 'composer'
        when block_key = 'subject:content_creators' then 'creator'
        when hub_key = 'hub:music'
             or exists (select 1 from ontology.concept_edges e
                         where e.object_concept_id = target_concept_id
                           and e.predicate_key = 'performed_by'
                           and e.status = 'active'
                           and e.ontology_version_id = target_version_id)
          then 'performer'
        else 'other'
      end
    when target_kind = 'work' then
      case
        -- 0463: the stamped medium speaks first — read off the source,
        -- never derived, and ambiguity refused at import.
        when (select r.metadata ->> 'work_type' from ontology.concept_revisions r
               where r.concept_id = target_concept_id
                 and r.ontology_version_id = target_version_id
                 and r.status = 'active') in ('anime', 'tv_series')
          then 'tv_series'
        when (select r.metadata ->> 'work_type' from ontology.concept_revisions r
               where r.concept_id = target_concept_id
                 and r.ontology_version_id = target_version_id
                 and r.status = 'active') = 'film'
          then 'movie'
        when (select r.metadata ->> 'work_type' from ontology.concept_revisions r
               where r.concept_id = target_concept_id
                 and r.ontology_version_id = target_version_id
                 and r.status = 'active') = 'game'
          then 'game'
        when (select r.metadata ->> 'work_type' from ontology.concept_revisions r
               where r.concept_id = target_concept_id
                 and r.ontology_version_id = target_version_id
                 and r.status = 'active') = 'recording'
          then 'other'
        -- 0455: a direct parent from the games world, before the anime
        -- block may claim the term.
        when exists (select 1 from ontology.concept_edges e
                      join ontology.concepts p on p.id = e.object_concept_id
                     where e.subject_concept_id = target_concept_id
                       and e.ontology_version_id = target_version_id
                       and e.predicate_key = 'broader'
                       and e.status = 'active'
                       and (p.concept_key = 'hub:games_play'
                            or semantic_private.concept_hub(p.id, target_version_id)
                                 = 'hub:games_play'))
          then 'game'
        -- 0453: the medium-genre block outranks the hub.
        when block_key = 'genre:anime' then 'tv_series'
        when block_key = 'genre:musicals' then 'tv_series'
        when hub_key = 'hub:games_play' then 'game'
        when block_key = 'medium:literary_genres'
             or exists (select 1 from ontology.concept_revisions r
                         where r.concept_id = target_concept_id
                           and r.ontology_version_id = target_version_id
                           and r.status = 'active'
                           and r.metadata ->> 'work_type' = 'book')
          then 'book'
        -- 0463: an untyped work the dictionary hears performed is a
        -- recording — tested after musicals and anime so a cast
        -- recording still names its musical, and before the film regex
        -- so a fossil film parent cannot outrank the stated performance.
        when exists (select 1 from ontology.concept_edges e
                      where e.subject_concept_id = target_concept_id
                        and e.ontology_version_id = target_version_id
                        and e.predicate_key in ('performed_by', 'composed_by')
                        and e.status = 'active'
                        and (e.provenance_type in ('curated', 'provider')
                             or (e.provenance_type = 'learned'
                                 and (e.provenance ->> 'source' = '0374_relation_promotion'
                                      or e.provenance ->> 'rule' ~ '^[0-9]{4} '))))
          then 'other'
        when block_key ~ '^genre:.*(television|drama|sitcom|show|series)'
          then 'tv_series'
        when block_key ~ '^genre:.*(film|movie|bollywood|noir)$'
             or block_key ~ '_film$'
          then 'movie'
        when hub_key = 'hub:film_video' then 'screen'
        else 'other'
      end
    when block_key = 'subject:language_learning'
         or exists (select 1 from ontology.concepts c
                     where c.id = target_concept_id
                       and c.concept_key like 'subject:%_language')
      then 'subject_language'
    when hub_key = 'hub:ideas_learning'
         and exists (select 1 from ontology.concepts c
                      where c.id = target_concept_id
                        and c.concept_key like 'subject:%')
      then 'subject'
    else 'other'
  end;
$function$;

commit;
