-- ════════════════════════════════════════════════════════════════════════════
-- 010 — one switch for all chat notifications
-- Account now has a single Chat switch (prefs.chat.all); the per-room bells in the chat window
-- only count while it's on. Round wrap is still per comp; achievements unchanged.
-- Run after 009. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function ft_push_wants(p_user uuid, p_kind text, p_key text default null) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from ft_push_subs s where s.user_id = p_user)
     and case
           when p_kind like 'chat\_%' and not coalesce((p.prefs->'chat'->>'all')::boolean, true) then false   -- chat off altogether
           when p_kind = 'chat_comp'    then coalesce((p.prefs->'chat'->'comp'->>p_key)::boolean, true)
           when p_kind = 'chat_sport'   then coalesce((p.prefs->'chat'->'sport'->>p_key)::boolean, true)
           when p_kind = 'chat_global'  then coalesce((p.prefs->'chat'->>'global')::boolean, false)        -- off until turned on
           when p_kind = 'digest'       then coalesce((p.prefs->'digest'->>p_key)::boolean, true)
           when p_kind = 'achievements' then coalesce((p.prefs->>'achievements')::boolean, true)
           else false end
    from (select coalesce((select prefs from ft_profiles where user_id = p_user), '{}'::jsonb) prefs) p;
$$;
