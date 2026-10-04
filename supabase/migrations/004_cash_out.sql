-- ════════════════════════════════════════════════════════════════════════════
-- 004 — cash out
-- A pending bet can be cashed out once any of its games has started. The offer is
--   stake × (won legs' prices) × Π(open legs: price × chance it still lands × (1 − cut))
-- capped at the potential payout. The cut is a comp rule (rules.cashout = % per open leg,
-- −1 = cash out off, default 5).
--
-- ft_leg_eval() judges one leg against its match — upcoming / pending (with a chance) /
-- won / lost / void. Bet settlement (a later migration) uses it too, so a leg is judged
-- the same way everywhere. The page mirrors this in evalLeg() / cashOutQuote(); keep the
-- two in step.
-- Run after 003. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

-- bets can now end as cashed out
alter table ft_bets drop constraint if exists ft_bets_status_check;
alter table ft_bets add constraint ft_bets_status_check
  check (status in ('pending','won','lost','void','cashed_out'));

-- other members see any finished bet (incl. cash outs) for Key Moments; pending stays private
drop policy if exists ft_bets_read on ft_bets;
create policy ft_bets_read on ft_bets for select to authenticated
  using (user_id = auth.uid() or (status <> 'pending' and ft_is_member(comp_id)));


-- ── maths ───────────────────────────────────────────────────────────────────

-- standard normal CDF (Abramowitz–Stegun 7.1.26)
create or replace function ft_ncdf(x float8) returns float8
language plpgsql immutable as $$
declare z float8 := abs(x)/sqrt(2.0); t float8; y float8;
begin
  t := 1/(1+0.3275911*z);
  y := 1 - (((((1.061405429*t - 1.453152027)*t) + 1.421413741)*t - 0.284496736)*t + 0.254829592)*t*exp(-z*z);
  return case when x >= 0 then (1+y)/2 else (1-y)/2 end;
end $$;

-- inverse normal CDF (Acklam)
create or replace function ft_ninv(p float8) returns float8
language plpgsql immutable as $$
declare
  a float8[] := array[-39.69683028665376,220.9460984245205,-275.9285104469687,138.357751867269,-30.66479806614716,2.506628277459239];
  b float8[] := array[-54.47609879822406,161.5858368580409,-155.6989798598866,66.80131188771972,-13.28068155288572];
  c float8[] := array[-0.007784894002430293,-0.3223964580411365,-2.400758277161838,-2.549732539343734,4.374664141464968,2.938163982698783];
  d float8[] := array[0.007784695709041462,0.3224671290700398,2.445134137142996,3.754408661907416];
  q float8; r float8;
begin
  p := least(1-1e-9, greatest(1e-9, p));
  if p < 0.02425 then
    q := sqrt(-2*ln(p));
    return (((((c[1]*q+c[2])*q+c[3])*q+c[4])*q+c[5])*q+c[6])/((((d[1]*q+d[2])*q+d[3])*q+d[4])*q+1);
  elsif p > 1-0.02425 then
    q := sqrt(-2*ln(1-p));
    return -(((((c[1]*q+c[2])*q+c[3])*q+c[4])*q+c[5])*q+c[6])/((((d[1]*q+d[2])*q+d[3])*q+d[4])*q+1);
  end if;
  q := p-0.5; r := q*q;
  return (((((a[1]*r+a[2])*r+a[3])*r+a[4])*r+a[5])*r+a[6])*q/(((((b[1]*r+b[2])*r+b[3])*r+b[4])*r+b[5])*r+1);
end $$;

-- Poisson P(N ≤ k)
create or replace function ft_pois_cdf(lam float8, k int) returns float8
language plpgsql immutable as $$
declare term float8; s float8;
begin
  if k < 0 then return 0; end if;
  term := exp(-lam); s := term;
  for i in 1..k loop term := term*lam/i; s := s + term; end loop;
  return least(1, s);
end $$;

-- Poisson P(N ≥ k)
create or replace function ft_pois_ge(lam float8, k int) returns float8
language sql immutable as $$
  select case when k <= 0 then 1::float8 else 1 - ft_pois_cdf(lam, k-1) end;
$$;

-- the full-game rate that makes the pre-game chance match the odds (bisection)
create or replace function ft_pois_lambda(p0 float8, k int, under boolean) returns float8
language plpgsql immutable as $$
declare lo float8 := 1e-4; hi float8 := 300; mid float8; v float8;
begin
  for i in 1..60 loop
    mid := (lo+hi)/2;
    v := case when under then ft_pois_cdf(mid, k) else ft_pois_ge(mid, k) end;
    if (under and v > p0) or (not under and v < p0) then lo := mid; else hi := mid; end if;
  end loop;
  return (lo+hi)/2;
end $$;

-- a team's score after k completed periods, from the live snapshot
-- (AFL periods hold [goals, behinds]; NRL periods hold points)
create or replace function ft_score_at(m ft_matches, side text, k int) returns float8
language plpgsql immutable as $$
declare v jsonb;
begin
  if k <= 0 then return 0; end if;
  v := m.live -> side -> (k-1);
  if v is null then return null; end if;
  if jsonb_typeof(v) = 'array' then return (v->>0)::float8*6 + (v->>1)::float8; end if;
  return (v #>> '{}')::float8;
end $$;


-- ── one leg against its match ───────────────────────────────────────────────
-- st: 'upcoming' (not started), 'pending' (p = chance it lands), 'won', 'lost', 'void'
create or replace function ft_leg_eval(l jsonb, m ft_matches, out st text, out p float8)
language plpgsql stable set search_path = public as $$
declare
  p0 float8 := least(0.999, 1.0 / nullif((l->>'price')::float8, 0));
  mk text := l->>'market';
  base text; per text;
  n int; plen float8; done boolean; frac float8; q int; secs float8;
  ps float8 := 0; pe float8; completed int; decided boolean;
  h0 float8; a0 float8; hs float8; as_ float8; wf float8; r float8;
  s_margin float8; s_total float8; s_team float8; sg float8; mu float8; pt float8; v float8; mine float8; z float8;
  stat text; sc_type text; who text; pl jsonb; cur_v float8; k int; lim int; mx float8; first_p text; last_p text;
  is_over boolean;
begin
  st := 'upcoming'; p := coalesce(p0, 0.5);
  if m.id is null then return; end if;
  done := m.status = 'concluded';
  if not done and m.status = 'scheduled' and m.commence_time > now() then return; end if;   -- not started

  n    := case when m.sport = 'nrl' then 2 else 4 end;
  plen := case when m.sport = 'nrl' then 2400 else 1800 end;
  q    := coalesce((m.live->>'q')::int, 1);
  secs := coalesce((m.live->>'clockSecs')::float8, 0);
  frac := case when done then 1 else least(1, ((q-1) + least(secs, plen)/plen)/n) end;
  s_margin := case when m.sport = 'nrl' then 15 else 37 end;
  s_total  := case when m.sport = 'nrl' then 12 else 26 end;
  s_team   := case when m.sport = 'nrl' then 9  else 18 end;

  per  := substring(mk from '_(q[1-4]|h[12])$');
  base := case when per is null then mk else regexp_replace(mk, '_(q[1-4]|h[12])$', '') end;
  st := 'pending';

  -- ── player markets ──
  if base like 'player\_%' then
    who := l->>'description';
    sc_type := case when m.sport = 'nrl' then 'try' else 'goal' end;
    select e->>'player' into first_p from jsonb_array_elements(coalesce(m.live->'events','[]')) e
     where e->>'type' = sc_type order by (e->>'q')::int, (e->>'secs')::float8 limit 1;
    if base like '%\_scorer\_first' then
      if first_p is not null then st := case when first_p = who then 'won' else 'lost' end;
      elsif done then st := 'void'; end if;
      p := case st when 'won' then 1 when 'lost' then 0 else p0 end; return;
    end if;
    if base like '%\_scorer\_last' then
      if done then
        select e->>'player' into last_p from jsonb_array_elements(coalesce(m.live->'events','[]')) e
         where e->>'type' = sc_type order by (e->>'q')::int desc, (e->>'secs')::float8 desc limit 1;
        st := case when last_p is null then 'void' when last_p = who then 'won' else 'lost' end;
      end if;
      p := case st when 'won' then 1 when 'lost' then 0 else p0 end; return;
    end if;
    stat := case base
      when 'player_disposals_over' then 'd' when 'player_disposals' then 'd' when 'player_kicks_over' then 'k'
      when 'player_handballs_over' then 'h' when 'player_marks_over' then 'm' when 'player_marks_most' then 'm'
      when 'player_tackles_over' then 't' when 'player_tackles_most' then 't' when 'player_clearances_over' then 'cl'
      when 'player_goals_scored_over' then 'g' when 'player_goal_scorer_anytime' then 'g'
      when 'player_afl_fantasy_points_over' then 'af' when 'player_afl_fantasy_points' then 'af'
      when 'player_afl_fantasy_points_most' then 'af'
      when 'player_try_scorer_over' then 'tr' when 'player_try_scorer_anytime' then 'tr' end;
    select e into pl from jsonb_array_elements(coalesce(m.live->'players','[]')) e where e->>'name' = who limit 1;
    if base like '%\_most' then
      if done then
        if pl is null then st := 'void';
        else
          select max(coalesce((e->>stat)::float8,0)) into mx from jsonb_array_elements(m.live->'players') e;
          st := case when coalesce((pl->>stat)::float8,0) = mx then 'won' else 'lost' end;
        end if;
      end if;
      p := case st when 'won' then 1 when 'lost' then 0 else p0 end; return;
    end if;
    if stat is null or pl is null or pl->stat is null then        -- not playing / a stat we don't track
      st := case when done then 'void' else 'pending' end; p := p0; return;
    end if;
    cur_v := coalesce((pl->>stat)::float8, 0);
    if l->>'name' = 'Under' then
      lim := floor((l->>'point')::float8)::int;
      if cur_v > lim then st := 'lost'; p := 0;
      elsif done then st := 'won'; p := 1;
      else p := ft_pois_cdf(ft_pois_lambda(p0, lim, true)*(1-frac), lim - cur_v::int); end if;
      return;
    end if;
    k := case when base like '%\_anytime' then 1 else ceil((l->>'point')::float8)::int end;
    if cur_v >= k then st := 'won'; p := 1;
    elsif done then st := 'lost'; p := 0;
    else p := ft_pois_ge(ft_pois_lambda(p0, k, false)*(1-frac), k - cur_v::int); end if;
    return;
  end if;

  -- ── team markets: the whole game, a quarter or a half ──
  pe := n;
  if per like 'q%' then ps := substring(per from 2)::int - 1; pe := ps + 1;
  elsif per = 'h1' then ps := 0; pe := n/2.0;
  elsif per = 'h2' then ps := n/2.0; pe := n; end if;
  if frac*n < ps then p := p0; return; end if;                   -- its quarter/half hasn't started
  completed := case when done then n else greatest(0, q-1) end;
  decided := completed >= pe;
  h0 := coalesce(ft_score_at(m, 'home', ps::int), 0);
  a0 := coalesce(ft_score_at(m, 'away', ps::int), 0);
  if decided and not (pe = n and done) then
    hs := coalesce(ft_score_at(m, 'home', pe::int), 0) - h0; as_ := coalesce(ft_score_at(m, 'away', pe::int), 0) - a0;
  else
    hs := coalesce(m.home_score, 0) - h0; as_ := coalesce(m.away_score, 0) - a0;
  end if;
  wf := (pe-ps)/n;
  r  := greatest(0.001, (pe/n - frac)/wf);

  if base in ('h2h','h2h_3_way','spreads','alternate_spreads') then
    if l->>'name' = 'Draw' then
      if decided then st := case when hs = as_ then 'won' else 'lost' end; end if;
      p := case st when 'won' then 1 when 'lost' then 0 else p0 end; return;
    end if;
    mine := case when l->>'name' = m.home_team then hs - as_ else as_ - hs end;
    pt := case when base in ('spreads','alternate_spreads') then coalesce((l->>'point')::float8, 0) else 0 end;
    if decided then
      v := mine + pt;
      st := case when v > 0 then 'won' when v < 0 then 'lost' else 'void' end;
      p := case st when 'won' then 1 when 'lost' then 0 else p0 end; return;
    end if;
    sg := s_margin*sqrt(wf); mu := sg*ft_ninv(p0) - pt;
    p := ft_ncdf((mine + pt + mu*r)/(sg*sqrt(r))); return;
  end if;

  if base in ('totals','alternate_totals','team_totals','alternate_team_totals') then
    v := case when base like '%team\_totals' then (case when l->>'description' = m.home_team then hs else as_ end) else hs + as_ end;
    pt := (l->>'point')::float8;
    is_over := l->>'name' = 'Over';
    if decided then
      st := case when v = pt then 'void' when (v > pt) = is_over then 'won' else 'lost' end;
      p := case st when 'won' then 1 when 'lost' then 0 else p0 end; return;
    end if;
    sg := (case when base like '%team\_totals' then s_team else s_total end)*sqrt(wf);
    mu := case when is_over then pt + sg*ft_ninv(p0) else pt - sg*ft_ninv(p0) end;
    z := (v + mu*r - pt)/(sg*sqrt(r));
    p := case when is_over then ft_ncdf(z) else ft_ncdf(-z) end; return;
  end if;

  -- a market we can't judge
  st := case when done then 'void' else 'pending' end; p := p0;
end $$;


-- ── a bet's cash out offer (null when it can't be cashed out) ──────────────
create or replace function ft_cash_out_value(b ft_bets, cut float8) returns numeric
language plpgsql stable set search_path = public as $$
declare
  l jsonb; m ft_matches; e_st text; e_p float8;
  v float8 := b.stake; started boolean := false; n_open int := 0;
begin
  if b.status <> 'pending' or cut is null or cut < 0 then return null; end if;
  for l in select * from jsonb_array_elements(b.legs) loop
    select * into m from ft_matches where id = l->>'match_id';
    select st, p into e_st, e_p from ft_leg_eval(l, m);
    if e_st <> 'upcoming' then started := true; end if;
    if e_st = 'lost' then return null; end if;
    if e_st = 'won' then v := v * (l->>'price')::float8;
    elsif e_st in ('pending','upcoming') then v := v * (l->>'price')::float8 * e_p * (1-cut); n_open := n_open + 1;
    end if;
  end loop;
  if not started or n_open = 0 then return null; end if;
  v := least(b.potential_payout::float8, floor(v*100)/100);
  return case when v >= 0.01 then round(v::numeric, 2) else null end;
end $$;


-- ── cash out: re-price on the server, pay it, close the bet ─────────────────
-- p_quote is the offer the player saw; if the game has moved it on (by more than
-- 3% or 50c), nothing is paid and the error carries the new value for the page to show.
create or replace function ft_cash_out(p_bet uuid, p_quote numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b ft_bets; c ft_comps; cut float8; v numeric; bal numeric;
begin
  select * into b from ft_bets where id = p_bet and user_id = auth.uid() for update;
  if b.id is null then raise exception 'Bet not found.'; end if;
  if b.status <> 'pending' then raise exception 'This bet has already been settled.'; end if;
  select * into c from ft_comps where id = b.comp_id;
  cut := coalesce((c.rules->>'cashout')::float8, 5);
  if cut < 0 then raise exception 'Cash out is off in this comp.'; end if;
  v := ft_cash_out_value(b, cut/100.0);
  if v is null then raise exception 'Cash out isn’t available on this bet right now.'; end if;
  if abs(v - p_quote) > greatest(0.5, p_quote*0.03) then
    raise exception 'cash out value changed: %', v;
  end if;
  update ft_bets set status = 'cashed_out', payout = v, settled_at = now() where id = b.id;
  update ft_members set balance = balance + v
   where comp_id = b.comp_id and user_id = auth.uid()
  returning balance into bal;
  return jsonb_build_object('payout', v, 'balance', bal);
end $$;

revoke all on function ft_cash_out(uuid,numeric) from public, anon;
grant execute on function ft_cash_out(uuid,numeric) to authenticated;


-- ── hosting now takes the cash out rule ─────────────────────────────────────
create or replace function ft_host_comp(p_name text, p_username text, p_starting_balance numeric, p_rules jsonb, p_season int, p_sport text default 'afl')
returns ft_comps
language plpgsql security definer set search_path = public as $$
declare
  v_comp  ft_comps;
  v_rules jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_starting_balance is null or p_starting_balance <= 0 then raise exception 'starting balance must be more than zero'; end if;
  -- keep rules in range: 2–15 legs, stake limit ≥ 0 (0 = none), props on/off,
  -- cash out −1 (off) or a 0–20% cut per open leg
  v_rules := jsonb_build_object(
    'max_legs',  least(15, greatest(2, coalesce((p_rules->>'max_legs')::int, 15))),
    'max_stake', greatest(0, coalesce((p_rules->>'max_stake')::numeric, 0)),
    'props',     coalesce((p_rules->>'props')::boolean, true),
    'cashout',   case when coalesce((p_rules->>'cashout')::numeric, 5) < 0 then -1
                      else least(20, coalesce((p_rules->>'cashout')::numeric, 5)) end);

  insert into ft_comps (name, code, sport, season, starting_balance, start_round, rules)
  values (trim(p_name), ft_new_code_value(), p_sport, p_season, p_starting_balance, ft_current_round(p_sport, p_season), v_rules)
  returning * into v_comp;

  insert into ft_members (comp_id, user_id, username, is_host, balance)
  values (v_comp.id, auth.uid(), trim(p_username), true, p_starting_balance);

  return v_comp;
end $$;
