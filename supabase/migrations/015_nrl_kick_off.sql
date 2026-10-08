-- ════════════════════════════════════════════════════════════════════════════
-- 015 — "your bet's live" says the game has kicked off for NRL (bounced is AFL)
--
-- Run after 014. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

-- a game you've got a bet on has started (off unless turned on)
create or replace function ft_push_bet_live() returns trigger
language plpgsql set search_path = public as $$
begin
  begin
    if old.status = 'scheduled' and new.status = 'live' then
      perform ft_push_enqueue(u.user_id, 'bet_live', null, '🏉 Your bet’s live',
                format('%s v %s has %s', new.home_team, new.away_team, case when new.sport = 'nrl' then 'kicked off' else 'bounced' end),
                './?comp=' || u.comp_id || '&view=mybets', 'live-' || new.id)
        from (select distinct on (b.user_id) b.user_id, b.comp_id
                from ft_bets b, jsonb_array_elements(b.legs) x
               where b.status = 'pending' and x->>'match_id' = new.id) u;
    end if;
  exception when others then raise warning 'push (live): %', sqlerrm;
  end;
  return null;
end $$;
