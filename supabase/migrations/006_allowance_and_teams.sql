-- ════════════════════════════════════════════════════════════════════════════
-- 006 — weekly allowance, profit ranking, and the team you barrack for
--
-- Bankroll (host's choice when creating a comp, rules.bankroll):
--   'weekly' (default)  everyone gets the comp's amount at the start of every round, on top of
--                       whatever they have left. Joining mid-season gets you the current round's
--                       allowance only — no back-pay — so late joiners can't cannonball in.
--   'once'              the old way: one starting balance for the whole season.
-- The leaderboard ranks on PROFIT = balance − funded (everything you've been given), so a late
-- joiner starts level on $0 profit without a head start in cash.
--   ft_members.funded        total allowance received (the starting balance counts)
--   ft_members.funded_round  the last round you were paid for (stops double payments)
--   ft_members.history       end-of-round snapshots, now { "5": { "b": balance, "f": funded } }
--                            (older plain-number entries are read as one-off balances)
--
-- Barracking for (ft_profiles, one row per person, shared across comps):
--   teams = { "afl": { "team":"HAW", "season":2027, "since_round":3, "changes":0 }, "nrl": {…} }
--   Pick any time while unset. Once set: one change per season, then locked until next season.
--   since_round is when the current pick started, for season-long team achievements later.
--
-- Run after 005. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

-- ── allowance bookkeeping ───────────────────────────────────────────────────
alter table ft_members add column if not exists funded       numeric(12,2);
alter table ft_members add column if not exists funded_round int;
update ft_members m set funded = c.starting_balance, funded_round = c.start_round
  from ft_comps c where c.id = m.comp_id and m.funded is null;
alter table ft_members alter column funded set not null;
alter table ft_members alter column funded_round set not null;


-- ── host a comp: adds the bankroll rule (weekly unless 'once' is asked for) ──
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
    'bankroll',  case when p_rules->>'bankroll' = 'once' then 'once' else 'weekly' end);
  v_round := ft_current_round(p_sport, p_season);

  insert into ft_comps (name, code, sport, season, starting_balance, start_round, rules)
  values (trim(p_name), ft_new_code_value(), p_sport, p_season, p_starting_balance, v_round, v_rules)
  returning * into v_comp;

  insert into ft_members (comp_id, user_id, username, is_host, balance, funded, funded_round)
  values (v_comp.id, auth.uid(), trim(p_username), true, p_starting_balance, p_starting_balance, v_round);

  return v_comp;
end $$;


-- ── join: you get this round's allowance (or the one-off balance) ───────────
create or replace function ft_join_comp(p_comp uuid, p_username text)
returns ft_members
language plpgsql security definer set search_path = public as $$
declare
  v_row ft_members;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into v_row from ft_members where comp_id = p_comp and user_id = auth.uid();
  if found then return v_row; end if;
  if exists (select 1 from ft_members where comp_id = p_comp and lower(username) = lower(trim(p_username))) then
    raise exception 'That username is taken in this comp.';
  end if;
  insert into ft_members (comp_id, user_id, username, balance, funded, funded_round)
  select p_comp, auth.uid(), trim(p_username), c.starting_balance, c.starting_balance,
         greatest(c.start_round, ft_current_round(c.sport, c.season))
    from ft_comps c where c.id = p_comp
  returning * into v_row;
  if v_row is null then raise exception 'Competition not found.'; end if;
  return v_row;
end $$;


-- ── find a comp by code: now says how the bankroll works ────────────────────
drop function if exists ft_find_comp(text);
create function ft_find_comp(p_code text)
returns table (id uuid, name text, sport text, members int, starting_balance numeric, bankroll text, is_member boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.sport,
         (select count(*)::int from ft_members m where m.comp_id = c.id),
         c.starting_balance,
         coalesce(c.rules->>'bankroll', 'once'),
         exists (select 1 from ft_members m where m.comp_id = c.id and m.user_id = auth.uid())
  from ft_comps c
  where c.code = upper(trim(p_code));
$$;


-- ── end of round: snapshot balance + funded, then pay next round's allowance ─
-- (replaces 005's version; the ladder part is unchanged)
create or replace function ft_close_rounds() returns int
language plpgsql set search_path = public as $$
declare r record; cnt int := 0;
begin
  for r in
    select m.sport, m.season, m.round from ft_matches m
     group by m.sport, m.season, m.round
    having bool_and(m.status = 'concluded')
       and not exists (select 1 from ft_round_closed c where c.sport = m.sport and c.season = m.season and c.round = m.round)
     order by m.round
  loop
    insert into ft_round_closed (sport, season, round) values (r.sport, r.season, r.round);
    -- end-of-round snapshot, for leaderboard movement
    update ft_members mb set history = mb.history || jsonb_build_object(r.round::text, jsonb_build_object('b', mb.balance, 'f', mb.funded))
      from ft_comps c
     where c.id = mb.comp_id and c.sport = r.sport and c.season = r.season and c.start_round <= r.round;
    -- weekly comps: next round's allowance lands now, if there is a next round
    if exists (select 1 from ft_matches x where x.sport = r.sport and x.season = r.season and x.round = r.round + 1) then
      update ft_members mb set balance = mb.balance + c.starting_balance,
                               funded  = mb.funded  + c.starting_balance,
                               funded_round = r.round + 1
        from ft_comps c
       where c.id = mb.comp_id and c.sport = r.sport and c.season = r.season
         and coalesce(c.rules->>'bankroll', 'once') = 'weekly'
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
revoke all on function ft_close_rounds() from public, anon, authenticated;


-- ── barracking for ──────────────────────────────────────────────────────────
create table if not exists ft_profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  teams      jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table ft_profiles enable row level security;
-- everyone signed in can see who barracks for whom (badges in chat and the leaderboard)
drop policy if exists ft_profiles_read on ft_profiles;
create policy ft_profiles_read on ft_profiles for select to authenticated using (true);

-- pick (or change) your team for one code. p_team is the club's abbreviation from teams.json.
create or replace function ft_set_team(p_sport text, p_team text, p_season int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_teams jsonb; v_cur jsonb; v_changes int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_sport not in ('afl','nrl') then raise exception 'unknown code'; end if;
  if p_team is null or p_team !~ '^[A-Z]{3}$' then raise exception 'unknown team'; end if;

  insert into ft_profiles (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select teams into v_teams from ft_profiles where user_id = auth.uid() for update;
  v_cur := v_teams -> p_sport;

  if v_cur is not null and v_cur->>'team' = p_team then return v_teams; end if;   -- no change
  -- a new season (or first pick) starts fresh; within a season you get one change after picking
  if v_cur is null or (v_cur->>'season')::int <> p_season then
    v_changes := 0;
  elsif coalesce((v_cur->>'changes')::int, 0) >= 1 then
    raise exception 'You’ve already changed your % team this season. It unlocks again next season.', upper(p_sport);
  else
    v_changes := coalesce((v_cur->>'changes')::int, 0) + 1;
  end if;

  v_teams := v_teams || jsonb_build_object(p_sport, jsonb_build_object(
    'team', p_team, 'season', p_season, 'since_round', ft_current_round(p_sport, p_season), 'changes', v_changes));
  update ft_profiles set teams = v_teams, updated_at = now() where user_id = auth.uid();
  return v_teams;
end $$;
