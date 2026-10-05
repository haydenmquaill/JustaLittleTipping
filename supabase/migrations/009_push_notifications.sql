-- ════════════════════════════════════════════════════════════════════════════
-- 009 — push notifications
--
-- What gets sent (each person chooses in the app; stored in ft_profiles.prefs):
--   chat         a message in a room you're in, unless you've muted it. The global room is
--                muted until you turn it on: prefs.chat = { comp:{ <comp id>:false }, sport:{ afl:false }, global:true }
--   round wrap   after each round closes, per comp: the top 3, where you sit, the biggest win.
--                Mute a comp with prefs.digest = { <comp id>:false }. Only goes to people who've
--                bet in the last couple of rounds.
--   achievements an unlock while you're away (prefs.achievements = false to stop them)
-- The service worker skips the notification if the app is open on screen; the page shows its own.
--
-- How it's sent:
--   ft_push_subs    one row per device that turned notifications on (from the page)
--   ft_push_queue   messages waiting to go out; triggers fill it
--   ft_push_flush() (in the 5-second job) pokes the ft-push Edge Function, which claims the queue
--                   with ft_push_claim(), signs and sends each message (VAPID), and drops dead devices.
--   Set up once (see supabase/functions/ft-push/README.md):
--     update ft_config set value = 'https://<project>.supabase.co/functions/v1/ft-push' where key = 'push_url';
--     update ft_config set value = '<the same secret as the function's FT_PUSH_SECRET>' where key = 'push_secret';
--   Until then messages just wait in the queue (and are dropped after an hour).
--
-- Run after 008. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists ft_push_subs (
  endpoint   text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index if not exists ft_push_subs_user on ft_push_subs (user_id);

create table if not exists ft_push_queue (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  title      text not null,
  body       text not null default '',
  url        text not null default './',
  tag        text,                                -- same tag replaces the last one (e.g. a busy chat room)
  created_at timestamptz not null default now()
);

alter table ft_push_subs  enable row level security;
alter table ft_push_queue enable row level security;
drop policy if exists ft_push_subs_mine on ft_push_subs;
create policy ft_push_subs_mine on ft_push_subs for select to authenticated using (user_id = auth.uid());

insert into ft_config (key, value) values ('push_url', null), ('push_secret', null) on conflict (key) do nothing;


-- ── the page: this device on / off, and your settings ───────────────────────
create or replace function ft_push_subscribe(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into ft_push_subs (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function ft_push_unsubscribe(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from ft_push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- replace your notification settings (the page sends the whole object)
create or replace function ft_set_prefs(p_prefs jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into ft_profiles (user_id, prefs) values (auth.uid(), coalesce(p_prefs, '{}'))
  on conflict (user_id) do update set prefs = excluded.prefs, updated_at = now();
  return p_prefs;
end $$;


-- ── who wants what ──────────────────────────────────────────────────────────
-- p_kind: 'chat_comp' | 'chat_sport' | 'chat_global' | 'digest' | 'achievements'; p_key: comp id or code
create or replace function ft_push_wants(p_user uuid, p_kind text, p_key text default null) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from ft_push_subs s where s.user_id = p_user)
     and case p_kind
           when 'chat_comp'    then coalesce((p.prefs->'chat'->'comp'->>p_key)::boolean, true)
           when 'chat_sport'   then coalesce((p.prefs->'chat'->'sport'->>p_key)::boolean, true)
           when 'chat_global'  then coalesce((p.prefs->'chat'->>'global')::boolean, false)     -- off until turned on
           when 'digest'       then coalesce((p.prefs->'digest'->>p_key)::boolean, true)
           when 'achievements' then coalesce((p.prefs->>'achievements')::boolean, true)
           else false end
    from (select coalesce((select prefs from ft_profiles where user_id = p_user), '{}'::jsonb) prefs) p;
$$;

-- an unlock's display name, from data/achievements.json (flair names fill in their template)
create or replace function ft_unlock_label(p_ach text, p_scope text, p_meta jsonb) returns text
language plpgsql stable set search_path = public as $$
declare v_doc jsonb; v_t text; v_sport text; v_team jsonb; v_season text; v_streak text;
begin
  select doc into v_doc from ft_docs where name = 'achievements';
  if p_ach not like 'flair\_%' then
    return coalesce((select a->>'name' from jsonb_array_elements(v_doc->'achievements') a where a->>'key' = p_ach), p_ach);
  end if;
  v_t := v_doc->'flairs'->substr(p_ach, 7)->>'name';
  if v_t is null then return 'New flair'; end if;
  v_sport := split_part(p_scope, ':', 1);
  select t into v_team from ft_docs d, jsonb_array_elements(d.doc->v_sport) t where d.name = 'teams' and t->>'abbr' = split_part(p_scope, ':', 2);
  v_season := coalesce(p_meta->>'season', split_part(p_scope, ':', 3));
  v_streak := coalesce(p_meta->>'streak', split_part(p_scope, ':', 3));
  return replace(replace(replace(replace(replace(replace(v_t,
    '{team}', coalesce(v_team->>'name', split_part(p_scope, ':', 2))),
    '{nick}', coalesce(v_team->>'nick', v_team->>'name', split_part(p_scope, ':', 2))),
    '{abbr}', split_part(p_scope, ':', 2)),
    '{season}', v_season), '{yy}', right(v_season, 2)), '{streak}', v_streak);
end $$;


-- ── what fills the queue ────────────────────────────────────────────────────
-- chat: everyone in the room except the sender
create or replace function ft_push_chat() returns trigger
language plpgsql set search_path = public as $$
declare v_comp text; v_url text;
begin
  begin
    select name into v_comp from ft_comps where id = new.comp_id;
    v_url := './?comp=' || new.comp_id || '&chat=' || new.room;
    insert into ft_push_queue (user_id, title, body, url, tag)
    select u.user_id,
           '💬 ' || new.username || case new.room when 'comp' then ' · ' || v_comp when 'sport' then ' · ' || upper(new.sport) || ' chat' else ' · Everyone' end,
           left(new.body, 140), v_url, 'chat-' || new.room || '-' || case new.room when 'comp' then new.comp_id::text when 'sport' then new.sport else 'all' end
      from (
        select distinct m.user_id from ft_members m join ft_comps c on c.id = m.comp_id
         where case new.room when 'comp' then m.comp_id = new.comp_id when 'sport' then c.sport = new.sport else true end
      ) u
     where u.user_id is distinct from new.user_id
       and ft_push_wants(u.user_id, 'chat_' || new.room, case new.room when 'comp' then new.comp_id::text when 'sport' then new.sport end);
  exception when others then raise warning 'push (chat): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_chat on ft_chats;
create trigger ft_push_chat after insert on ft_chats for each row execute function ft_push_chat();

-- an achievement or flair unlocked
create or replace function ft_push_unlock() returns trigger
language plpgsql set search_path = public as $$
begin
  begin
    if ft_push_wants(new.user_id, 'achievements') then
      insert into ft_push_queue (user_id, title, body, url, tag)
      values (new.user_id,
              case when new.ach like 'flair\_%' then '🎽 New flair unlocked' else '🏆 Achievement unlocked' end,
              ft_unlock_label(new.ach, new.scope, new.meta), './?achievements=1', 'ach-' || new.ach || '-' || new.scope);
    end if;
  exception when others then raise warning 'push (unlock): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_unlock on ft_unlocks;
create trigger ft_push_unlock after insert on ft_unlocks for each row execute function ft_push_unlock();

-- the round wrap: fires as a round is marked closed (before next round's allowance lands)
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
        from (select username, balance - funded profit, rank() over (order by balance - funded desc) rk from ft_members where comp_id = c.id) s where rk <= 3;
      select format('Biggest win: %s +$%s', m.username, to_char(b.payout - b.stake, 'FM999,990')) into v_best
        from ft_bets b join ft_members m on m.comp_id = b.comp_id and m.user_id = b.user_id
       where b.comp_id = c.id and b.round = new.round and b.status = 'won' order by b.payout - b.stake desc limit 1;
      for p in select user_id, rk, profit from (
                 select user_id, balance - funded profit, rank() over (order by balance - funded desc) rk from ft_members where comp_id = c.id) s
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
drop trigger if exists ft_push_digest on ft_round_closed;
create trigger ft_push_digest after insert on ft_round_closed for each row execute function ft_push_digest();


-- ── sending: the job pokes the Edge Function, which claims the queue ────────
create or replace function ft_push_flush() returns void
language plpgsql set search_path = public as $$
declare v_url text; v_secret text;
begin
  delete from ft_push_queue where created_at < now() - interval '1 hour';      -- nobody's sending; don't pile up
  if not exists (select 1 from ft_push_queue) then return; end if;
  select value into v_url from ft_config where key = 'push_url';
  select value into v_secret from ft_config where key = 'push_secret';
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(v_url, '{}'::jsonb, '{}'::jsonb,
    jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret), 10000);
end $$;

-- for the Edge Function (service role): take up to p_limit messages, with each person's devices
create or replace function ft_push_claim(p_limit int default 200)
returns table (id bigint, title text, body text, url text, tag text, subs jsonb)
language sql security definer set search_path = public as $$
  with taken as (
    delete from ft_push_queue where id in (select id from ft_push_queue order by id limit p_limit for update skip locked)
    returning *
  )
  select t.id, t.title, t.body, t.url, t.tag,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                     from ft_push_subs s where s.user_id = t.user_id), '[]')
    from taken t order by t.id;
$$;

-- for the Edge Function: forget a device the browser says is gone
create or replace function ft_push_drop(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from ft_push_subs where endpoint = p_endpoint;
$$;

-- the 5-second job: 008's, plus sending
create or replace function ft_tick() returns void
language plpgsql set search_path = public as $$
begin
  perform ft_replay_tick();
  perform ft_settle_bets();
  perform ft_close_rounds();
  begin perform ft_docs_sync(); exception when others then raise warning 'ft_docs_sync: %', sqlerrm; end;
  begin perform ft_push_flush(); exception when others then raise warning 'ft_push_flush: %', sqlerrm; end;
end $$;


-- ── who can call what ──
do $$
declare f text;
begin
  foreach f in array array['ft_push_subscribe(text,text,text)', 'ft_push_unsubscribe(text)', 'ft_set_prefs(jsonb)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['ft_push_claim(int)', 'ft_push_drop(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['ft_push_flush()', 'ft_tick()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
