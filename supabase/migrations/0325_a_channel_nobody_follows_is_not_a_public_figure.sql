-- 0325 — the account holder is not vocabulary, and neither is their friend.
--
-- Reading twenty YouTube rows against what the extractor made of them turned up
-- three ways a private person became a term in a dictionary shared across every
-- account. All three are structural, none needed a model to fix, and **each is
-- derivable from what the source itself states** — which is why this migration
-- computes its sets from `public.distilled_records` rather than listing names.
--
-- **1. The account holder, through YouTube's playlists.** On `playlist` and
-- `playlist_item` rows `creator` is `snippet.channelTitle`, which for a
-- person's own playlists is *their own channel*. Measured: it holds exactly one
-- value per account across every such row — `Tianmei Zhu` for one, `柔理柔理世界
-- 第一` for the other. **A field constant over an account is describing the
-- account, not the rows**, and sending it as a performer made the owner's name
-- a `person`, an `organization` and a `franchise`. It is the same defect as the
-- calendar's `creator`, which named the calendar 165 times.
--
-- Apple Music and Spotify are *not* affected and must not be swept in: their
-- `playlist_item.creator` is the real performer — Jay Chou, Raphaël Pichon —
-- so the rule is YouTube's alone.
--
-- **2. A channel nobody follows.** `subscription` rows carry
-- `subscriber_count`, which III.E.4 lets outlive thirty days precisely because
-- it is a statistic. The owner named 姚丞徽 as an acquaintance rather than a
-- public figure; YouTube says it has **14 subscribers and one video**. Beside
-- it: 阮育志 at 2, 郭冠麟 at 3, two hamster channels at 47 and 100.
--
-- **The bar is Dunbar's number, not a line drawn round this library.** An
-- audience no larger than one person's own social circle is a personal account.
-- The number is external on purpose — the same kind of anchor as IATA's
-- twenty-four hours for a flight connection — because a threshold read off the
-- five channels it was first applied to is fitted by construction.
--
-- **The measure had to be the channel, not the video.** Median view counts
-- separate nothing here: a fan repost draws 3.5 million and Smith College's own
-- upload draws 2,084.
--
-- **3. Apple's shelf furniture.** `apple_music/recommendation` carries
-- `action_weight` 0.000 and this project's standing rule is *mint no vocabulary
-- from recommendation rows*. The RIS lane sent all 250, and `Apple Music for
-- Shing Hei` and `Shing Hei Mok's Station` — two of Apple's own templates, with
-- the account holder's name substituted into them — produced `Shing Hei Mok` as
-- a `person`. Reading the name back out of Apple's template is reading what the
-- source states; guessing which terms look like people is not, and is not done
-- here.
--
-- **Redacted rather than hidden**, on `0323`'s argument: these are real people,
-- one of whom never agreed to anything, and leaving a readable label in a
-- cross-user table while merely refusing to draw it is the worse of the two
-- arrangements. `0324` then spreads the mark across the whole spelling and
-- cluster, and `review_item_is_coarse` already refuses anything marked.

alter table semantic_private.presumed_terms
  drop constraint if exists presumed_terms_excluded_reason_check;

alter table semantic_private.presumed_terms
  add constraint presumed_terms_excluded_reason_check
    check (excluded_reason is null or excluded_reason in (
      -- Still a closed vocabulary: a reason nobody can name is a reason nobody
      -- can lift, and this column decides what is never shown.
      'private_calendar',
      -- The account holder's own name, arriving as the creator of their own
      -- playlists or out of a recommendation shelf named after them.
      'account_owner',
      -- A channel whose audience is smaller than a personal network.
      'private_channel'));

do $$
declare
  owners text[];
  channels text[];
  shelves text[];
  marked integer;
  redacted integer;
  leftover integer;
begin
  -- ---------------------------------------------------------------------
  -- The three sets, each read off what the source states
  -- ---------------------------------------------------------------------

  -- **Constant per account, and asserted to be.** If a later distillation makes
  -- `creator` vary on these rows it has stopped meaning "the playlist's owner",
  -- and sweeping on it would start deleting artists.
  if exists (
    select 1 from public.distilled_records
     where source = 'youtube' and data_type in ('playlist', 'playlist_item')
     group by user_id having count(distinct creator) > 1) then
    raise exception
      '0325: youtube playlist `creator` is no longer one value per account; '
      'it has stopped naming the owner and this sweep would remove artists';
  end if;

  select coalesce(array_agg(distinct lower(btrim(creator))), '{}') into owners
    from public.distilled_records
   where source = 'youtube'
     and data_type in ('playlist', 'playlist_item')
     and coalesce(btrim(creator), '') <> '';

  select coalesce(array_agg(distinct lower(btrim(name))), '{}') into channels
    from public.distilled_records
   where source = 'youtube' and data_type = 'subscription'
     and coalesce(btrim(name), '') <> ''
     -- A count that is absent or not a number is not evidence of a large
     -- audience; an unstated size fails closed, as every other absence here
     -- does.
     and coalesce(nullif(regexp_replace(
           coalesce(extra ->> 'subscriber_count', ''), '[^0-9]', '', 'g'), ''),
         '0')::bigint < 150;

  -- Apple's two templates, with the name read back out of them. Nothing else
  -- about a recommendation row is treated as a name.
  select coalesce(array_agg(distinct lower(btrim(extracted))), '{}') into shelves
    from (
      select regexp_replace(creator, '^Apple Music for\s+', '') as extracted
        from public.distilled_records
       where source = 'apple_music' and data_type = 'recommendation'
         and creator ~ '^Apple Music for\s+\S'
      union all
      select regexp_replace(name, '(’|'')s Station$', '')
        from public.distilled_records
       where source = 'apple_music' and data_type = 'recommendation'
         and name ~ '(’|'')s Station$'
    ) templates
   where coalesce(btrim(extracted), '') <> '';

  raise notice '0325: % owner names, % private channels, % shelf names',
    coalesce(array_length(owners, 1), 0),
    coalesce(array_length(channels, 1), 0),
    coalesce(array_length(shelves, 1), 0);

  -- ---------------------------------------------------------------------
  -- Mark, then redact
  -- ---------------------------------------------------------------------
  --
  -- **Matched on every spelling the row carries**, because the dictionary holds
  -- 姚丞徽 and `Yao Chenghui` as separate rows and the source states only the
  -- first. `original_label` is where the native form was filed, so a romanised
  -- row is reached through it.

  with matches as (
    select pt.id,
           case when lower(btrim(coalesce(pt.normalized_label, ''))) = any(channels)
                  or lower(btrim(coalesce(pt.original_label, ''))) = any(channels)
                then 'private_channel'
                else 'account_owner' end as reason
      from semantic_private.presumed_terms pt
     where pt.excluded_reason is null
       and (lower(btrim(coalesce(pt.normalized_label, ''))) = any(owners || shelves || channels)
         or lower(btrim(coalesce(pt.original_label, ''))) = any(owners || shelves || channels)
         or lower(btrim(coalesce(pt.canonical_label, ''))) = any(owners || shelves || channels))
  ),
  applied as (
    update semantic_private.presumed_terms pt
       set excluded_reason = m.reason
      from matches m
     where pt.id = m.id
    returning 1)
  select count(*) into marked from applied;

  raise notice '0325: % terms marked', marked;

  -- **`0324`'s spread, run again for the rows this migration just marked.**
  -- One spelling is one thing, so a mark on any row of a cluster is a mark on
  -- all of it — otherwise `Yao Chenghui` is refused and `姚丞徽` is drawn.
  with marked_labels as (
    select distinct normalized_label from semantic_private.presumed_terms
     where excluded_reason is not null),
  marked_clusters as (
    select distinct coalesce(canonical_term_id, id) as cluster_id
      from semantic_private.presumed_terms where excluded_reason is not null),
  spreading as (
    update semantic_private.presumed_terms pt
       set excluded_reason = 'account_owner'
     where pt.excluded_reason is null
       and (pt.normalized_label in (select normalized_label from marked_labels)
            or coalesce(pt.canonical_term_id, pt.id)
                 in (select cluster_id from marked_clusters))
    returning 1)
  select count(*) into leftover from spreading;
  raise notice '0325: % sibling rows carried the mark', leftover;

  -- **A person who never agreed to anything keeps no readable label.** Same
  -- redaction `0323` performs, and for the same reason: hiding a name from a
  -- card while leaving it legible in a cross-user table is the worse of the two
  -- arrangements. `normalized_label` goes too, since it *is* the name.
  update semantic_private.presumed_terms
     set normalized_label = 'redacted:' || id::text,
         canonical_label = 'redacted',
         english_label = null,
         original_label = null
   where excluded_reason in ('account_owner', 'private_channel')
     and canonical_label <> 'redacted';
  get diagnostics redacted = row_count;
  raise notice '0325: % rows redacted', redacted;

  -- ---------------------------------------------------------------------
  -- Assert the state, which holds on an empty replay too
  -- ---------------------------------------------------------------------

  select count(*) into leftover
    from semantic_private.presumed_terms
   where excluded_reason in ('account_owner', 'private_channel')
     and (canonical_label <> 'redacted' or english_label is not null
          or original_label is not null);
  if leftover > 0 then
    raise exception '0325: % excluded terms still carry a readable label', leftover;
  end if;

  select count(*) into leftover
    from (select normalized_label from semantic_private.presumed_terms
           group by normalized_label
          having count(*) filter (where excluded_reason is not null) > 0
             and count(*) filter (where excluded_reason is null) > 0) split;
  if leftover > 0 then
    raise exception
      '0325: % spellings are excluded under one family and allowed under another',
      leftover;
  end if;
end;
$$;
