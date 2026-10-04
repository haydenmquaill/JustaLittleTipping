-- ════════════════════════════════════════════════════════════════════════════
-- Footy Tipping — Supabase schema
-- Lives in the same project as the party games, so every object is prefixed ft_.
-- Run once in the Supabase SQL editor. Safe to re-run: tables use IF NOT EXISTS,
-- functions use CREATE OR REPLACE, policies are dropped and recreated.
--
-- Tables
--   ft_comps    competitions (sport, name, invite code, starting balance, rules)
--   ft_members  who's in which comp — username, balance, host flag, end-of-round history
--   ft_matches  AFL + NRL fixture, results + live feed snapshot (shared by every comp of that code)
--   ft_odds     every market for a match, one row per match      (shared)
--   ft_bets     bets, per comp and user
--   ft_chats    chat messages — comp, sport or global room
--
-- Who writes what
--   Players never write tables directly. Everything goes through the ft_* functions
--   at the bottom, which check membership, host rights, rules, kick-off and balance.
--   ft_matches / ft_odds are written by edge functions using the service role
--   (fixture import, odds pulls, live updates). Bet settlement and end-of-round
--   snapshots also run there — added in a later migration.
-- ════════════════════════════════════════════════════════════════════════════

-- ── tables ──────────────────────────────────────────────────────────────────

create table if not exists ft_comps (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (char_length(trim(name)) between 1 and 40),
  code             text not null unique check (code ~ '^[A-Z0-9]{6}$'),
  sport            text not null default 'afl' check (sport in ('afl','nrl')),   -- one code per comp; rounds follow it
  season           int  not null,
  starting_balance numeric(12,2) not null check (starting_balance > 0),
  start_round      int  not null default 1,          -- leaderboard starts here
  -- { "max_legs": 2–15, "max_stake": 0 = no limit, "props": player markets on/off }
  rules            jsonb not null default '{"max_legs":15,"max_stake":0,"props":true}',
  created_at       timestamptz not null default now()
);

create table if not exists ft_members (
  comp_id    uuid not null references ft_comps(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  username   text not null check (char_length(trim(username)) between 1 and 24),
  is_host    boolean not null default false,
  balance    numeric(12,2) not null,
  history    jsonb not null default '{}',             -- end-of-round balances, e.g. {"5": 1180.50}
  joined_at  timestamptz not null default now(),
  primary key (comp_id, user_id)
);
create unique index if not exists ft_members_one_host on ft_members (comp_id) where is_host;
create unique index if not exists ft_members_username on ft_members (comp_id, lower(username));
create index        if not exists ft_members_user     on ft_members (user_id);

create table if not exists ft_matches (
  id             text primary key,                    -- match-centre id: AFL CD_M20250142701, NRL e.g. 20251112710
  sport          text not null default 'afl' check (sport in ('afl','nrl')),
  season         int  not null,
  round          int  not null,
  home_team      text not null,
  away_team      text not null,
  venue          text,
  commence_time  timestamptz not null,
  status         text not null default 'scheduled' check (status in ('scheduled','live','concluded')),
  home_score     int,
  away_score     int,
  -- live feed snapshot: { q, clockSecs, home, away, events:[…], players:[…] }
  --   AFL: home/away = cumulative [goals,behinds] per quarter; events goal/behind
  --   NRL: home/away = cumulative points per half; events try/conversion/penalty/field_goal
  live           jsonb,
  odds_event_id  text,                                -- The Odds API event id, for pulls
  updated_at     timestamptz not null default now()
);
create index if not exists ft_matches_round on ft_matches (sport, season, round, commence_time);

create table if not exists ft_odds (
  match_id   text primary key references ft_matches(id) on delete cascade,
  bookmaker  text not null,
  -- { "<market_key>": [ { "name":"Over", "description":"Nick Daicos", "point":24.5, "price":1.85 }, … ], … }
  markets    jsonb not null,
  pulled_at  timestamptz not null default now()
);

create table if not exists ft_bets (
  id                uuid primary key default gen_random_uuid(),
  comp_id           uuid not null references ft_comps(id) on delete cascade,
  user_id           uuid not null references auth.users(id) on delete cascade,
  kind              text not null check (kind in ('single','multi','sgm')),
  -- [ { match_id, round, market, name, description, point, price }, … ]
  legs              jsonb not null,
  stake             numeric(12,2) not null check (stake > 0),
  price             numeric(10,2) not null,
  potential_payout  numeric(12,2) not null,
  round             int  not null,                    -- the round it settles in (a multi's last leg)
  status            text not null default 'pending' check (status in ('pending','won','lost','void')),
  payout            numeric(12,2),
  placed_at         timestamptz not null default now(),
  settled_at        timestamptz
);
create index if not exists ft_bets_mine    on ft_bets (comp_id, user_id, placed_at desc);
create index if not exists ft_bets_round   on ft_bets (comp_id, round);
create index if not exists ft_bets_pending on ft_bets (status) where status = 'pending';

-- Rooms: 'comp' (this comp's members), 'sport' (everyone in any comp of that code),
-- 'global' (everyone signed in).
create table if not exists ft_chats (
  id          uuid primary key default gen_random_uuid(),
  -- comp room: the comp. sport/global: the sender's comp (shown as "Gazza · Quaill Family Tipping")
  comp_id     uuid not null references ft_comps(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete set null,
  username    text not null,                          -- name at the time of sending
  body        text not null check (char_length(trim(body)) between 1 and 280),
  room        text not null default 'comp' check (room in ('comp','sport','global')),
  sport       text not null,                          -- the sender's comp's code; filters the sport room
  is_pinned   boolean not null default false,
  created_at  timestamptz not null default now(),
  check (not is_pinned or room = 'comp')              -- only comp-room messages can be pinned
);
create unique index if not exists ft_chats_one_pin on ft_chats (comp_id) where is_pinned;
create index        if not exists ft_chats_comp    on ft_chats (comp_id, created_at) where room = 'comp';
create index        if not exists ft_chats_sport   on ft_chats (sport, created_at)   where room = 'sport';
create index        if not exists ft_chats_global  on ft_chats (created_at)          where room = 'global';

-- ── membership helpers (security definer so RLS policies can call them without recursion) ──

create or replace function ft_is_member(p_comp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ft_members where comp_id = p_comp and user_id = auth.uid());
$$;

create or replace function ft_is_host(p_comp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ft_members where comp_id = p_comp and user_id = auth.uid() and is_host);
$$;

-- ── row level security: reads only ──────────────────────────────────────────

alter table ft_comps   enable row level security;
alter table ft_members enable row level security;
alter table ft_matches enable row level security;
alter table ft_odds    enable row level security;
alter table ft_bets    enable row level security;
alter table ft_chats   enable row level security;

drop policy if exists ft_comps_read   on ft_comps;
drop policy if exists ft_members_read on ft_members;
drop policy if exists ft_matches_read on ft_matches;
drop policy if exists ft_odds_read    on ft_odds;
drop policy if exists ft_bets_read    on ft_bets;
drop policy if exists ft_chats_read   on ft_chats;

-- a comp, and who's in it, is only visible to its members (joining by code goes through ft_find_comp)
create policy ft_comps_read   on ft_comps   for select to authenticated using (ft_is_member(id));
create policy ft_members_read on ft_members for select to authenticated using (ft_is_member(comp_id));
-- footy data is shared
create policy ft_matches_read on ft_matches for select to authenticated using (true);
create policy ft_odds_read    on ft_odds    for select to authenticated using (true);
-- your own bets, plus other members' settled bets (Key Moments) — nobody sees anyone else's pending bets
create policy ft_bets_read    on ft_bets    for select to authenticated
  using (user_id = auth.uid() or (status in ('won','lost') and ft_is_member(comp_id)));
-- sport and global rooms are open to everyone signed in; the comp room to its members
create policy ft_chats_read   on ft_chats   for select to authenticated using (room in ('sport','global') or ft_is_member(comp_id));

-- ── realtime: scores, balances, settled bets and chat push to the page ──────
do $$
declare t text;
begin
  foreach t in array array['ft_matches','ft_members','ft_bets','ft_chats'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = t) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- Functions — every write a player makes goes through one of these
-- ════════════════════════════════════════════════════════════════════════════

-- random 6-character invite code, no look-alike characters (0/O, 1/I/L)
create or replace function ft_new_code_value() returns text
language plpgsql volatile set search_path = public as $$
declare
  a constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  c text;
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    exit when not exists (select 1 from ft_comps where code = c);
  end loop;
  return c;
end $$;

-- the round a new comp's leaderboard starts from: the first round still to be decided
create or replace function ft_current_round(p_sport text, p_season int) returns int
language sql stable set search_path = public as $$
  select coalesce(
    (select min(round) from ft_matches where sport = p_sport and season = p_season and status <> 'concluded'),
    (select max(round) from ft_matches where sport = p_sport and season = p_season),
    1);
$$;

-- look up a comp by invite code (comps aren't readable until you join)
create or replace function ft_find_comp(p_code text)
returns table (id uuid, name text, sport text, members int, starting_balance numeric, is_member boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.sport,
         (select count(*)::int from ft_members m where m.comp_id = c.id),
         c.starting_balance,
         exists (select 1 from ft_members m where m.comp_id = c.id and m.user_id = auth.uid())
  from ft_comps c
  where c.code = upper(trim(p_code));
$$;

-- host a new comp; you become its host member
create or replace function ft_host_comp(p_name text, p_username text, p_starting_balance numeric, p_rules jsonb, p_season int, p_sport text default 'afl')
returns ft_comps
language plpgsql security definer set search_path = public as $$
declare
  v_comp  ft_comps;
  v_rules jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_starting_balance is null or p_starting_balance <= 0 then raise exception 'starting balance must be more than zero'; end if;
  -- keep rules in range: 2–15 legs, stake limit ≥ 0 (0 = none), props on/off
  v_rules := jsonb_build_object(
    'max_legs',  least(15, greatest(2, coalesce((p_rules->>'max_legs')::int, 15))),
    'max_stake', greatest(0, coalesce((p_rules->>'max_stake')::numeric, 0)),
    'props',     coalesce((p_rules->>'props')::boolean, true));

  insert into ft_comps (name, code, sport, season, starting_balance, start_round, rules)
  values (trim(p_name), ft_new_code_value(), p_sport, p_season, p_starting_balance, ft_current_round(p_sport, p_season), v_rules)
  returning * into v_comp;

  insert into ft_members (comp_id, user_id, username, is_host, balance)
  values (v_comp.id, auth.uid(), trim(p_username), true, p_starting_balance);

  return v_comp;
end $$;

-- join a comp with a username; already a member → returns your existing membership
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
  insert into ft_members (comp_id, user_id, username, balance)
  select p_comp, auth.uid(), trim(p_username), c.starting_balance from ft_comps c where c.id = p_comp
  returning * into v_row;
  if v_row is null then raise exception 'Competition not found.'; end if;
  return v_row;
end $$;

-- change your username in one comp
create or replace function ft_set_username(p_comp uuid, p_username text)
returns ft_members
language plpgsql security definer set search_path = public as $$
declare v_row ft_members;
begin
  if not ft_is_member(p_comp) then raise exception 'not a member of this comp'; end if;
  if exists (select 1 from ft_members where comp_id = p_comp and user_id <> auth.uid() and lower(username) = lower(trim(p_username))) then
    raise exception 'That username is taken in this comp.';
  end if;
  update ft_members set username = trim(p_username)
   where comp_id = p_comp and user_id = auth.uid()
  returning * into v_row;
  return v_row;
end $$;

-- ── host tools ──

create or replace function ft_rename_comp(p_comp uuid, p_name text) returns ft_comps
language plpgsql security definer set search_path = public as $$
declare v ft_comps;
begin
  if not ft_is_host(p_comp) then raise exception 'Only the host can do that.'; end if;
  update ft_comps set name = trim(p_name) where id = p_comp returning * into v;
  return v;
end $$;

create or replace function ft_new_code(p_comp uuid) returns ft_comps
language plpgsql security definer set search_path = public as $$
declare v ft_comps;
begin
  if not ft_is_host(p_comp) then raise exception 'Only the host can do that.'; end if;
  update ft_comps set code = ft_new_code_value() where id = p_comp returning * into v;
  return v;
end $$;

-- removes the membership; their past bets stay (Key Moments shows them as a former member)
create or replace function ft_remove_member(p_comp uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ft_is_host(p_comp) then raise exception 'Only the host can do that.'; end if;
  if p_user = auth.uid() then raise exception 'The host can’t remove themselves.'; end if;
  delete from ft_members where comp_id = p_comp and user_id = p_user;
end $$;

-- ── chat ──

-- post as your username in p_comp; p_room is 'comp', 'sport' or 'global'
create or replace function ft_send_chat(p_comp uuid, p_body text, p_room text default 'comp') returns ft_chats
language plpgsql security definer set search_path = public as $$
declare
  v_name  text;
  v_sport text;
  v_row   ft_chats;
begin
  select m.username, c.sport into v_name, v_sport
    from ft_members m join ft_comps c on c.id = m.comp_id
   where m.comp_id = p_comp and m.user_id = auth.uid();
  if v_name is null then raise exception 'not a member of this comp'; end if;
  if coalesce(p_room,'comp') not in ('comp','sport','global') then raise exception 'unknown chat room'; end if;
  insert into ft_chats (comp_id, user_id, username, body, room, sport)
  values (p_comp, auth.uid(), v_name, left(trim(p_body), 280), coalesce(p_room,'comp'), v_sport)
  returning * into v_row;
  return v_row;
end $$;

-- pin one comp-room message (or pass null to unpin)
create or replace function ft_pin_chat(p_comp uuid, p_chat uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ft_is_host(p_comp) then raise exception 'Only the host can do that.'; end if;
  update ft_chats set is_pinned = false where comp_id = p_comp and is_pinned;
  if p_chat is not null then
    update ft_chats set is_pinned = true where id = p_chat and comp_id = p_comp and room = 'comp';
  end if;
end $$;

-- ── betting ──

-- Place a whole slip in one go.
--   p_bets: [ { kind, stake, price, legs:[ { match_id, market, name, description, point }, … ] }, … ]
-- Prices are re-read from ft_odds (the client's price only detects a re-pull since the
-- bet was added). Checks the comp's rules, kick-off and balance. Returns the new balance.
create or replace function ft_place_bets(p_comp uuid, p_bets jsonb) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_comp     ft_comps;
  v_member   ft_members;
  v_max_legs int;
  v_max_stk  numeric;
  v_props    boolean;
  v_total    numeric := 0;
  b jsonb; l jsonb;
  v_kind text; v_stake numeric; v_price numeric; v_leg_px numeric;
  v_match ft_matches;
  v_legs jsonb; v_matches text[]; v_keys text[]; v_key text; v_round int;
  -- markets where only one outcome can land: a Same Game Multi takes one leg per market
  c_exclusive constant text[] := array['h2h','h2h_3_way','spreads','totals',
    'player_goal_scorer_first','player_goal_scorer_last','player_try_scorer_first','player_try_scorer_last',
    'player_marks_most','player_tackles_most','player_afl_fantasy_points_most'];
begin
  select * into v_comp from ft_comps where id = p_comp;
  select * into v_member from ft_members where comp_id = p_comp and user_id = auth.uid() for update;
  if v_member is null then raise exception 'not a member of this comp'; end if;
  if jsonb_typeof(p_bets) <> 'array' or jsonb_array_length(p_bets) = 0 then raise exception 'empty slip'; end if;

  v_max_legs := least(15, coalesce((v_comp.rules->>'max_legs')::int, 15));
  v_max_stk  := coalesce((v_comp.rules->>'max_stake')::numeric, 0);
  v_props    := coalesce((v_comp.rules->>'props')::boolean, true);

  for b in select * from jsonb_array_elements(p_bets) loop
    v_kind  := b->>'kind';
    v_stake := round((b->>'stake')::numeric, 2);
    if v_kind not in ('single','multi','sgm') then raise exception 'invalid bet type'; end if;
    if v_stake is null or v_stake <= 0 then raise exception 'invalid stake'; end if;
    if v_max_stk > 0 and v_stake > v_max_stk then
      raise exception 'This comp’s max stake is $% per bet', v_max_stk;
    end if;
    if v_kind = 'single' and jsonb_array_length(b->'legs') <> 1 then raise exception 'a single has one leg'; end if;
    if v_kind <> 'single' and jsonb_array_length(b->'legs') < 2 then raise exception 'a multi needs at least 2 legs'; end if;
    if jsonb_array_length(b->'legs') > v_max_legs then raise exception 'This comp allows at most % legs', v_max_legs; end if;

    v_price := 1; v_legs := '[]'; v_matches := '{}'; v_keys := '{}'; v_round := 0;
    for l in select * from jsonb_array_elements(b->'legs') loop
      select * into v_match from ft_matches where id = l->>'match_id';
      if v_match is null then raise exception 'unknown match'; end if;
      if v_match.status <> 'scheduled' or v_match.commence_time <= now() then
        raise exception 'Betting closed for % v %', v_match.home_team, v_match.away_team;
      end if;
      -- legs must be from this comp's code (an AFL comp can't take NRL games)
      if v_match.sport <> v_comp.sport then raise exception 'That match isn’t part of this comp'; end if;
      if not v_props and (l->>'market') like 'player\_%' then raise exception 'Player markets are off in this comp'; end if;

      if v_kind = 'multi' then
        -- one leg per match
        if v_match.id = any(v_matches) then raise exception 'a multi takes one leg per match'; end if;
      elsif v_kind = 'sgm' then
        -- every leg from the same match, no contradictions
        if cardinality(v_matches) > 0 and v_match.id <> v_matches[1] then raise exception 'a Same Game Multi must be one match'; end if;
        v_key := case when (l->>'market') = any(c_exclusive) then l->>'market'
                      else (l->>'market') || '|' || coalesce(l->>'description','') end;
        if v_key = any(v_keys) then raise exception 'conflicting legs in Same Game Multi'; end if;
        v_keys := v_keys || v_key;
      end if;
      v_matches := v_matches || v_match.id;

      select (o->>'price')::numeric into v_leg_px
        from ft_odds fo, jsonb_array_elements(fo.markets -> (l->>'market')) o
       where fo.match_id = v_match.id
         and o->>'name' = l->>'name'
         and coalesce(o->>'description','') = coalesce(l->>'description','')
         and coalesce((o->>'point')::numeric, -9999) = coalesce((l->>'point')::numeric, -9999)
       limit 1;
      if v_leg_px is null then raise exception 'selection no longer available'; end if;

      v_price := v_price * v_leg_px;
      v_round := greatest(v_round, v_match.round);
      v_legs  := v_legs || jsonb_build_object(
        'match_id', v_match.id, 'round', v_match.round, 'market', l->>'market', 'name', l->>'name',
        'description', l->'description', 'point', l->'point', 'price', v_leg_px);
    end loop;

    v_price := round(v_price, 2);
    if abs(v_price - coalesce((b->>'price')::numeric, 0)) > 0.011 then
      raise exception 'price changed — remove and re-add this bet';
    end if;

    v_total := v_total + v_stake;
    if v_total > v_member.balance then raise exception 'insufficient balance'; end if;

    insert into ft_bets (comp_id, user_id, kind, legs, stake, price, potential_payout, round)
    values (p_comp, auth.uid(), v_kind, v_legs, v_stake, v_price, round(v_stake * v_price, 2), v_round);
  end loop;

  update ft_members set balance = balance - v_total
   where comp_id = p_comp and user_id = auth.uid()
  returning balance into v_member.balance;
  return v_member.balance;
end $$;

-- ── who can call what ──
do $$
declare f text;
begin
  foreach f in array array[
    'ft_find_comp(text)',
    'ft_host_comp(text,text,numeric,jsonb,int,text)',
    'ft_join_comp(uuid,text)',
    'ft_set_username(uuid,text)',
    'ft_rename_comp(uuid,text)',
    'ft_new_code(uuid)',
    'ft_remove_member(uuid,uuid)',
    'ft_send_chat(uuid,text,text)',
    'ft_pin_chat(uuid,uuid)',
    'ft_place_bets(uuid,jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- internal helpers: not callable from the page
  revoke all on function ft_new_code_value() from public, anon, authenticated;
end $$;
