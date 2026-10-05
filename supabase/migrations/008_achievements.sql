-- ════════════════════════════════════════════════════════════════════════════
-- 008 — achievements and flairs
--
-- Definitions live in the repo: data/achievements.json (names, icons, rarity, hidden, and each
-- rule's numbers) and data/teams.json (to tell which club a bet is on). The database fetches both
-- from the live site about once an hour (pg_net), so editing the JSON and pushing is all it takes.
-- The copies at the bottom of this file are just the starting point.
--
-- Unlocks (ft_unlocks) belong to a person, not a comp. Most are one-offs (scope ''); season results
-- like Champion are per comp (scope = comp id), and team flairs carry code:club:season.
--   flair_supporter  "{team} '{yy}"     picking a team unlocks that season's flair (a change replaces it)
--   flair_streak     "{nick} {streak}Y" same club 3 / 5 / 10 seasons running (flairs.streak.at)
--   flair_premiers / flair_minor_premiers / flair_spooners   at season end
-- ft_profiles.flair is the one you show next to your name ({ ach, scope }); null = your team's.
--
-- When rules are checked:
--   placing a bet (trigger)        Centurion, Buzzer Beater, Night Owl, All In, Early Bird, Tipster
--   a bet settling / cashing out   wins, multis, streaks, team bets, tails, Bottler …
--   a chat message                 Chatterbox
--   a round closing                Round Winner, Top Dog, Bolter, Perfect Round, Comeback Kid …
--   the Grand Final finishing      season results, team season achievements, team flairs
--                                  (ft_matches.stage marks finals: 'final' / 'grand_final')
-- Every check is wrapped so an achievement problem can never block a bet or a settlement.
--
-- Needs pg_net (Database → Extensions). Run after 007. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

create extension if not exists pg_net;

-- ── schema ──────────────────────────────────────────────────────────────────
alter table ft_matches  add column if not exists stage text not null default 'regular';
alter table ft_matches  drop constraint if exists ft_matches_stage_check;
alter table ft_matches  add constraint ft_matches_stage_check check (stage in ('regular','final','grand_final'));
alter table ft_bets     add column if not exists all_in boolean not null default false;   -- staked the whole balance
alter table ft_members  add column if not exists seen_round int;                          -- last round overview you've seen
alter table ft_profiles add column if not exists flair jsonb;                             -- { ach, scope } you show; null = your team
alter table ft_profiles add column if not exists prefs jsonb not null default '{}';       -- notification settings (009)

create table if not exists ft_docs (                 -- data/*.json as last fetched from the site
  name text primary key, doc jsonb not null, fetched_at timestamptz not null default now()
);
create table if not exists ft_doc_requests (         -- pg_net requests in flight
  id bigint primary key, name text not null, made_at timestamptz not null default now()
);
create table if not exists ft_config (key text primary key, value text);
insert into ft_config (key, value) values ('site_url', 'https://haydenmquaill.github.io/JustaLittleTipping/')
on conflict (key) do nothing;

create table if not exists ft_unlocks (
  user_id     uuid not null references auth.users(id) on delete cascade,
  ach         text not null,                       -- achievement key, or flair_*
  scope       text not null default '',
  comp_id     uuid references ft_comps(id) on delete set null,
  meta        jsonb not null default '{}',         -- e.g. { comp_name, season } or { sport, team, season, streak }
  unlocked_at timestamptz not null default now(),
  seen        boolean not null default false,      -- the unlock pop-up has been shown
  primary key (user_id, ach, scope)
);
create index if not exists ft_unlocks_unseen on ft_unlocks (user_id) where not seen;

alter table ft_docs         enable row level security;   -- server only
alter table ft_doc_requests enable row level security;
alter table ft_config       enable row level security;
alter table ft_unlocks      enable row level security;
drop policy if exists ft_unlocks_read on ft_unlocks;
create policy ft_unlocks_read on ft_unlocks for select to authenticated using (true);   -- player views show anyone's

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'ft_unlocks') then
    alter publication supabase_realtime add table ft_unlocks;
  end if;
end $$;

-- the round overview starts from now: existing members have "seen" everything already closed
update ft_members mb set seen_round = coalesce(
    (select max(rc.round) from ft_round_closed rc where rc.sport = c.sport and rc.season = c.season), c.start_round - 1)
  from ft_comps c where c.id = mb.comp_id and mb.seen_round is null;
-- new members start from the round before they joined
create or replace function ft_members_seen_default() returns trigger
language plpgsql as $$
begin
  new.seen_round := coalesce(new.seen_round, new.funded_round - 1);
  return new;
end $$;
drop trigger if exists ft_members_seen_default on ft_members;
create trigger ft_members_seen_default before insert on ft_members for each row execute function ft_members_seen_default();


-- ── the JSON definitions ────────────────────────────────────────────────────
-- fetch data/teams.json and data/achievements.json from the site about once an hour
create or replace function ft_docs_sync() returns void
language plpgsql set search_path = public as $$
declare r record; v_base text; v_last timestamptz;
begin
  -- collect finished requests
  for r in select q.id, q.name, h.status_code, h.content
             from ft_doc_requests q join net._http_response h on h.id = q.id loop
    if r.status_code = 200 then
      begin
        insert into ft_docs (name, doc, fetched_at) values (r.name, r.content::jsonb, now())
        on conflict (name) do update set doc = excluded.doc, fetched_at = now();
      exception when others then
        raise warning 'ft_docs_sync: % is not valid JSON (%)', r.name, sqlerrm;
      end;
    end if;
    delete from ft_doc_requests where id = r.id;
  end loop;
  delete from ft_doc_requests where made_at < now() - interval '10 minutes';      -- never answered

  -- ask again hourly
  select value::timestamptz into v_last from ft_config where key = 'docs_requested_at';
  if v_last is null or v_last < now() - interval '1 hour' then
    select value into v_base from ft_config where key = 'site_url';
    insert into ft_doc_requests (id, name) select net.http_get(v_base || 'data/' || n || '.json'), n from unnest(array['teams','achievements']) n;
    insert into ft_config (key, value) values ('docs_requested_at', now()::text)
    on conflict (key) do update set value = excluded.value;
  end if;
end $$;

-- or load one by hand: select ft_load_doc('achievements', '{…}'::jsonb);
create or replace function ft_load_doc(p_name text, p_doc jsonb) returns void
language sql set search_path = public as $$
  insert into ft_docs (name, doc, fetched_at) values (p_name, p_doc, now())
  on conflict (name) do update set doc = excluded.doc, fetched_at = now();
$$;

-- every achievement rule: (key, rule)
create or replace function ft_rules() returns table (key text, rule jsonb)
language sql stable set search_path = public as $$
  select a->>'key', a->'rule' from ft_docs d, jsonb_array_elements(d.doc->'achievements') a where d.name = 'achievements';
$$;

-- a club's abbreviation from any name it goes by (longest match wins, as on the page)
create or replace function ft_team_abbr(p_sport text, p_name text) returns text
language sql stable set search_path = public as $$
  select t->>'abbr'
    from ft_docs d, jsonb_array_elements(d.doc->p_sport) t, jsonb_array_elements_text(t->'match') k
   where d.name = 'teams' and position(k in lower(coalesce(p_name,''))) > 0
   order by length(k) desc limit 1;
$$;

-- who someone barracked for, for a match in that round (only picks made by then count)
create or replace function ft_user_team(p_user uuid, p_sport text, p_season int, p_round int) returns text
language sql stable set search_path = public as $$
  select p.teams->p_sport->>'team' from ft_profiles p
   where p.user_id = p_user
     and (p.teams->p_sport->>'season')::int = p_season
     and coalesce((p.teams->p_sport->>'since_round')::int, 0) <= p_round;
$$;

-- which side a head to head leg is on: 'home', 'away' or null
create or replace function ft_leg_side(p_leg jsonb, m ft_matches) returns text
language sql stable set search_path = public as $$
  select case ft_team_abbr(m.sport, p_leg->>'name')
           when ft_team_abbr(m.sport, m.home_team) then 'home'
           when ft_team_abbr(m.sport, m.away_team) then 'away' end;
$$;

-- was a head to head leg on the underdog? (its price longer than the other side's)
create or replace function ft_leg_underdog(p_leg jsonb) returns boolean
language sql stable set search_path = public as $$
  select (p_leg->>'price')::numeric > min((o->>'price')::numeric)
    from ft_odds fo, jsonb_array_elements(fo.markets->'h2h') o
   where fo.match_id = p_leg->>'match_id' and o->>'name' <> p_leg->>'name';
$$;

-- final margin from a side's point of view
create or replace function ft_side_margin(m ft_matches, p_side text) returns int
language sql immutable as $$
  select case p_side when 'home' then m.home_score - m.away_score when 'away' then m.away_score - m.home_score end;
$$;

-- did a head to head result turn in the last p_secs of the game? (the leader then wasn't the winner)
create or replace function ft_h2h_turned_late(p_leg jsonb, p_secs int) returns boolean
language plpgsql stable set search_path = public as $$
declare m ft_matches; v_side text; q int; clk numeric; hs int := 0; as_ int := 0;
begin
  select * into m from ft_matches where id = p_leg->>'match_id';
  if m is null or m.live is null or m.status <> 'concluded' then return false; end if;
  v_side := ft_leg_side(p_leg, m);
  if v_side is null then return false; end if;
  q := (m.live->>'q')::int; clk := (m.live->>'clockSecs')::numeric;
  select coalesce(sum(ft_event_pts(m.sport, e->>'type')) filter (where e->>'team' = 'home'), 0),
         coalesce(sum(ft_event_pts(m.sport, e->>'type')) filter (where e->>'team' = 'away'), 0)
    into hs, as_
    from jsonb_array_elements(m.live->'events') e
   where (e->>'q')::int < q or ((e->>'q')::int = q and (e->>'secs')::numeric <= clk - p_secs);
  -- the side that won wasn't ahead with p_secs to go
  return case v_side when 'home' then hs <= as_ else as_ <= hs end;
end $$;

-- profit at the end of a round from a member's history ({ b, f } or an old plain balance)
create or replace function ft_hist_profit(p_hist jsonb, p_round int, p_start numeric) returns numeric
language sql immutable as $$
  select case when p_hist->(p_round::text) is null then null
              when jsonb_typeof(p_hist->(p_round::text)) = 'number' then (p_hist->>(p_round::text))::numeric - p_start
              else ((p_hist->(p_round::text))->>'b')::numeric - ((p_hist->(p_round::text))->>'f')::numeric end;
$$;

-- unlock (once); true if it's new
create or replace function ft_award(p_user uuid, p_ach text, p_scope text default '', p_comp uuid default null, p_meta jsonb default '{}')
returns boolean
language plpgsql set search_path = public as $$
begin
  if p_user is null then return false; end if;
  insert into ft_unlocks (user_id, ach, scope, comp_id, meta) values (p_user, p_ach, coalesce(p_scope,''), p_comp, coalesce(p_meta,'{}'))
  on conflict do nothing;
  return found;
end $$;


-- ── placing a bet ───────────────────────────────────────────────────────────
-- before it goes in: is this the whole balance? (the slip's total comes off after every bet is in)
create or replace function ft_bets_all_in() returns trigger
language plpgsql set search_path = public as $$
begin
  new.all_in := new.stake >= coalesce((select balance from ft_members where comp_id = new.comp_id and user_id = new.user_id), 0) - 0.005;
  return new;
end $$;
drop trigger if exists ft_bets_all_in on ft_bets;
create trigger ft_bets_all_in before insert on ft_bets for each row execute function ft_bets_all_in();

create or replace function ft_ach_placed(b ft_bets) returns void
language plpgsql set search_path = public as $$
declare r record; v_first timestamptz; v_hour int; v_owner uuid;
begin
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
      if b.all_in and b.stake >= (r.rule->>'min')::numeric then perform ft_award(b.user_id, r.key); end if;
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


-- ── a bet settling, cashing out, or getting its leg results filled in ───────
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
    when 'bet_return_gte' then v_ok := b.status = 'won' and b.payout >= (r.rule->>'amount')::numeric;
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
    when 'all_in_lost' then v_ok := b.status = 'lost' and b.all_in and b.stake >= (r.rule->>'min')::numeric;
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

create or replace function ft_bets_ach() returns trigger
language plpgsql set search_path = public as $$
begin
  begin
    if tg_op = 'INSERT' then
      perform ft_ach_placed(new);
    elsif new.status <> 'pending' and (new.status is distinct from old.status or new.legs is distinct from old.legs) then
      perform ft_ach_settled(new);
    end if;
  exception when others then
    raise warning 'achievements (bet %): %', new.id, sqlerrm;    -- never block the bet itself
  end;
  return null;
end $$;
drop trigger if exists ft_bets_ach on ft_bets;
create trigger ft_bets_ach after insert or update on ft_bets for each row execute function ft_bets_ach();


-- ── chat ────────────────────────────────────────────────────────────────────
create or replace function ft_chats_ach() returns trigger
language plpgsql set search_path = public as $$
declare r record;
begin
  begin
    for r in select * from ft_rules() where rule->>'type' = 'chat_messages' loop
      if (select count(*) from ft_chats where user_id = new.user_id) >= (r.rule->>'count')::int then perform ft_award(new.user_id, r.key); end if;
    end loop;
  exception when others then raise warning 'achievements (chat): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_chats_ach on ft_chats;
create trigger ft_chats_ach after insert on ft_chats for each row execute function ft_chats_ach();


-- ── a round closing ─────────────────────────────────────────────────────────
-- run after the end-of-round snapshot, for every comp of that code
create or replace function ft_ach_round(p_sport text, p_season int, p_round int) returns void
language plpgsql set search_path = public as $$
declare
  c ft_comps; r record; p record; v_n int; v_prev int; v_rp numeric[]; k int; v_ok boolean; v_cnt int;
begin
  for c in select * from ft_comps where sport = p_sport and season = p_season and start_round <= p_round loop
    -- profit now and a round ago, and the ranking on each
    create temp table if not exists _ach_m (user_id uuid, history jsonb, pr numeric, pp numeric, rk int, rkp int) on commit drop;
    truncate _ach_m;
    insert into _ach_m
    select x.user_id, x.history, x.pr, x.pp, rank() over (order by x.pr desc), rank() over (order by x.pp desc)
      from (select mb.user_id, mb.history,
                   coalesce(ft_hist_profit(mb.history, p_round, c.starting_balance), 0) pr,
                   coalesce(ft_hist_profit(mb.history, p_round - 1, c.starting_balance), 0) pp
              from ft_members mb where mb.comp_id = c.id) x;
    select count(*) into v_n from _ach_m;
    continue when v_n < 2;

    for r in select * from ft_rules() loop
      case r.rule->>'type'
      when 'round_top' then
        perform ft_award(z.user_id, r.key) from _ach_m z
         where z.pr - z.pp > 0 and z.pr - z.pp = (select max(pr - pp) from _ach_m);
      when 'rank_top' then
        perform ft_award(z.user_id, r.key) from _ach_m z where z.rk = 1;
      when 'rank_climb' then
        if p_round > c.start_round then
          perform ft_award(z.user_id, r.key) from _ach_m z where z.rkp - z.rk >= (r.rule->>'places')::int;
        end if;
      when 'rank_drop' then
        if p_round > c.start_round then
          perform ft_award(z.user_id, r.key) from _ach_m z where z.rk - z.rkp >= (r.rule->>'places')::int;
        end if;
      when 'round_all_won', 'round_all_lost' then
        perform ft_award(s.user_id, r.key) from (
          select user_id, count(*) n, count(*) filter (where status = case when r.rule->>'type' = 'round_all_won' then 'won' else 'lost' end) hit
            from ft_bets where comp_id = c.id and round = p_round group by user_id) s
         where s.n >= (r.rule->>'min_bets')::int and s.hit = s.n;
      when 'round_underdogs_won' then
        perform ft_award(s.user_id, r.key) from (
          select bb.user_id, count(*) n, count(*) filter (where x->>'result' = 'won') hit
            from ft_bets bb, jsonb_array_elements(bb.legs) x
           where bb.comp_id = c.id and (x->>'round')::int = p_round and x->>'market' = 'h2h' and ft_leg_underdog(x)
           group by bb.user_id) s
         where s.n >= (r.rule->>'count')::int and s.hit = s.n;
      when 'bounce_back' then
        -- a winning round straight after your worst round so far (which was a losing one)
        for p in select * from _ach_m loop
          continue when p_round - 2 <= c.start_round;
          select array_agg(coalesce(ft_hist_profit(p.history, k2, c.starting_balance), 0) - coalesce(ft_hist_profit(p.history, k2 - 1, c.starting_balance), 0) order by k2)
            into v_rp from generate_series(c.start_round, p_round - 1) k2;
          if p.pr - p.pp > 0 and v_rp[cardinality(v_rp)] < 0 and v_rp[cardinality(v_rp)] = (select min(v) from unnest(v_rp) v) then
            perform ft_award(p.user_id, r.key);
          end if;
        end loop;
      when 'comeback' then
        -- last at the end of some earlier round (3+ members), top N now
        if v_n >= 3 then
          for p in select * from _ach_m where rk <= (r.rule->>'top')::int loop
            v_ok := false;
            for k in c.start_round .. p_round - 1 loop
              select rk2 into v_prev from (
                select mb.user_id, rank() over (order by coalesce(ft_hist_profit(mb.history, k, c.starting_balance), 0) desc) rk2
                  from ft_members mb where mb.comp_id = c.id) z where z.user_id = p.user_id;
              if v_prev = v_n then v_ok := true; exit; end if;
            end loop;
            if v_ok then perform ft_award(p.user_id, r.key); end if;
          end loop;
        end if;
      when 'rounds_streak' then
        for p in select * from _ach_m loop
          v_cnt := 0;
          for k in reverse p_round .. c.start_round loop
            exit when not exists (select 1 from ft_bets where comp_id = c.id and user_id = p.user_id and round = k);
            v_cnt := v_cnt + 1;
          end loop;
          if v_cnt >= (r.rule->>'count')::int then perform ft_award(p.user_id, r.key); end if;
        end loop;
      else null;
      end case;
    end loop;
  end loop;
end $$;


-- ── the season finishing (Grand Final over) ─────────────────────────────────
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
    select mb.user_id, mb.balance, mb.funded, mb.balance - mb.funded, rank() over (order by mb.balance - mb.funded desc),
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
        perform ft_award(z.user_id, r.key, c.id::text, c.id, v_meta) from _ach_s z where z.balance <= (r.rule->>'amount')::numeric;
      when 'season_profit_between' then
        perform ft_award(z.user_id, r.key, c.id::text, c.id, v_meta) from _ach_s z
         where z.profit >= (r.rule->>'min')::numeric and z.profit < (r.rule->>'max')::numeric;
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
           and (r.rule->>'profit_max' is null or z.profit / z.funded <  (r.rule->>'profit_max')::numeric);
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


-- ── supporter flairs: picking a team unlocks that season's; same club N seasons running → streak ──
create or replace function ft_supporter_flairs(p_user uuid, p_sport text, p_team text, p_season int) returns void
language plpgsql set search_path = public as $$
declare v_run int := 0; s int; v_at jsonb;
begin
  -- one supporter flair per code per season: a change replaces it (and stops showing it)
  delete from ft_unlocks where user_id = p_user and ach = 'flair_supporter' and scope like p_sport||':%:'||p_season and scope <> p_sport||':'||p_team||':'||p_season;
  update ft_profiles set flair = null
   where user_id = p_user and flair->>'ach' = 'flair_supporter' and flair->>'scope' like p_sport||':%:'||p_season
     and flair->>'scope' <> p_sport||':'||p_team||':'||p_season;
  perform ft_award(p_user, 'flair_supporter', p_sport||':'||p_team||':'||p_season, null,
                   jsonb_build_object('sport', p_sport, 'team', p_team, 'season', p_season));
  -- seasons in a row with this club
  s := p_season;
  while exists (select 1 from ft_unlocks where user_id = p_user and ach = 'flair_supporter' and scope = p_sport||':'||p_team||':'||s) loop
    v_run := v_run + 1; s := s - 1;
  end loop;
  select doc->'flairs'->'streak'->'at' into v_at from ft_docs where name = 'achievements';
  perform ft_award(p_user, 'flair_streak', p_sport||':'||p_team||':'||a, null,
                   jsonb_build_object('sport', p_sport, 'team', p_team, 'season', p_season, 'streak', a))
     from (select jsonb_array_elements_text(coalesce(v_at, '[3,5,10]'))::int a) x where x.a <= v_run;
end $$;

-- pick (or change) your team — 006's rules, plus the season's supporter flair
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

  if v_cur is not null and v_cur->>'team' = p_team and (v_cur->>'season')::int = p_season then return v_teams; end if;
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
  perform ft_supporter_flairs(auth.uid(), p_sport, p_team, p_season);
  return v_teams;
end $$;

-- teams picked before this migration get their flair too
do $$
declare p record;
begin
  for p in select user_id, k sport, teams->k->>'team' team, (teams->k->>'season')::int season
             from ft_profiles, jsonb_object_keys(teams) k where teams->k ? 'team' loop
    perform ft_supporter_flairs(p.user_id, p.sport, p.team, p.season);
  end loop;
end $$;


-- ── the flair you show, and pop-ups you've seen ─────────────────────────────
create or replace function ft_set_flair(p_ach text, p_scope text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_ach is not null and not exists (select 1 from ft_unlocks where user_id = auth.uid() and ach = p_ach and scope = coalesce(p_scope,'')) then
    raise exception 'You haven’t unlocked that one yet.';
  end if;
  v := case when p_ach is null then null else jsonb_build_object('ach', p_ach, 'scope', coalesce(p_scope,'')) end;
  insert into ft_profiles (user_id, flair) values (auth.uid(), v)
  on conflict (user_id) do update set flair = excluded.flair, updated_at = now();
  return v;
end $$;

-- progress towards the count-based achievements (Account's "closest to unlocking")
create or replace function ft_ach_progress() returns table (key text, have int, need int)
language plpgsql stable security definer set search_path = public as $$
declare r record; v int;
begin
  for r in select * from ft_rules() loop
    v := null;
    case r.rule->>'type'
    when 'bets_placed' then select count(*) into v from ft_bets where user_id = auth.uid();
    when 'wins_short_price_count' then
      select count(*) into v from ft_bets where user_id = auth.uid() and status = 'won' and price < (r.rule->>'price')::numeric;
    when 'chat_messages' then select count(*) into v from ft_chats where user_id = auth.uid();
    when 'tailed_count' then
      select count(*) into v from ft_bets x where x.tail_of in (select id from ft_bets where user_id = auth.uid());
    else null;
    end case;
    if v is not null then
      key := r.key; have := v; need := coalesce((r.rule->>'count')::int, 1); return next;
    end if;
  end loop;
end $$;

create or replace function ft_seen_unlocks() returns void
language sql security definer set search_path = public as $$
  update ft_unlocks set seen = true where user_id = auth.uid() and not seen;
$$;

create or replace function ft_seen_round(p_comp uuid, p_round int) returns void
language sql security definer set search_path = public as $$
  update ft_members set seen_round = greatest(coalesce(seen_round, 0), p_round) where comp_id = p_comp and user_id = auth.uid();
$$;


-- ── hook into the round close and the job ───────────────────────────────────
-- 006's version, plus achievements after the snapshot and the season wrap after a Grand Final
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
    -- end-of-round snapshot, for leaderboard movement
    update ft_members mb set history = mb.history || jsonb_build_object(r.round::text, jsonb_build_object('b', mb.balance, 'f', mb.funded))
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

create or replace function ft_tick() returns void
language plpgsql set search_path = public as $$
begin
  perform ft_replay_tick();
  perform ft_settle_bets();
  perform ft_close_rounds();
  begin perform ft_docs_sync(); exception when others then raise warning 'ft_docs_sync: %', sqlerrm; end;
end $$;


-- ── who can call what ──
do $$
declare f text;
begin
  foreach f in array array['ft_set_flair(text,text)', 'ft_seen_unlocks()', 'ft_seen_round(uuid,int)', 'ft_set_team(text,text,int)', 'ft_ach_progress()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['ft_docs_sync()', 'ft_load_doc(text,jsonb)', 'ft_award(uuid,text,text,uuid,jsonb)',
                           'ft_ach_placed(ft_bets)', 'ft_ach_settled(ft_bets)', 'ft_ach_round(text,int,int)', 'ft_ach_season(text,int)',
                           'ft_supporter_flairs(uuid,text,text,int)', 'ft_close_rounds()', 'ft_tick()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
