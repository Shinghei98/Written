-- 0163 — an "artist" both people share must come from a music library.
--
-- **The first real match drew `Unknown Organizer`.** Timi liked David, he
-- accepted, and `seed_icebreaker` computed `theme_kind = 'artist'`,
-- `theme = 'Unknown Organizer'`, with both subjects collapsed onto it — so the
-- card would have opened their thread with *"You two both listen to Unknown
-- Organizer. You can talk about Unknown Organizer, or ask her about Unknown
-- Organizer!"*
--
-- The cause is a deny-list where an allow-list was needed. The creator branch
-- excluded `youtube` and nothing else, and `creator` is not an artist column: it
-- is whatever each distiller puts there. `CalendarDistiller` writes
-- `event.organizer?.name ?? calendar.title`, and Apple's parsed flight events
-- carry the organiser `Unknown Organizer` — four on one account, more on the
-- other — so the commonest "artist" two people shared was an airline's
-- placeholder. HealthKit, location and `user` rows were equally eligible.
--
-- **This is `0133`'s lesson in the public schema.** A deny-list is silent when a
-- new source arrives: nothing failed, nothing was logged, and the only symptom
-- was a sentence nobody would write. The branch now names the sources whose
-- `creator` genuinely is a performer or a show, so a source added later is
-- excluded until somebody decides it belongs.
--
-- Podcasts are included deliberately — the branch's own comment says "the same
-- artist *or show* on both sides", and a shared show is a real thing to talk
-- about. Both the legacy and current podcast source codes are listed because
-- both appear in `distilled_records`.
--
-- **The existing row is cleared rather than recomputed.** The trigger fixes a
-- theme at match time and never recomputes, which is deliberate: an opener that
-- changed each time the thread opened would not be an opener. So the one
-- conversation carrying the bad theme has it removed instead, and `no overlap
-- means no card` — the view draws nothing rather than something wrong.

begin;

do $migration$
declare
  src text;
  patched text;
  anchor text := $a$                  from public.distilled_records d
                 where d.user_id in (new.user_a, new.user_b)
                   and d.source <> 'youtube'
                   and d.removed_at is null
                 order by d.user_id, d.source, d.data_type, d.item_id, d.distilled_at desc
               ) l
         where l.creator <> ''$a$;
  replacement text := $a$                  from public.distilled_records d
                 where d.user_id in (new.user_a, new.user_b)
                   -- **Named, not excluded.** `creator` holds a performer in a
                   -- music library, a publisher in a podcast, and a calendar
                   -- organiser in an event — so anything not listed here is not
                   -- an artist, whatever the column is called.
                   and d.source in (
                     'apple_music', 'music_library', 'spotify',
                     'apple_podcasts', 'podcast'
                   )
                   and d.removed_at is null
                 order by d.user_id, d.source, d.data_type, d.item_id, d.distilled_at desc
               ) l
         where l.creator <> ''$a$;
begin
  select pg_get_functiondef(p.oid) into src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'seed_icebreaker';

  if src is null then
    raise exception 'seed_icebreaker is missing';
  end if;
  if position(anchor in src) = 0 then
    raise exception 'the creator branch has drifted; refusing to patch';
  end if;

  patched := replace(src, anchor, replacement);
  if patched = src then
    raise exception 'the patch changed nothing';
  end if;
  execute patched;
end;
$migration$;

-- The one conversation this produced. Cleared rather than recomputed, because
-- the trigger fixes an opener at match time by design.
update public.conversations
   set theme = null, theme_kind = null, subject_a = null, subject_b = null
 where theme = 'Unknown Organizer';

do $$
declare
  still_wrong integer;
  filtered boolean;
begin
  select count(*) into still_wrong
  from public.conversations where theme = 'Unknown Organizer';
  if still_wrong <> 0 then
    raise exception '% conversations still carry the organiser as a theme', still_wrong;
  end if;

  -- **Checked in the body, because there is no match to fire the trigger on.**
  -- A behavioural test would need two accounts and an accepted like inside this
  -- transaction; what can be asserted here is that the branch names its sources
  -- rather than excluding one.
  select pg_get_functiondef(p.oid) like '%''apple_music'', ''music_library'', ''spotify'',%'
    into filtered
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'seed_icebreaker';
  if not filtered then
    raise exception 'the creator branch does not name its sources';
  end if;

  raise notice '0163: an artist comes from a music library';
end;
$$;

commit;
