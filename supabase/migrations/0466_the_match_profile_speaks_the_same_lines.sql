-- 0466 — the match profile speaks the same lines as the feed.
--
-- **The owner's direction (2026-08-28)**: tapping a match's picture
-- opens their profile — six photographs as six cards — and each card's
-- text is the same dynamic bio the discovery page composes. The feed
-- gets its ingredients from `matching_terms`; the profile page had only
-- the legacy overlap captions, because `match_card` predates the term
-- machinery. It now returns the same `terms` column `discover_profiles`
-- does, from the same function, so the two surfaces cannot drift: one
-- gate stack (suppressions, the witness, the rollup exclusion) already
-- lives inside `matching_terms` and is not restated here.
--
-- Authorization is unchanged and strictly narrower than the feed's:
-- `may_see_match` still guards the whole answer, and a matched viewer
-- is more authorized than the eligible stranger `discover_profiles`
-- already serves these terms to.
--
-- The return type gains a column, and `create or replace` cannot change
-- a signature — it overloads, and an overload raises 42725 from inside
-- whatever calls it (the 0009-era lesson). So: drop by full signature,
-- recreate, and re-state the grants the drop discards — execute to
-- `authenticated` and `service_role`, and the default-privilege grant
-- to `anon` revoked by name, the block-list discipline.

begin;

drop function public.match_card(uuid);

CREATE FUNCTION public.match_card(target uuid)
 RETURNS TABLE(user_id uuid, display_name text, age integer, district text, photo_seeds integer[], photo_paths text[], interests jsonb, domains jsonb, top_subjects jsonb, terms jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  me uuid := (select auth.uid());
begin
  if not private.may_see_match(me, target) then
    return;
  end if;

  return query
  select c.user_id, c.display_name, c.age, c.district, c.photo_seeds,
         c.photo_paths, c.interests, c.domains, c.top_subjects,
         semantic_private.matching_terms(target)
    from public.discovery_cards c
   where c.user_id = target;
end;
$function$;

-- Both revocations, because they are different holes: the default
-- privilege lands on PUBLIC (the pseudo-role every role inherits),
-- and a direct anon grant would survive a PUBLIC revoke untouched.
revoke execute on function public.match_card(uuid) from public;
revoke execute on function public.match_card(uuid) from anon;
grant execute on function public.match_card(uuid) to authenticated;
grant execute on function public.match_card(uuid) to service_role;

commit;
