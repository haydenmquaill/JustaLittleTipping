-- ════════════════════════════════════════════════════════════════════════════
-- 011 — weekly spend: a third bankroll for hosts
--
--   'once'    one starting amount for the season                     profit = balance − amount
--   'weekly'  the amount again every round, everything carries over  profit = balance − everything received
--   'spend'   the amount to bet every round; nothing carries over. When a round closes, anything above
--             the amount is BANKED and your balance goes back to the amount. A round can't bank less
--             than $0, so blowing it all costs nothing compared with sitting out.
--             profit = banked + anything above the amount right now (never negative)
-- Winnings landing mid-round are spendable that round in every mode.
--
--   ft_members.banked      weekly spend: total banked so far
--   history snapshots      now { b, f, k } (k = banked)
--   ft_member_profit()     the one profit formula: leaderboard, round wrap, achievements
--   ft_rule_amt()          achievement amounts can be multiples of the comp's amount:
--                          { "amount_mult": 2 } = 2 × the starting / weekly amount
--
-- Run after 010. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

alter table ft_members add column if not exists banked numeric(12,2) not null default 0;

create or replace function ft_member_profit(p_balance numeric, p_funded numeric, p_banked numeric, p_start numeric, p_bankroll text)
returns numeric language sql immutable as $$
  select case when p_bankroll = 'spend' then coalesce(p_banked, 0) + greatest(0, p_balance - p_start)
              else p_balance - p_funded end;
$$;

-- a rule's money threshold: a plain amount, or <key>_mult × the comp's amount
create or replace function ft_rule_amt(p_rule jsonb, p_key text, p_start numeric) returns numeric
language sql immutable as $$
  select coalesce((p_rule->>p_key)::numeric, (p_rule->>(p_key || '_mult'))::numeric * p_start);
$$;

-- profit at the end of a round from a member's history ({ b, f, k }, { b, f } or an old plain balance)
create or replace function ft_hist_profit(p_hist jsonb, p_round int, p_start numeric) returns numeric
language sql immutable as $$
  select case when p_hist->(p_round::text) is null then null
              when jsonb_typeof(p_hist->(p_round::text)) = 'number' then (p_hist->>(p_round::text))::numeric - p_start
              when (p_hist->(p_round::text)) ? 'k' then ((p_hist->(p_round::text))->>'k')::numeric
                                                       + greatest(0, ((p_hist->(p_round::text))->>'b')::numeric - p_start)
              else ((p_hist->(p_round::text))->>'b')::numeric - ((p_hist->(p_round::text))->>'f')::numeric end;
$$;

-- ── hosting: 'spend' joins 'weekly' and 'once' (006's version otherwise) ──
create or replace function ft_host_comp(p_name text, p_username text, p_starting_balance numeric, p_rules jsonb, p_season int, p_sport text default 'afl')
returns ft_comps
language plpgsql security definer set search_path = public as $$
declare
  v_comp  ft_comps;
  v_rules jsonb;
  v_round int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_starting_balance is null or p_starting_balance <= 0 then raise exception 'starting balance must be more than zero'; end if;
  -- keep rules in range: 2–15 legs, stake limit ≥ 0 (0 = none), props on/off,
  -- cash out −1 (off) or a 0–20% cut per open leg, bankroll weekly/once
  v_rules := jsonb_build_object(
    'max_legs',  least(15, greatest(2, coalesce((p_rules->>'max_legs')::int, 15))),
    'max_stake', greatest(0, coalesce((p_rules->>'max_stake')::numeric, 0)),
    'props',     coalesce((p_rules->>'props')::boolean, true),
    'cashout',   case when coalesce((p_rules->>'cashout')::numeric, 5) < 0 then -1
                      else least(20, coalesce((p_rules->>'cashout')::numeric, 5)) end,
    'bankroll',  case p_rules->>'bankroll' when 'once' then 'once' when 'spend' then 'spend' else 'weekly' end);
  v_round := ft_current_round(p_sport, p_season);

  insert into ft_comps (name, code, sport, season, starting_balance, start_round, rules)
  values (trim(p_name), ft_new_code_value(), p_sport, p_season, p_starting_balance, v_round, v_rules)
  returning * into v_comp;

  insert into ft_members (comp_id, user_id, username, is_host, balance, funded, funded_round)
  values (v_comp.id, auth.uid(), trim(p_username), true, p_starting_balance, p_starting_balance, v_round);

  return v_comp;
end $$;


-- ── round close: weekly spend banks and resets before the snapshot (008's version otherwise) ──
create or replace function ft_close_rounds() returns int
language plpgsql set search_path = public as $$
declare r record; cnt int := 0;
begin
  for r in
    select m.sport, m.season, m.round, bool_or(m.stage = 'grand_final') gf from ft_matches m
     group by m.sport, m.season, m.round
    having bool_and(m.status = 'concluded')
       and not exists (select 1 from ft_round_closed c where c.sport = m.sport and c.season = m.season and c.round = m.round)
     order by m.round
  loop
    insert into ft_round_closed (sport, season, round) values (r.sport, r.season, r.round);
    -- weekly spend: bank anything above the amount, and everyone starts the next round on the amount again
    update ft_members mb set banked  = mb.banked + greatest(0, mb.balance - c.starting_balance),
                             balance = c.starting_balance
      from ft_comps c
     where c.id = mb.comp_id and c.sport = r.sport and c.season = r.season and c.start_round <= r.round
       and coalesce(c.rules->>'bankroll', 'once') = 'spend';
    -- end-of-round snapshot, for leaderboard movement (k = banked, weekly spend)
    update ft_members mb set history = mb.history || jsonb_build_object(r.round::text, jsonb_build_object('b', mb.balance, 'f', mb.funded, 'k', mb.banked))
      from ft_comps c
     where c.id = mb.comp_id and c.sport = r.sport and c.season = r.season and c.start_round <= r.round;
    -- achievements for the round (and the season, after a Grand Final)
    begin
      perform ft_ach_round(r.sport, r.season, r.round);
      if r.gf then perform ft_ach_season(r.sport, r.season); end if;
    exception when others then raise warning 'achievements (round %): %', r.round, sqlerrm;
    end;
    -- weekly comps: next round's allowance lands now, if there is a next round
    if exists (select 1 from ft_matches x where x.sport = r.sport and x.season = r.season and x.round = r.round + 1) then
      update ft_members mb set balance = mb.balance + c.starting_balance,
                               funded  = mb.funded  + c.starting_balance,
                               funded_round = r.round + 1
        from ft_comps c
       where c.id = mb.comp_id and c.sport = r.sport and c.season = r.season
         and coalesce(c.rules->>'bankroll', 'once') = 'weekly'
         and mb.funded_round < r.round + 1;
      -- weekly spend: the new round's amount counts as given (for the stake / profit shares in achievements)
      update ft_members mb set funded = mb.funded + c.starting_balance, funded_round = r.round + 1
        from ft_comps c
       where c.id = mb.comp_id and c.sport = r.sport and c.season = r.season
         and coalesce(c.rules->>'bankroll', 'once') = 'spend'
         and mb.funded_round < r.round + 1;
    end if;
    -- the round's ladder goes public now it's been played
    insert into ft_ladders (sport, season, round, rows, updated_at)
    select sport, season, round, rows, now() from ft_replay_ladders
     where sport = r.sport and season = r.season and round = r.round
    on conflict (sport, season, round) do update set rows = excluded.rows, updated_at = now();
    cnt := cnt + 1;
  end loop;
  return cnt;
end $$;


-- ── achievements: amounts as multiples, one profit formula (008's versions otherwise) ──
create or replace function ft_ach_placed(b ft_bets) returns void
language plpgsql set search_path = public as $$
declare r record; v_first timestamptz; v_hour int; v_owner uuid; v_start numeric;
begin
  select starting_balance into v_start from ft_comps where id = b.comp_id;
  for r in select * from ft_rules() loop
    case r.rule->>'type'
    when 'bets_placed' then
      if (select count(*) from ft_bets where user_id = b.user_id) >= (r.rule->>'count')::int then perform ft_award(b.user_id, r.key); end if;
    when 'placed_near_bounce' then
      select min(m.commence_time) into v_first from jsonb_array_elements(b.legs) l join ft_matches m on m.id = l->>'match_id';
      if v_first > b.placed_at and v_first - b.placed_at <= make_interval(secs => (r.rule->>'secs')::int) then perform ft_award(b.user_id, r.key); end if;
    when 'placed_between_hours' then
      v_hour := extract(hour from b.placed_at at time zone 'Australia/Melbourne');
      if v_hour >= (r.rule->>'from')::int and v_hour < (r.rule->>'to')::int then perform ft_award(b.user_id, r.key); end if;
    when 'all_in' then
      if b.all_in and b.stake >= ft_rule_amt(r.rule, 'min', v_start) then perform ft_award(b.user_id, r.key); end if;
    when 'first_on_round' then
      if not exists (select 1 from ft_bets x where x.comp_id = b.comp_id and x.round = b.round and x.id <> b.id and x.placed_at <= b.placed_at) then
        perform ft_award(b.user_id, r.key);
      end if;
    when 'tailed_count' then
      if b.tail_of is not null then
        select user_id into v_owner from ft_bets where id = b.tail_of;
        if (select count(*) from ft_bets x where x.tail_of in (select id from ft_bets where user_id = v_owner)) >= (r.rule->>'count')::int then
          perform ft_award(v_owner, r.key);
        end if;
      end if;
    else null;
    end case;
  end loop;
end $$;


create or replace function ft_ach_settled(b ft_bets) returns void
language plpgsql set search_path = public as $$
declare
  r record; c ft_comps; l jsonb; m ft_matches;
  n int; n_won int; n_lost int; v_side text; v_mine text; v_cnt int; v_ok boolean; v_last text[];
begin
  select * into c from ft_comps where id = b.comp_id;
  n := jsonb_array_length(b.legs);
  select count(*) filter (where x->>'result' = 'won'), count(*) filter (where x->>'result' = 'lost')
    into n_won, n_lost from jsonb_array_elements(b.legs) x;

  for r in select * from ft_rules() loop
    v_ok := false;
    case r.rule->>'type'
    when 'first_win' then v_ok := b.status = 'won';
    when 'bet_return_gte' then v_ok := b.status = 'won' and b.payout >= ft_rule_amt(r.rule, 'amount', c.starting_balance);
    when 'single_won_price_gte' then v_ok := b.status = 'won' and b.kind = 'single' and b.price >= (r.rule->>'price')::numeric;
    when 'multi_won_legs_gte' then v_ok := b.status = 'won' and b.kind <> 'single' and n >= (r.rule->>'legs')::int;
    when 'multi_won_full_round' then
      v_ok := b.status = 'won' and b.kind = 'multi'
          and (select count(distinct x->>'round') from jsonb_array_elements(b.legs) x) = 1
          and n = (select count(*) from ft_matches where sport = c.sport and season = c.season and round = (b.legs->0->>'round')::int);
    when 'lost_on_last_leg' then
      v_ok := b.status = 'lost' and b.kind <> 'single' and n >= (r.rule->>'min_legs')::int and n_lost = 1 and n_won = n - 1;
    when 'won_market' then
      v_ok := b.status = 'won' and exists (select 1 from jsonb_array_elements(b.legs) x
                where x->>'market' in (select jsonb_array_elements_text(r.rule->'markets')));
    when 'lost_short_price' then
      v_ok := b.status = 'lost' and exists (select 1 from jsonb_array_elements(b.legs) x
                where x->>'result' = 'lost' and (x->>'price')::numeric <= (r.rule->>'price')::numeric);
    when 'wins_short_price_count' then
      v_ok := b.status = 'won' and b.price < (r.rule->>'price')::numeric
          and (select count(*) from ft_bets where user_id = b.user_id and status = 'won' and price < (r.rule->>'price')::numeric) >= (r.rule->>'count')::int;
    when 'all_in_lost' then v_ok := b.status = 'lost' and b.all_in and b.stake >= ft_rule_amt(r.rule, 'min', c.starting_balance);
    when 'h2h_flip_late' then
      v_ok := b.status = 'won' and exists (select 1 from jsonb_array_elements(b.legs) x
                where x->>'market' = 'h2h' and x->>'result' = 'won' and ft_h2h_turned_late(x, (r.rule->>'secs')::int));
    when 'void_draw' then
      v_ok := exists (select 1 from jsonb_array_elements(b.legs) x join ft_matches mm on mm.id = x->>'match_id'
                where x->>'market' = 'h2h' and x->>'result' = 'void' and mm.home_score = mm.away_score);
    when 'tail_won' then v_ok := b.tail_of is not null and b.status = 'won';
    when 'tail_lost' then v_ok := b.tail_of is not null and b.status = 'lost';
    when 'streak_won', 'streak_lost' then
      if b.status in ('won','lost') then
        select array_agg(status) into v_last from (
          select status from ft_bets where user_id = b.user_id and status in ('won','lost')
           order by settled_at desc, placed_at desc limit (r.rule->>'count')::int) s;
        v_ok := cardinality(v_last) = (r.rule->>'count')::int
            and v_last <@ array[case when r.rule->>'type' = 'streak_won' then 'won' else 'lost' end];
      end if;
    when 'won_line_margin_lt' then
      if b.status = 'won' then
        for l in select * from jsonb_array_elements(b.legs) loop
          continue when l->>'market' not in ('spreads','alternate_spreads') or l->>'result' <> 'won';
          select * into m from ft_matches where id = l->>'match_id';
          v_side := ft_leg_side(l, m);
          if v_side is not null and ft_side_margin(m, v_side) + (l->>'point')::numeric < (r.rule->>'points')::numeric then v_ok := true; end if;
        end loop;
      end if;
    when 'cash_out_profit' then v_ok := b.status = 'cashed_out' and b.payout > b.stake;
    when 'cash_out_would_win' then
      v_ok := b.status = 'cashed_out' and n_lost = 0 and n_won > 0
          and not exists (select 1 from jsonb_array_elements(b.legs) x where not (x ? 'result'));
    when 'gf_win' then
      v_ok := b.status = 'won' and exists (select 1 from jsonb_array_elements(b.legs) x join ft_matches mm on mm.id = x->>'match_id'
                where mm.stage = 'grand_final');
    -- ── your team ──
    when 'team_underdog_win' then
      -- head to head legs on your team, as the underdog, that won — counted across the season
      select count(distinct x->>'match_id') into v_cnt
        from ft_bets bb, jsonb_array_elements(bb.legs) x, ft_matches mm
       where bb.user_id = b.user_id and mm.id = x->>'match_id' and mm.sport = c.sport and mm.season = c.season
         and x->>'market' = 'h2h' and x->>'result' = 'won'
         and ft_team_abbr(mm.sport, x->>'name') = ft_user_team(b.user_id, mm.sport, mm.season, mm.round)
         and ft_leg_underdog(x);
      v_ok := v_cnt >= (r.rule->>'count')::int;
    when 'team_betrayal' then
      if b.status = 'won' then
        for l in select * from jsonb_array_elements(b.legs) loop
          continue when l->>'market' <> 'h2h' or l->>'result' <> 'won';
          select * into m from ft_matches where id = l->>'match_id';
          continue when coalesce((r.rule->>'finals')::boolean, false) and m.stage = 'regular';
          v_mine := ft_user_team(b.user_id, m.sport, m.season, m.round);
          if v_mine is not null and v_mine in (ft_team_abbr(m.sport, m.home_team), ft_team_abbr(m.sport, m.away_team))
             and ft_team_abbr(m.sport, l->>'name') <> v_mine then v_ok := true; end if;
        end loop;
      end if;
    when 'team_close_loss' then
      for l in select * from jsonb_array_elements(b.legs) loop
        continue when l->>'market' <> 'h2h' or l->>'result' <> 'lost';
        select * into m from ft_matches where id = l->>'match_id';
        v_side := ft_leg_side(l, m);
        if v_side is not null and ft_team_abbr(m.sport, l->>'name') = ft_user_team(b.user_id, m.sport, m.season, m.round)
           and -ft_side_margin(m, v_side) < (r.rule->>m.sport)::int then v_ok := true; end if;
      end loop;
    else null;
    end case;
    if v_ok then perform ft_award(b.user_id, r.key); end if;
  end loop;
end $$;


create or replace function ft_ach_season(p_sport text, p_season int) returns void
language plpgsql set search_path = public as $$
declare
  c ft_comps; r record; p record; t record; v_n int; v_ok boolean; v_meta jsonb;
  v_gf ft_matches; v_winner text; v_first_final int; v_ladder jsonb; v_top text; v_bottom text; v_pos int; v_last int;
  v_rounds int[]; v_played int[]; v_fl jsonb;
begin
  -- ── per comp: where everyone finished ──
  for c in select * from ft_comps where sport = p_sport and season = p_season loop
    v_meta := jsonb_build_object('comp_name', c.name, 'season', p_season);
    create temp table if not exists _ach_s (user_id uuid, balance numeric, funded numeric, profit numeric, rk int, staked numeric, bets int, history jsonb) on commit drop;
    truncate _ach_s;
    insert into _ach_s
    select mb.user_id, mb.balance, mb.funded, ft_member_profit(mb.balance, mb.funded, mb.banked, c.starting_balance, coalesce(c.rules->>'bankroll', 'once')), rank() over (order by ft_member_profit(mb.balance, mb.funded, mb.banked, c.starting_balance, coalesce(c.rules->>'bankroll', 'once')) desc),
           coalesce((select sum(stake) from ft_bets where comp_id = c.id and user_id = mb.user_id), 0),
           (select count(*) from ft_bets where comp_id = c.id and user_id = mb.user_id), mb.history
      from ft_members mb where mb.comp_id = c.id;
    select count(*) into v_n from _ach_s;
    select array_agg(distinct round order by round) into v_rounds from ft_matches where sport = p_sport and season = p_season and round >= c.start_round;

    for r in select * from ft_rules() loop
      case r.rule->>'type'
      when 'season_rank' then
        if v_n >= 2 then perform ft_award(z.user_id, r.key, c.id::text, c.id, v_meta) from _ach_s z where z.rk <= (r.rule->>'max_rank')::int; end if;
      when 'season_last' then
        if v_n >= (r.rule->>'min_members')::int then
          perform ft_award(z.user_id, r.key, c.id::text, c.id, v_meta) from _ach_s z where z.rk = (select max(rk) from _ach_s) and z.rk > 1;
        end if;
      when 'season_balance_lte' then
        perform ft_award(z.user_id, r.key, c.id::text, c.id, v_meta) from _ach_s z where z.balance <= ft_rule_amt(r.rule, 'amount', c.starting_balance)
           and coalesce(c.rules->>'bankroll', 'once') <> 'spend';            -- balances reset in weekly spend
      when 'season_profit_between' then
        perform ft_award(z.user_id, r.key, c.id::text, c.id, v_meta) from _ach_s z
         where z.profit > ft_rule_amt(r.rule, 'min', c.starting_balance) and z.profit < ft_rule_amt(r.rule, 'max', c.starting_balance);
      when 'season_no_bets' then
        -- there for every round (a snapshot for each), never bet
        perform ft_award(z.user_id, r.key, c.id::text, c.id, v_meta) from _ach_s z
         where z.bets = 0 and (select count(*) from unnest(v_rounds) rr where z.history ? rr::text) = cardinality(v_rounds);
      when 'season_spend_profit' then
        perform ft_award(z.user_id, r.key, c.id::text, c.id, v_meta) from _ach_s z
         where z.funded > 0 and z.bets > 0
           and (r.rule->>'stake_min'  is null or z.staked / z.funded >= (r.rule->>'stake_min')::numeric)
           and (r.rule->>'stake_max'  is null or z.staked / z.funded <  (r.rule->>'stake_max')::numeric)
           and (r.rule->>'profit_min' is null or z.profit / z.funded >= (r.rule->>'profit_min')::numeric)
           and (r.rule->>'profit_max' is null or z.profit / z.funded <= (r.rule->>'profit_max')::numeric);
      when 'season_every_round' then
        -- a bet settling in every round from when they joined
        for p in select * from _ach_s where bets > 0 loop
          if not exists (select 1 from unnest(v_rounds) rr
                          where rr >= coalesce((select min(k::int) from jsonb_object_keys(p.history) k), c.start_round)
                            and not exists (select 1 from ft_bets where comp_id = c.id and user_id = p.user_id and round = rr)) then
            perform ft_award(p.user_id, r.key, c.id::text, c.id, v_meta);
          end if;
        end loop;
      else null;
      end case;
    end loop;
  end loop;

  -- ── per person: their team's season ──
  select * into v_gf from ft_matches where sport = p_sport and season = p_season and stage = 'grand_final' order by commence_time desc limit 1;
  if v_gf.id is not null and v_gf.home_score is not null and v_gf.home_score <> v_gf.away_score then
    v_winner := ft_team_abbr(p_sport, case when v_gf.home_score > v_gf.away_score then v_gf.home_team else v_gf.away_team end);
  end if;
  select min(round) into v_first_final from ft_matches where sport = p_sport and season = p_season and stage <> 'regular';
  -- the ladder after the home and away season
  select rows into v_ladder from ft_ladders where sport = p_sport and season = p_season
     and round < coalesce(v_first_final, 1000) order by round desc limit 1;
  select ft_team_abbr(p_sport, x->>'team') into v_top    from jsonb_array_elements(v_ladder) x order by (x->>'pos')::int asc  limit 1;
  select ft_team_abbr(p_sport, x->>'team') into v_bottom from jsonb_array_elements(v_ladder) x order by (x->>'pos')::int desc limit 1;
  select max((x->>'pos')::int) into v_last from jsonb_array_elements(v_ladder) x;
  select doc->'flairs' into v_fl from ft_docs where name = 'achievements';

  for t in select user_id, teams->p_sport->>'team' team, coalesce((teams->p_sport->>'since_round')::int, 1) since
             from ft_profiles where (teams->p_sport->>'season')::int = p_season loop
    select (x->>'pos')::int into v_pos from jsonb_array_elements(v_ladder) x where ft_team_abbr(p_sport, x->>'team') = t.team limit 1;
    -- rounds their team played since they picked them, and the rounds they backed them head to head
    select array_agg(distinct round) into v_played from ft_matches
     where sport = p_sport and season = p_season and round >= t.since and status = 'concluded'
       and t.team in (ft_team_abbr(p_sport, home_team), ft_team_abbr(p_sport, away_team));
    for r in select * from ft_rules() loop
      v_ok := false;
      case r.rule->>'type'
      when 'team_every_round' then
        v_ok := cardinality(v_played) > 0 and not exists (
          select 1 from unnest(v_played) rr where not exists (
            select 1 from ft_bets bb, jsonb_array_elements(bb.legs) x, ft_matches mm
             where bb.user_id = t.user_id and mm.id = x->>'match_id' and mm.sport = p_sport and mm.season = p_season and mm.round = rr
               and x->>'market' = 'h2h' and ft_team_abbr(p_sport, x->>'name') = t.team));
        if v_ok and r.rule ? 'team_top' then v_ok := v_pos is not null and v_pos <= (r.rule->>'team_top')::int; end if;
        if v_ok and coalesce((r.rule->>'team_last')::boolean, false) then v_ok := v_pos is not null and v_pos = v_last; end if;
      when 'team_only_favourite' then
        select count(*), bool_and(not ft_leg_underdog(x)) into v_n, v_ok
          from ft_bets bb, jsonb_array_elements(bb.legs) x, ft_matches mm
         where bb.user_id = t.user_id and mm.id = x->>'match_id' and mm.sport = p_sport and mm.season = p_season and mm.round >= t.since
           and x->>'market' = 'h2h' and ft_team_abbr(p_sport, x->>'name') = t.team;
        v_ok := coalesce(v_ok, false) and v_n >= (r.rule->>'min')::int;
      when 'gf_backed_team_won' then
        v_ok := v_winner = t.team and exists (
          select 1 from ft_bets bb, jsonb_array_elements(bb.legs) x
           where bb.user_id = t.user_id and x->>'match_id' = v_gf.id and x->>'market' = 'h2h' and ft_team_abbr(p_sport, x->>'name') = t.team);
      else null;
      end case;
      if v_ok then perform ft_award(t.user_id, r.key, p_season::text, null, jsonb_build_object('season', p_season, 'team', t.team)); end if;
    end loop;

    -- team flairs (picked before finals started, so no bandwagon premierships)
    if v_winner = t.team and t.since < coalesce(v_first_final, 1000) and v_fl ? 'premiers' then
      perform ft_award(t.user_id, 'flair_premiers', p_sport||':'||t.team||':'||p_season, null, jsonb_build_object('sport', p_sport, 'team', t.team, 'season', p_season));
    end if;
    if v_top = t.team and v_fl ? 'minor_premiers' then
      perform ft_award(t.user_id, 'flair_minor_premiers', p_sport||':'||t.team||':'||p_season, null, jsonb_build_object('sport', p_sport, 'team', t.team, 'season', p_season));
    end if;
    if v_bottom = t.team and v_fl ? 'spooners' then
      perform ft_award(t.user_id, 'flair_spooners', p_sport||':'||t.team||':'||p_season, null, jsonb_build_object('sport', p_sport, 'team', t.team, 'season', p_season));
    end if;
  end loop;
end $$;


-- ── round wrap notification: the same profit (009's version otherwise) ──
create or replace function ft_push_digest() returns trigger
language plpgsql set search_path = public as $$
declare c ft_comps; v_top text; v_best text; p record; v_n int;
begin
  begin
    for c in select * from ft_comps where sport = new.sport and season = new.season and start_round <= new.round loop
      select count(*) into v_n from ft_members where comp_id = c.id;
      continue when v_n < 2;
      select string_agg(format('%s %s %s', rk, username, case when profit >= 0 then '+$' else '−$' end || to_char(abs(profit), 'FM999,990')), ' · ' order by rk)
        into v_top
        from (select username, ft_member_profit(balance, funded, banked, c.starting_balance, coalesce(c.rules->>'bankroll', 'once')) profit, rank() over (order by ft_member_profit(balance, funded, banked, c.starting_balance, coalesce(c.rules->>'bankroll', 'once')) desc) rk from ft_members where comp_id = c.id) s where rk <= 3;
      select format('Biggest win: %s +$%s', m.username, to_char(b.payout - b.stake, 'FM999,990')) into v_best
        from ft_bets b join ft_members m on m.comp_id = b.comp_id and m.user_id = b.user_id
       where b.comp_id = c.id and b.round = new.round and b.status = 'won' order by b.payout - b.stake desc limit 1;
      for p in select user_id, rk, profit from (
                 select user_id, ft_member_profit(balance, funded, banked, c.starting_balance, coalesce(c.rules->>'bankroll', 'once')) profit, rank() over (order by ft_member_profit(balance, funded, banked, c.starting_balance, coalesce(c.rules->>'bankroll', 'once')) desc) rk from ft_members where comp_id = c.id) s
               where exists (select 1 from ft_bets b where b.comp_id = c.id and b.user_id = s.user_id and b.round >= new.round - 1)
                 and ft_push_wants(s.user_id, 'digest', c.id::text) loop
        insert into ft_push_queue (user_id, title, body, url, tag)
        values (p.user_id, format('📊 Round %s wrap · %s', new.round, c.name),
                v_top || format(E'\nYou’re #%s of %s', p.rk, v_n) || coalesce(E'\n' || v_best, ''),
                './?comp=' || c.id || '&overview=1', 'digest-' || c.id);
      end loop;
    end loop;
  exception when others then raise warning 'push (digest): %', sqlerrm;
  end;
  return null;
end $$;


do $$
declare f text;
begin
  foreach f in array array['ft_close_rounds()', 'ft_ach_placed(ft_bets)', 'ft_ach_settled(ft_bets)', 'ft_ach_season(text,int)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
