-- ════════════════════════════════════════════════════════════════════════════
-- 012 — more notifications, and quiet hours
--
--   round wrap    now also says what happened to your money: the weekly allowance landing, or what
--                 you banked and that you're back to the amount (weekly spend); and if you've moved
--                 into the top 3 or to the top
--   results       every leg of a multi / Same Game Multi that lands ("4 of 6"), "one leg to go",
--                 and the bet itself landing, going down or being voided               (on)
--   reminders     the round's first bounce in 2 hours; weekly spend: money left with an hour to go
--                 before the round's last game                                         (on)
--   bet_live      a game you've got a bet on has bounced                               (off)
--   social        someone tailed your bet                                              (on)
--   joins         someone joined one of your comps (everyone in it can share the code)  (on)
--   quiet hours   prefs.quiet (on by default): nothing between 11pm and 7am Melbourne time except
--                 chat. Anything else waits in the queue until 7am.
--
--   ft_push_enqueue()   the one way in: checks the person's settings and quiet hours
--   ft_push_sent        reminders already sent (so each goes once)
--
-- Run after 011. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

alter table ft_push_queue add column if not exists send_after timestamptz not null default now();
create index if not exists ft_push_queue_due on ft_push_queue (send_after);

create table if not exists ft_push_sent (key text primary key, sent_at timestamptz not null default now());
alter table ft_push_sent enable row level security;


-- ── settings ────────────────────────────────────────────────────────────────
create or replace function ft_push_wants(p_user uuid, p_kind text, p_key text default null) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from ft_push_subs s where s.user_id = p_user)
     and case
           when p_kind like 'chat\_%' and not coalesce((p.prefs->'chat'->>'all')::boolean, true) then false   -- chat off altogether
           when p_kind = 'chat_comp'    then coalesce((p.prefs->'chat'->'comp'->>p_key)::boolean, true)
           when p_kind = 'chat_sport'   then coalesce((p.prefs->'chat'->'sport'->>p_key)::boolean, true)
           when p_kind = 'chat_global'  then coalesce((p.prefs->'chat'->>'global')::boolean, false)        -- off until turned on
           when p_kind = 'digest'       then coalesce((p.prefs->'digest'->>p_key)::boolean, true)
           when p_kind = 'bet_live'     then coalesce((p.prefs->>'bet_live')::boolean, false)              -- off until turned on
           when p_kind in ('achievements','results','reminders','social','joins')
                                        then coalesce((p.prefs->>p_kind)::boolean, true)
           else false end
    from (select coalesce((select prefs from ft_profiles where user_id = p_user), '{}'::jsonb) prefs) p;
$$;

-- quiet hours: 11pm–7am Melbourne time → hold until 7am (on unless turned off)
create or replace function ft_push_quiet_until(p_user uuid) returns timestamptz
language plpgsql stable set search_path = public as $$
declare v_local timestamp := now() at time zone 'Australia/Melbourne'; v_on boolean;
begin
  select coalesce((prefs->>'quiet')::boolean, true) into v_on from ft_profiles where user_id = p_user;
  if not coalesce(v_on, true) then return now(); end if;
  if extract(hour from v_local) >= 23 then return (date_trunc('day', v_local) + interval '1 day 7 hours') at time zone 'Australia/Melbourne'; end if;
  if extract(hour from v_local) < 7   then return (date_trunc('day', v_local) + interval '7 hours') at time zone 'Australia/Melbourne'; end if;
  return now();
end $$;

-- the one way into the queue
create or replace function ft_push_enqueue(p_user uuid, p_kind text, p_key text, p_title text, p_body text, p_url text, p_tag text default null)
returns void language plpgsql set search_path = public as $$
begin
  if p_user is null or not ft_push_wants(p_user, p_kind, p_key) then return; end if;
  insert into ft_push_queue (user_id, title, body, url, tag, send_after)
  values (p_user, p_title, coalesce(p_body, ''), coalesce(p_url, './'), p_tag,
          case when p_kind like 'chat\_%' then now() else ft_push_quiet_until(p_user) end);
end $$;

-- little formatting helpers
create or replace function ft_money(v numeric) returns text language sql immutable as $$
  select '$' || case when v = trunc(v) then to_char(v, 'FM999,999,990') else to_char(v, 'FM999,999,990.00') end;
$$;
create or replace function ft_leg_text(l jsonb) returns text language sql immutable as $$
  select trim(case when l->>'name' in ('Yes','No') then coalesce(l->>'description', '') || case when l->>'name' = 'No' then ' (No)' else '' end
                   else coalesce((l->>'description') || ' ', '') || (l->>'name') || coalesce(' ' || (l->>'point'), '') end);
$$;
create or replace function ft_bet_label(b ft_bets) returns text language sql immutable as $$
  select case b.kind when 'single' then 'single'
                     when 'sgm' then 'Same Game Multi'
                     else jsonb_array_length(b.legs) || '-leg multi' end;
$$;


-- ── sending: only what's due (quiet hours hold the rest) ────────────────────
create or replace function ft_push_claim(p_limit int default 200)
returns table (id bigint, title text, body text, url text, tag text, subs jsonb)
language sql security definer set search_path = public as $$
  with taken as (
    delete from ft_push_queue where id in (
      select id from ft_push_queue where send_after <= now() order by id limit p_limit for update skip locked)
    returning *
  )
  select t.id, t.title, t.body, t.url, t.tag,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                     from ft_push_subs s where s.user_id = t.user_id), '[]')
    from taken t order by t.id;
$$;

create or replace function ft_push_flush() returns void
language plpgsql set search_path = public as $$
declare v_url text; v_secret text;
begin
  delete from ft_push_queue where send_after < now() - interval '1 hour';     -- nobody's sending; don't pile up
  if not exists (select 1 from ft_push_queue where send_after <= now()) then return; end if;
  select value into v_url from ft_config where key = 'push_url';
  select value into v_secret from ft_config where key = 'push_secret';
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(v_url, '{}'::jsonb, '{}'::jsonb,
    jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret), 10000);
end $$;


-- ── achievements (009's, through the new way in) ────────────────────────────
create or replace function ft_push_unlock() returns trigger
language plpgsql set search_path = public as $$
begin
  begin
    perform ft_push_enqueue(new.user_id, 'achievements', null,
      case when new.ach like 'flair\_%' then '🎽 New flair unlocked' else '🏆 Achievement unlocked' end,
      ft_unlock_label(new.ach, new.scope, new.meta), './?achievements=1', 'ach-' || new.ach || '-' || new.scope);
  exception when others then raise warning 'push (unlock): %', sqlerrm;
  end;
  return null;
end $$;


-- ── the round wrap: now with your money and big moves ───────────────────────
-- fires as a round is marked closed: before weekly spend banks and before the next allowance lands
create or replace function ft_push_digest() returns trigger
language plpgsql set search_path = public as $$
declare c ft_comps; v_top text; v_best text; p record; v_n int; v_next boolean; v_mode text; v_money text; v_move text;
begin
  begin
    v_next := exists (select 1 from ft_matches x where x.sport = new.sport and x.season = new.season and x.round = new.round + 1);
    for c in select * from ft_comps where sport = new.sport and season = new.season and start_round <= new.round loop
      select count(*) into v_n from ft_members where comp_id = c.id;
      continue when v_n < 2;
      v_mode := coalesce(c.rules->>'bankroll', 'once');
      select string_agg(format('%s %s %s', rk, username,
               case when v_mode = 'spend' then ft_money(profit) when profit >= 0 then '+' || ft_money(profit) else '−' || ft_money(abs(profit)) end), ' · ' order by rk)
        into v_top
        from (select username, ft_member_profit(balance, funded, banked, c.starting_balance, v_mode) profit,
                     rank() over (order by ft_member_profit(balance, funded, banked, c.starting_balance, v_mode) desc) rk
                from ft_members where comp_id = c.id) s where rk <= 3;
      select format('Biggest win: %s +%s', m.username, ft_money(b.payout - b.stake)) into v_best
        from ft_bets b join ft_members m on m.comp_id = b.comp_id and m.user_id = b.user_id
       where b.comp_id = c.id and b.round = new.round and b.status = 'won' order by b.payout - b.stake desc limit 1;

      for p in select s.* from (
                 select user_id, balance, history,
                        rank() over (order by ft_member_profit(balance, funded, banked, c.starting_balance, v_mode) desc) rk,
                        rank() over (order by coalesce(ft_hist_profit(history, new.round - 1, c.starting_balance), 0) desc) rk_prev
                   from ft_members where comp_id = c.id) s
               where exists (select 1 from ft_bets b where b.comp_id = c.id and b.user_id = s.user_id and b.round >= new.round - 1) loop
        -- your money
        v_money := case
          when v_mode = 'weekly' and v_next then format('💰 +%s allowance for round %s', ft_money(c.starting_balance), new.round + 1)
          when v_mode = 'spend' then
            case when p.balance > c.starting_balance then format('Banked +%s · ', ft_money(p.balance - c.starting_balance)) else '' end ||
            case when v_next then format('Back to %s for round %s', ft_money(c.starting_balance), new.round + 1) else 'Season done' end
          else null end;
        -- a big move
        v_move := case
          when new.round > c.start_round and p.rk = 1 and p.rk_prev > 1 then '👑 You’re top of the leaderboard!'
          when new.round > c.start_round and p.rk <= 3 and p.rk_prev > 3 then '📈 You’ve moved into the top 3'
          else null end;
        perform ft_push_enqueue(p.user_id, 'digest', c.id::text,
          format('📊 Round %s wrap · %s', new.round, c.name),
          concat_ws(E'\n', v_move, v_top, format('You’re #%s of %s', p.rk, v_n), v_money, v_best),
          './?comp=' || c.id || '&overview=1', 'digest-' || c.id);
      end loop;
    end loop;
  exception when others then raise warning 'push (digest): %', sqlerrm;
  end;
  return null;
end $$;


-- ── your bets: every leg that lands, one to go, and the result ──────────────
create or replace function ft_push_bets() returns trigger
language plpgsql set search_path = public as $$
declare n int; n_won int; v_new jsonb; v_left jsonb; v_lost jsonb; m ft_matches; v_url text; v_label text;
begin
  begin
    if tg_op <> 'UPDATE' or old.status <> 'pending' then return null; end if;
    v_url := './?comp=' || new.comp_id || '&view=mybets';
    v_label := ft_bet_label(new);
    n := jsonb_array_length(new.legs);
    select count(*) filter (where x->>'result' = 'won') into n_won from jsonb_array_elements(new.legs) x;

    if new.status = 'won' then
      perform ft_push_enqueue(new.user_id, 'results', null,
        format('✅ Your %s landed!', v_label),
        format('+%s (%s @ %s)', ft_money(new.payout - new.stake), ft_money(new.stake), new.price), v_url, 'bet-' || new.id);
    elsif new.status = 'lost' then
      select x into v_lost from jsonb_array_elements(new.legs) x where x->>'result' = 'lost' limit 1;
      perform ft_push_enqueue(new.user_id, 'results', null,
        format('❌ Your %s went down', v_label),
        case when n > 1 then format('%s didn’t get there · %s of %s legs landed', ft_leg_text(v_lost), n_won, n)
             else format('%s · −%s', ft_leg_text(v_lost), ft_money(new.stake)) end, v_url, 'bet-' || new.id);
    elsif new.status = 'void' then
      perform ft_push_enqueue(new.user_id, 'results', null, format('↩️ Your %s was voided', v_label),
        format('%s back in your balance', ft_money(new.payout)), v_url, 'bet-' || new.id);
    elsif new.status = 'pending' and n > 1 then
      -- legs that just landed (a result now that wasn't there before)
      for v_new in select x from jsonb_array_elements(new.legs) with ordinality a(x, i)
                    where x->>'result' = 'won' and coalesce((old.legs->(i::int - 1))->>'result', '') <> 'won' loop
        if n_won = n - 1 then
          select x into v_left from jsonb_array_elements(new.legs) x where not (x ? 'result') limit 1;
          select * into m from ft_matches where id = v_left->>'match_id';
          perform ft_push_enqueue(new.user_id, 'results', null,
            format('😬 One leg to go · %s of %s', n_won, n),
            format('%s landed. %s decides it%s', ft_leg_text(v_new), ft_leg_text(v_left),
                   case when m.id is not null then format(' (%s v %s)', m.home_team, m.away_team) else '' end),
            v_url, 'bet-' || new.id);
        else
          perform ft_push_enqueue(new.user_id, 'results', null,
            format('✅ Leg landed · %s of %s', n_won, n),
            format('%s · your %s is still alive', ft_leg_text(v_new), v_label), v_url, 'bet-' || new.id);
        end if;
      end loop;
    end if;
  exception when others then raise warning 'push (bets): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_bets on ft_bets;
create trigger ft_push_bets after update on ft_bets for each row execute function ft_push_bets();

-- someone tailed your bet
create or replace function ft_push_tailed() returns trigger
language plpgsql set search_path = public as $$
declare v_owner ft_bets; v_name text;
begin
  begin
    if new.tail_of is null then return null; end if;
    select * into v_owner from ft_bets where id = new.tail_of;
    if v_owner.user_id is null or v_owner.user_id = new.user_id then return null; end if;
    select username into v_name from ft_members where comp_id = new.comp_id and user_id = new.user_id;
    perform ft_push_enqueue(v_owner.user_id, 'social', null, format('🐱 %s tailed your %s', coalesce(v_name, 'Someone'), ft_bet_label(v_owner)),
      'Copycat. Let’s hope you know what you’re doing.', './?comp=' || new.comp_id || '&view=mybets', 'tail-' || v_owner.id);
  exception when others then raise warning 'push (tail): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_tailed on ft_bets;
create trigger ft_push_tailed after insert on ft_bets for each row execute function ft_push_tailed();

-- a game you've got a bet on has bounced (off unless turned on)
create or replace function ft_push_bet_live() returns trigger
language plpgsql set search_path = public as $$
begin
  begin
    if old.status = 'scheduled' and new.status = 'live' then
      perform ft_push_enqueue(u.user_id, 'bet_live', null, '🏉 Your bet’s live',
                format('%s v %s has bounced', new.home_team, new.away_team), './?comp=' || u.comp_id || '&view=mybets', 'live-' || new.id)
        from (select distinct on (b.user_id) b.user_id, b.comp_id
                from ft_bets b, jsonb_array_elements(b.legs) x
               where b.status = 'pending' and x->>'match_id' = new.id) u;
    end if;
  exception when others then raise warning 'push (live): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_bet_live on ft_matches;
create trigger ft_push_bet_live after update of status on ft_matches for each row execute function ft_push_bet_live();

-- someone joined: everyone already in the comp hears about it (anyone can share the code)
create or replace function ft_push_joined() returns trigger
language plpgsql set search_path = public as $$
declare v_comp text;
begin
  begin
    if new.is_host then return null; end if;                -- a new comp: nobody to tell
    select name into v_comp from ft_comps where id = new.comp_id;
    perform ft_push_enqueue(m.user_id, 'joins', null, '👋 New member', format('%s joined %s', new.username, v_comp),
      './?comp=' || new.comp_id, 'join-' || new.comp_id)
      from ft_members m where m.comp_id = new.comp_id and m.user_id <> new.user_id;
  exception when others then raise warning 'push (join): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_joined on ft_members;
create trigger ft_push_joined after insert on ft_members for each row execute function ft_push_joined();


-- ── reminders (from the 5-second job; each goes once) ───────────────────────
create or replace function ft_push_reminders() returns void
language plpgsql set search_path = public as $$
declare r record; c ft_comps; v_key text;
begin
  -- the round's first bounce is within 2 hours
  for r in select sport, season, round, min(commence_time) first_at from ft_matches
            group by sport, season, round
           having min(commence_time) > now() and min(commence_time) <= now() + interval '2 hours' loop
    for c in select * from ft_comps where sport = r.sport and season = r.season and start_round <= r.round loop
      v_key := 'open:' || c.id || ':' || r.round;
      continue when exists (select 1 from ft_push_sent where key = v_key);
      insert into ft_push_sent (key) values (v_key);
      perform ft_push_enqueue(mb.user_id, 'reminders', null,
        format('🏉 Round %s starts %s', r.round, lower(to_char(r.first_at at time zone 'Australia/Melbourne', 'FMHH12:MIam'))),
        case when coalesce(c.rules->>'bankroll', 'once') = 'spend' then format('You’ve got %s to spend in %s.', ft_money(mb.balance), c.name)
             else format('Get your bets in for %s. Balance: %s', c.name, ft_money(mb.balance)) end,
        './?comp=' || c.id, 'open-' || c.id)
        from ft_members mb where mb.comp_id = c.id;
    end loop;
  end loop;

  -- weekly spend: the round's last game bounces within the hour and you've still got money
  for r in select sport, season, round, max(commence_time) last_at from ft_matches
            group by sport, season, round
           having max(commence_time) > now() and max(commence_time) <= now() + interval '1 hour' loop
    for c in select * from ft_comps where sport = r.sport and season = r.season and start_round <= r.round
                                      and coalesce(rules->>'bankroll', 'once') = 'spend' loop
      v_key := 'spend:' || c.id || ':' || r.round;
      continue when exists (select 1 from ft_push_sent where key = v_key);
      insert into ft_push_sent (key) values (v_key);
      perform ft_push_enqueue(mb.user_id, 'reminders', null,
        format('⏰ %s left to spend', ft_money(mb.balance)),
        format('The last game of round %s starts in %s min. Use it or lose it!', r.round, greatest(1, ceil(extract(epoch from r.last_at - now()) / 60))::int),
        './?comp=' || c.id, 'spend-' || c.id)
        from ft_members mb where mb.comp_id = c.id and mb.balance >= 1;
    end loop;
  end loop;
  delete from ft_push_sent where sent_at < now() - interval '30 days';
end $$;

-- the 5-second job: 009's, plus reminders
create or replace function ft_tick() returns void
language plpgsql set search_path = public as $$
begin
  perform ft_replay_tick();
  perform ft_settle_bets();
  perform ft_close_rounds();
  begin perform ft_docs_sync(); exception when others then raise warning 'ft_docs_sync: %', sqlerrm; end;
  begin perform ft_push_reminders(); exception when others then raise warning 'ft_push_reminders: %', sqlerrm; end;
  begin perform ft_push_flush(); exception when others then raise warning 'ft_push_flush: %', sqlerrm; end;
end $$;


-- ── who can call what ──
do $$
declare f text;
begin
  foreach f in array array['ft_push_claim(int)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['ft_push_enqueue(uuid,text,text,text,text,text,text)', 'ft_push_reminders()', 'ft_push_flush()', 'ft_tick()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
