-- ════════════════════════════════════════════════════════════════════════════
-- 005 — replay clock, bet settlement and end-of-round jobs
-- One scheduled job (pg_cron, every 5 seconds) runs ft_tick(), which:
--   1. ft_replay_tick()   plays each started replay match forward to "now": score, quarter/half
--                         and clock, scoring events so far, player stats so far → ft_matches.live.
--                         It only writes when something changed (every write is pushed to every open
--                         page): scores/events/quarter at once, player stats at most every 30s, and
--                         never for the clock alone — the page runs the clock itself from clockSecs/at.
--   2. ft_settle_bets()   settles bets as soon as they're decided (a lost leg sinks a multi straight
--                         away), pays winners, and saves each leg's result for the ✓/✕ marks
--   3. ft_close_rounds()  once every match in a round is over: end-of-round balances into
--                         ft_members.history (leaderboard movement) and the round's ladder published
-- Steps 2 and 3 work the same for real fixtures later; only step 1 is replay-specific.
-- The replay data itself comes from replay/replay_seed.sql (built by replay/build-replay.ps1).
-- Needs pg_cron (Database → Extensions). Run after 004. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

-- ── replay source data (server-only: no read policies) ──────────────────────
create table if not exists ft_replay_src (
  match_id  text primary key references ft_matches(id) on delete cascade,
  plen      jsonb not null,          -- real seconds in each quarter/half, e.g. [1950, 1880, 1920, 1990]
  brk       jsonb not null,          -- real seconds of each break between them, e.g. [360, 1200, 360]
  events    jsonb not null,          -- every score: [{ team, type, q, secs, player }]
  players   jsonb not null           -- final player stats: [{ name, team, d, k, … }]
);
create table if not exists ft_replay_ladders (     -- the official ladder after each replayed round, held back until it's played
  sport text not null, season int not null, round int not null, rows jsonb not null,
  primary key (sport, season, round)
);
create table if not exists ft_round_closed (       -- rounds whose end-of-round work is done
  sport text not null, season int not null, round int not null, closed_at timestamptz not null default now(),
  primary key (sport, season, round)
);
alter table ft_replay_src     enable row level security;
alter table ft_replay_ladders enable row level security;
alter table ft_round_closed   enable row level security;


-- points per scoring event
create or replace function ft_event_pts(sport text, type text) returns int
language sql immutable as $$
  select case
    when sport = 'nrl' then case type when 'try' then 4 when 'conversion' then 2 when 'penalty' then 2
                                      when 'field_goal' then 1 when 'field_goal_2' then 2 else 0 end
    else case type when 'goal' then 6 when 'behind' then 1 else 0 end end;
$$;


-- ════════ 1. replay clock ════════
create or replace function ft_replay_tick() returns int
language plpgsql set search_path = public as $$
declare
  r record;
  n int; q int; clk float8; done boolean; e float8; per float8; brk float8; played float8; total float8; f float8;
  evs jsonb; hcum jsonb; acum jsonb; hs int; as_ int; hg int; hb int; ag int; ab int; k int; pl jsonb; cnt int := 0;
  run boolean; st text; nl jsonb;
begin
  for r in
    select m.id, m.sport, m.commence_time, m.status, m.home_score, m.away_score, m.live, m.updated_at,
           s.plen, s.brk, s.events, s.players
      from ft_matches m join ft_replay_src s on s.match_id = m.id
     where m.status <> 'concluded' and m.commence_time <= now()
  loop
    -- where the game is up to: walk the periods and breaks from the bounce
    n := jsonb_array_length(r.plen);
    e := extract(epoch from now() - r.commence_time);
    total := (select sum(x::float8) from jsonb_array_elements_text(r.plen) x);
    q := 1; clk := 0; done := false; played := 0; run := false;
    loop
      per := (r.plen->>(q-1))::float8;
      if e < per then clk := e; played := played + e; run := true; exit; end if;
      e := e - per; played := played + per;
      if q = n then done := true; clk := per; exit; end if;
      brk := (r.brk->>(q-1))::float8;
      if e < brk then clk := per; exit; end if;           -- at the break: clock held at the end of the period
      e := e - brk; q := q + 1;
    end loop;
    f := least(1, played/total);

    -- scores so far, in order
    select coalesce(jsonb_agg(x order by (x->>'q')::int, (x->>'secs')::float8), '[]') into evs
      from jsonb_array_elements(r.events) x
     where done or (x->>'q')::int < q or ((x->>'q')::int = q and (x->>'secs')::float8 <= clk);

    -- cumulative score at the end of each period played (the current one so far)
    hcum := '[]'; acum := '[]'; hs := 0; as_ := 0;
    for k in 1 .. (case when done then n else q end) loop
      if r.sport = 'afl' then
        select count(*) filter (where x->>'team' = 'home' and x->>'type' = 'goal'),
               count(*) filter (where x->>'team' = 'home' and x->>'type' = 'behind'),
               count(*) filter (where x->>'team' = 'away' and x->>'type' = 'goal'),
               count(*) filter (where x->>'team' = 'away' and x->>'type' = 'behind')
          into hg, hb, ag, ab
          from jsonb_array_elements(evs) x where (x->>'q')::int <= k;
        hcum := hcum || jsonb_build_array(jsonb_build_array(hg, hb));
        acum := acum || jsonb_build_array(jsonb_build_array(ag, ab));
        hs := hg*6 + hb; as_ := ag*6 + ab;
      else
        select coalesce(sum(ft_event_pts('nrl', x->>'type')) filter (where x->>'team' = 'home'), 0),
               coalesce(sum(ft_event_pts('nrl', x->>'type')) filter (where x->>'team' = 'away'), 0)
          into hs, as_
          from jsonb_array_elements(evs) x where (x->>'q')::int <= k;
        hcum := hcum || to_jsonb(hs);
        acum := acum || to_jsonb(as_);
      end if;
    end loop;

    -- player stats so far: goals / behinds / tries counted from the scores exactly,
    -- everything else is the final figure scaled by how much of the game has been played
    select coalesce(jsonb_agg((
      select jsonb_object_agg(kv.key,
        case
          when kv.key in ('name','team') then kv.value
          when kv.key in ('g','b','tr') then to_jsonb((
            select count(*) from jsonb_array_elements(evs) x
             where x->>'player' = p->>'name' and x->>'team' = p->>'team'
               and x->>'type' = case kv.key when 'g' then 'goal' when 'b' then 'behind' else 'try' end))
          when done then kv.value
          else to_jsonb(floor((kv.value #>> '{}')::numeric * f)::int)
        end)
      from jsonb_each(p) kv)), '[]')
      into pl
      from jsonb_array_elements(r.players) p;

    -- running: the clock is going (false at the breaks and after the siren); at: when clockSecs was read
    st := case when done then 'concluded' else 'live' end;
    nl := jsonb_build_object('q', q, 'clockSecs', round(clk), 'running', run, 'at', round(extract(epoch from now())::numeric, 1),
                             'home', hcum, 'away', acum, 'events', evs, 'players', pl);
    if st is distinct from r.status or hs is distinct from r.home_score or as_ is distinct from r.away_score
       or (nl - 'clockSecs' - 'at' - 'players') is distinct from (coalesce(r.live, '{}') - 'clockSecs' - 'at' - 'players')
       or (pl is distinct from r.live->'players' and r.updated_at < now() - interval '30 seconds')
    then
      update ft_matches set status = st, home_score = hs, away_score = as_, live = nl, updated_at = now() where id = r.id;
      cnt := cnt + 1;
    end if;
  end loop;
  return cnt;
end $$;


-- ════════ 2. settlement ════════
-- Pending bets settle the moment they're decided. Bets that ended early (a lost leg, or
-- cashed out) keep having their other legs' results filled in, so every leg gets a mark.
create or replace function ft_settle_bets() returns int
language plpgsql set search_path = public as $$
declare
  b ft_bets; l jsonb; m ft_matches; e_st text; e_p float8;
  v_legs jsonb; any_lost boolean; all_done boolean; all_void boolean; mult float8; pay numeric; cnt int := 0;
begin
  for b in
    select * from ft_bets x
     where x.status = 'pending'
        or (x.status in ('lost','cashed_out') and x.settled_at > now() - interval '21 days'
            and exists (select 1 from jsonb_array_elements(x.legs) g where not (g ? 'result')))
     for update skip locked
  loop
    v_legs := '[]'; any_lost := false; all_done := true; all_void := true; mult := 1;
    for l in select * from jsonb_array_elements(b.legs) loop
      select * into m from ft_matches where id = l->>'match_id';
      select st, p into e_st, e_p from ft_leg_eval(l - 'result', m);
      if e_st in ('won','lost','void') then l := l || jsonb_build_object('result', e_st); else all_done := false; end if;
      if e_st = 'lost' then any_lost := true; end if;
      if e_st <> 'void' then all_void := false; end if;
      if e_st = 'won' then mult := mult * (l->>'price')::float8; end if;
      v_legs := v_legs || l;
    end loop;

    if b.status <> 'pending' then                         -- already finished: just record leg results
      if v_legs is distinct from b.legs then update ft_bets set legs = v_legs where id = b.id; end if;
      continue;
    end if;

    if any_lost then
      update ft_bets set status = 'lost', payout = 0, legs = v_legs, settled_at = now() where id = b.id;
      cnt := cnt + 1;
    elsif all_done then
      -- void legs drop out of the odds; an all-void bet is refunded
      pay := case when all_void then b.stake else round((b.stake * mult)::numeric, 2) end;
      update ft_bets set status = case when all_void then 'void' else 'won' end, payout = pay, legs = v_legs, settled_at = now()
       where id = b.id;
      update ft_members set balance = balance + pay where comp_id = b.comp_id and user_id = b.user_id;
      cnt := cnt + 1;
    elsif v_legs is distinct from b.legs then
      update ft_bets set legs = v_legs where id = b.id;   -- legs decided so far, for the ✓ marks
    end if;
  end loop;
  return cnt;
end $$;


-- ════════ 3. end of round ════════
create or replace function ft_close_rounds() returns int
language plpgsql set search_path = public as $$
declare r record; cnt int := 0;
begin
  for r in
    select m.sport, m.season, m.round from ft_matches m
     group by m.sport, m.season, m.round
    having bool_and(m.status = 'concluded')
       and not exists (select 1 from ft_round_closed c where c.sport = m.sport and c.season = m.season and c.round = m.round)
  loop
    insert into ft_round_closed (sport, season, round) values (r.sport, r.season, r.round);
    -- end-of-round balances, for leaderboard movement
    update ft_members mb set history = mb.history || jsonb_build_object(r.round::text, mb.balance)
      from ft_comps c
     where c.id = mb.comp_id and c.sport = r.sport and c.season = r.season and c.start_round <= r.round;
    -- the round's ladder goes public now it's been played
    insert into ft_ladders (sport, season, round, rows, updated_at)
    select sport, season, round, rows, now() from ft_replay_ladders
     where sport = r.sport and season = r.season and round = r.round
    on conflict (sport, season, round) do update set rows = excluded.rows, updated_at = now();
    cnt := cnt + 1;
  end loop;
  return cnt;
end $$;


-- ════════ the job ════════
create or replace function ft_tick() returns void
language plpgsql set search_path = public as $$
begin
  perform ft_replay_tick();
  perform ft_settle_bets();
  perform ft_close_rounds();
end $$;

-- server-side only: not callable from the page
revoke all on function ft_replay_tick()  from public, anon, authenticated;
revoke all on function ft_settle_bets()  from public, anon, authenticated;
revoke all on function ft_close_rounds() from public, anon, authenticated;
revoke all on function ft_tick()         from public, anon, authenticated;

-- run it every 5 seconds (pg_cron won't start a run while the last one is still going)
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname in ('ft-tick', 'ft-cron-cleanup');
select cron.schedule('ft-tick', '5 seconds', 'select public.ft_tick()');
-- that's ~17,000 run-log rows a day: keep one day of them
select cron.schedule('ft-cron-cleanup', '17 3 * * *', $$delete from cron.job_run_details where end_time < now() - interval '1 day'$$);
