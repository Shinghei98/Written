-- 0320 — the rows an earlier load left stranded under their own family.
--
-- `0319` merges every identity the corpus *claims*: a mention says
-- `english_label: Mob Psycho 100` for the surface `路人超能100`, and the two
-- rows are linked. What it cannot reach is a row no mention in this corpus
-- produced — `(路人超能100, anime)` and `(海賊王, work)` were minted by `0307`
-- under families the corrected emitter no longer assigns, so nothing in
-- `0319` names them and they stand alone, rendering raw.
--
-- The owner's rule is that **any** mention of `路人超能100` or `mob psycho`
-- reads as `franchise: Mob Psycho 100 (モブサイコ100)`. This is the repair for
-- the rows already in the table.
--
-- **The rule: one spelling is one node.** Where a normalized label exists
-- under several families and none of them is yet a variant, they are the same
-- thing tagged differently, and they collapse onto the best-attested row.
--
-- **Best-attested, never highest family**, which is the mistake this repair
-- was nearly built on. Preferring `franchise` picks the stub a relation object
-- created — measured on the last load, every one of 693 unlabelled `franchise`
-- rows arrived that way. The order is: a row somebody's library named
-- (`origin = 'extracted'`), then one carrying an English label, then family
-- rank, then the label itself so the choice is deterministic and a replay
-- makes the same one.
--
-- **What this is not.** It is not similarity matching: the labels are equal
-- after the dictionary's own normalisation, not merely close, and this project
-- has paid twice for closeness. It is not a row merge either — `0301`'s
-- pointer is what moves, per-variant tallies are untouched, and an authored
-- counter-link severs it.
--
-- **Homonyms are the cost, and it is small here.** Two genuinely different
-- things sharing a spelling — a band and a song named alike — become one node.
-- `review_item_is_coarse` already refuses `work`, `album` and `music_work`
-- cards, so the song was never going to be shown, and folding it into the band
-- is the outcome `BABYMONS7ER` (album) → `BABYMONSTER` (group) was asked for.

do $$
declare
  linked integer := 0;
  n integer;
begin
  for n in
    with groups as (
      select normalized_label
        from semantic_private.presumed_terms
       where canonical_term_id is null
       group by normalized_label
      having count(*) > 1),
    ranked as (
      select pt.id, pt.normalized_label,
             row_number() over (
               partition by pt.normalized_label
               order by case when pt.origin = 'extracted' then 0 else 1 end,
                        case when pt.english_label is not null then 0 else 1 end,
                        case pt.family
                          when 'person' then 0 when 'group' then 0
                          when 'franchise' then 1 when 'organization' then 1
                          when 'event' then 2 when 'activity' then 3
                          when 'anime' then 4 when 'book' then 4
                          when 'game' then 4 when 'work' then 5
                          when 'music_work' then 6 when 'album' then 7
                          else 8 end,
                        pt.family) as rank
        from semantic_private.presumed_terms pt
        join groups g on g.normalized_label = pt.normalized_label
       where pt.canonical_term_id is null),
    written as (
      insert into semantic_private.presumed_term_links
        (variant_term_id, canonical_term_id, basis, evidence)
      select v.id, c.id, 'authored',
             jsonb_build_object('source', '0320', 'rule', 'one spelling one node')
        from ranked v
        join ranked c on c.normalized_label = v.normalized_label and c.rank = 1
       where v.rank > 1 and v.id <> c.id
      returning 1)
    select count(*) from written
  loop
    linked := n;
  end loop;

  raise notice '0320: % stranded rows now point at their identity', linked;

  -- **Assert the transformation, not a count.** A replay has no dictionary, so
  -- zero is correct there; what must never be true is a normalized label left
  -- with two rows that both claim to be canonical, which is the state this
  -- migration exists to end.
  select count(*) into n
    from (select normalized_label
            from semantic_private.presumed_terms
           where canonical_term_id is null
           group by normalized_label having count(*) > 1) leftover;
  if n > 0 then
    raise exception
      '0320: % spellings still have more than one canonical row', n;
  end if;
end;
$$;
