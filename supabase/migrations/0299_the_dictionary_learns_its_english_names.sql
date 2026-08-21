-- 0299 — the dictionary learns the English names it was never told.
--
-- The 35 foreign terms on the current review cards were extracted before the
-- wire carried english_label, so 0297's rendering had nothing to draw. These
-- are the model's own translations, obtained through the live lane (batched
-- probe calls under qwen_extractor_v11, 2026-08-21) and written under the
-- dictionary's standing rule: presumed, user-validated, never deleted. Three
-- timed out and stay untranslated; a handful are visibly wrong the way a
-- presumed term is allowed to be wrong (지젤 is Giselle, not Jisoo) — the
-- keep/edit/strike loop is the correction path, not this file. Guarded on
-- `english_label is null` throughout: a later, better answer is never
-- overwritten by this one, and on an empty database this updates nothing.

update semantic_private.presumed_terms set english_label = 'Éder Quartet', original_label = coalesce(original_label, 'Éder Quartet') where normalized_label = 'éder quartet' and family = 'group' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Chaewon', original_label = coalesce(original_label, 'チェウォン') where normalized_label = 'チェウォン' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Yi San Mi Tao Shuo', original_label = coalesce(original_label, '一三蜜桃说') where normalized_label = '一三蜜桃说' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Human Laboratory Channel', original_label = coalesce(original_label, '人类实验室 Human Laboratory Channel') where normalized_label = '人类实验室 human laboratory channel' and family = 'organization' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Fu Changpeng', original_label = coalesce(original_label, '傅長膨AnimaJinx') where normalized_label = '傅長膨animajinx' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Wu Hao', original_label = coalesce(original_label, '吴昊') where normalized_label = '吴昊' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Vivian Chow', original_label = coalesce(original_label, '周慧敏') where normalized_label = '周慧敏' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Jay Chou', original_label = coalesce(original_label, '周杰倫') where normalized_label = '周杰倫' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = '塌鼻梁', original_label = coalesce(original_label, '塌鼻梁') where normalized_label = '塌鼻梁' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Na Ge Nai Ji', original_label = coalesce(original_label, '娜個奶姬') where normalized_label = '娜個奶姬' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Man Shi Man Yu', original_label = coalesce(original_label, '曼食慢语 Amanda Tastes') where normalized_label = '曼食慢语 amanda tastes' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Lin Chia-Ling', original_label = coalesce(original_label, '林嘉凌') where normalized_label = '林嘉凌' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Loki', original_label = coalesce(original_label, '洛基') where normalized_label = '洛基' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Zen Master Does Not Sit in Meditation', original_label = coalesce(original_label, '禪師不打坐') where normalized_label = '禪師不打坐' and family = 'activity' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Akizawa Yoh', original_label = coalesce(original_label, '秋山燿平') where normalized_label = '秋山燿平' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Qiang Qiang', original_label = coalesce(original_label, '薔薔') where normalized_label = '薔薔' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Kim Jae-won', original_label = coalesce(original_label, '김재원') where normalized_label = '김재원' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Na Young', original_label = coalesce(original_label, '나영') where normalized_label = '나영' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Lightsum', original_label = coalesce(original_label, '라잇썸') where normalized_label = '라잇썸' and family = 'organization' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Ray', original_label = coalesce(original_label, '레이') where normalized_label = '레이' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Luka', original_label = coalesce(original_label, '루카') where normalized_label = '루카' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Makbang', original_label = coalesce(original_label, '막방') where normalized_label = '막방' and family = 'activity' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Moka', original_label = coalesce(original_label, '모카') where normalized_label = '모카' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Minnie', original_label = coalesce(original_label, '미나') where normalized_label = '미나' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Min-jeong', original_label = coalesce(original_label, '미연') where normalized_label = '미연' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Min-ji', original_label = coalesce(original_label, '민주') where normalized_label = '민주' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Kazuha', original_label = coalesce(original_label, '아일릿') where normalized_label = '아일릿' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Yujin', original_label = coalesce(original_label, '안유진') where normalized_label = '안유진' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Winter', original_label = coalesce(original_label, '윈터') where normalized_label = '윈터' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Jisoo', original_label = coalesce(original_label, '지젤') where normalized_label = '지젤' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Chaewon', original_label = coalesce(original_label, '채원이') where normalized_label = '채원이' and family = 'person' and english_label is null;
update semantic_private.presumed_terms set english_label = 'Karina', original_label = coalesce(original_label, '카리나') where normalized_label = '카리나' and family = 'person' and english_label is null;
