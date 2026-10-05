-- ════════════════════════════════════════════════════════════════════════════
-- 013 — the social bits: chat edits, avatars, real names, friends, direct + group messages
--
--   chat           edit or delete your own messages (the host can delete any in the comp room)
--   avatars        a photo per person (Storage bucket ft-avatars, public), ft_profiles.avatar_url
--   real names     ft_people: only you and your FRIENDS can read it (also mirrored to the auth
--                  user's display name by the page)
--   friends        ft_friends: a request either way, accepted by the other person. Friends see each
--                  other's real name, can message each other, and can choose to be notified when the
--                  other places a bet (in comps they share; bets stay private to their comp)
--   messages       ft_threads (a direct chat between two friends, or a group of friends someone
--                  created), ft_thread_members, ft_messages. Only members can read a thread.
--   notifications  'friends' (requests / accepts), 'friend_bets' (per friend), 'dm' (messages;
--                  like chat, never held by quiet hours)
--
-- Run after 012. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

-- ── chat: edit / delete ─────────────────────────────────────────────────────
alter table ft_chats add column if not exists edited_at timestamptz;
alter table ft_chats add column if not exists deleted   boolean not null default false;

create or replace function ft_edit_chat(p_id uuid, p_body text) returns ft_chats
language plpgsql security definer set search_path = public as $$
declare v ft_chats;
begin
  if coalesce(char_length(trim(p_body)), 0) not between 1 and 280 then raise exception 'Messages are 1 to 280 characters.'; end if;
  update ft_chats set body = trim(p_body), edited_at = now()
   where id = p_id and user_id = auth.uid() and not deleted
  returning * into v;
  if v is null then raise exception 'You can only edit your own messages.'; end if;
  return v;
end $$;

-- your own message, or (host) anything in your comp's room
create or replace function ft_delete_chat(p_id uuid) returns ft_chats
language plpgsql security definer set search_path = public as $$
declare v ft_chats;
begin
  update ft_chats c set deleted = true, body = '·', is_pinned = false, edited_at = null
   where c.id = p_id and not c.deleted
     and (c.user_id = auth.uid() or (c.room = 'comp' and ft_is_host(c.comp_id)))
  returning * into v;
  if v is null then raise exception 'You can’t delete that message.'; end if;
  return v;
end $$;


-- ── avatars ─────────────────────────────────────────────────────────────────
alter table ft_profiles add column if not exists avatar_url text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ft-avatars', 'ft-avatars', true, 524288, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- you can only write inside your own folder: ft-avatars/<your user id>/…
drop policy if exists ft_avatars_insert on storage.objects;
drop policy if exists ft_avatars_update on storage.objects;
drop policy if exists ft_avatars_delete on storage.objects;
drop policy if exists ft_avatars_select on storage.objects;
create policy ft_avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'ft-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy ft_avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'ft-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy ft_avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'ft-avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy ft_avatars_select on storage.objects for select to authenticated
  using (bucket_id = 'ft-avatars');

-- point your profile at your uploaded photo (or null to remove it)
create or replace function ft_set_avatar(p_url text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_url is not null and p_url !~ ('^https://[^/]+/storage/v1/object/public/ft-avatars/' || auth.uid()::text || '/') then
    raise exception 'That isn’t your avatar.';
  end if;
  insert into ft_profiles (user_id, avatar_url) values (auth.uid(), p_url)
  on conflict (user_id) do update set avatar_url = excluded.avatar_url, updated_at = now();
  return p_url;
end $$;


-- ── friends ─────────────────────────────────────────────────────────────────
create table if not exists ft_friends (
  a            uuid not null references auth.users(id) on delete cascade,   -- a < b, one row per pair
  b            uuid not null references auth.users(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending','accepted')),
  requested_by uuid not null,
  notify_a     boolean not null default false,       -- a wants to hear when b places a bet
  notify_b     boolean not null default false,       -- b wants to hear when a places a bet
  created_at   timestamptz not null default now(),
  accepted_at  timestamptz,
  primary key (a, b),
  check (a < b)
);
create index if not exists ft_friends_b on ft_friends (b);
alter table ft_friends enable row level security;
drop policy if exists ft_friends_read on ft_friends;
create policy ft_friends_read on ft_friends for select to authenticated using (auth.uid() in (a, b));

create or replace function ft_are_friends(p_a uuid, p_b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ft_friends where a = least(p_a, p_b) and b = greatest(p_a, p_b) and status = 'accepted');
$$;

-- send a request (or accept theirs if they already asked you); returns 'pending' / 'accepted'
create or replace function ft_friend_request(p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v ft_friends; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_user is null or p_user = me then raise exception 'That’s you!'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'No one has that user ID. Check it and try again.'; end if;
  select * into v from ft_friends where a = least(me, p_user) and b = greatest(me, p_user);
  if v.a is null then
    insert into ft_friends (a, b, requested_by) values (least(me, p_user), greatest(me, p_user), me);
    return 'pending';
  end if;
  if v.status = 'pending' and v.requested_by = p_user then
    update ft_friends set status = 'accepted', accepted_at = now() where a = v.a and b = v.b;
    return 'accepted';
  end if;
  return v.status;
end $$;

create or replace function ft_friend_respond(p_user uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if p_accept then
    update ft_friends set status = 'accepted', accepted_at = now()
     where a = least(me, p_user) and b = greatest(me, p_user) and status = 'pending' and requested_by = p_user;
  else
    delete from ft_friends where a = least(me, p_user) and b = greatest(me, p_user) and status = 'pending';
  end if;
end $$;

-- unfriend, or cancel a request you sent
create or replace function ft_friend_remove(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from ft_friends where a = least(auth.uid(), p_user) and b = greatest(auth.uid(), p_user);
$$;

-- hear about a friend's bets (in comps you share)
create or replace function ft_friend_notify(p_user uuid, p_on boolean) returns void
language sql security definer set search_path = public as $$
  update ft_friends set notify_a = case when a = auth.uid() then p_on else notify_a end,
                        notify_b = case when b = auth.uid() then p_on else notify_b end
   where a = least(auth.uid(), p_user) and b = greatest(auth.uid(), p_user) and status = 'accepted';
$$;


-- ── real names (you and your friends only) ──────────────────────────────────
create table if not exists ft_people (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  real_name  text check (real_name is null or char_length(real_name) between 1 and 60),
  updated_at timestamptz not null default now()
);
alter table ft_people enable row level security;
drop policy if exists ft_people_read on ft_people;
create policy ft_people_read on ft_people for select to authenticated
  using (user_id = auth.uid() or ft_are_friends(auth.uid(), user_id));

create or replace function ft_set_real_name(p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(coalesce(p_name, '')), '');
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if v is not null and char_length(v) > 60 then raise exception 'Keep it under 60 characters.'; end if;
  insert into ft_people (user_id, real_name) values (auth.uid(), v)
  on conflict (user_id) do update set real_name = excluded.real_name, updated_at = now();
  return v;
end $$;

-- the name to show for someone: their real name if you're friends (or it's you), otherwise the
-- most recent username they've used in any comp
create or replace function ft_known_as(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select username from ft_members where user_id = p_user order by joined_at desc limit 1), 'Someone');
$$;

-- everything the profile view needs about someone (only what you're allowed to see)
create or replace function ft_person(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); v_fr ft_friends; v_friends boolean;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into v_fr from ft_friends where a = least(me, p_user) and b = greatest(me, p_user);
  v_friends := v_fr.status = 'accepted';
  return jsonb_build_object(
    'user_id',   p_user,
    'known_as',  ft_known_as(p_user),
    'real_name', case when v_friends or p_user = me then (select real_name from ft_people where user_id = p_user) end,
    'avatar_url',(select avatar_url from ft_profiles where user_id = p_user),
    'friend',    case when v_fr.a is null then 'none' when v_friends then 'friends'
                      when v_fr.requested_by = me then 'requested' else 'incoming' end,
    'notify',    case when v_friends then case when v_fr.a = me then v_fr.notify_a else v_fr.notify_b end end,
    -- comps you're both in (with the name they use there)
    'shared',    coalesce((select jsonb_agg(jsonb_build_object('comp_id', c.id, 'comp_name', c.name, 'sport', c.sport, 'username', t.username) order by c.name)
                             from ft_members t join ft_members m on m.comp_id = t.comp_id and m.user_id = me join ft_comps c on c.id = t.comp_id
                            where t.user_id = p_user), '[]'));
end $$;

-- your friends and requests, with what to call them and their avatar
create or replace function ft_my_friends() returns table (user_id uuid, status text, incoming boolean, notify boolean,
                                                           known_as text, real_name text, avatar_url text, since timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, f.status, f.status = 'pending' and f.requested_by <> auth.uid(),
         case when f.a = auth.uid() then f.notify_a else f.notify_b end,
         ft_known_as(o.id),
         case when f.status = 'accepted' then (select real_name from ft_people p where p.user_id = o.id) end,
         (select avatar_url from ft_profiles p where p.user_id = o.id),
         coalesce(f.accepted_at, f.created_at)
    from ft_friends f, lateral (select case when f.a = auth.uid() then f.b else f.a end id) o
   where auth.uid() in (f.a, f.b);
$$;


-- ── direct + group messages ─────────────────────────────────────────────────
create table if not exists ft_threads (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('dm','group')),
  name       text check (name is null or char_length(trim(name)) between 1 and 40),
  dm_key     text unique,                               -- 'a:b' for a direct chat (a < b)
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists ft_thread_members (
  thread_id    uuid not null references ft_threads(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  joined_at    timestamptz not null default now(),
  last_read_at timestamptz not null default now(),
  muted        boolean not null default false,
  primary key (thread_id, user_id)
);
create index if not exists ft_thread_members_user on ft_thread_members (user_id);
create table if not exists ft_messages (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references ft_threads(id) on delete cascade,
  user_id    uuid references auth.users(id) on delete set null,
  body       text not null check (char_length(trim(body)) between 1 and 1000),
  created_at timestamptz not null default now(),
  edited_at  timestamptz,
  deleted    boolean not null default false
);
create index if not exists ft_messages_thread on ft_messages (thread_id, created_at);

create or replace function ft_in_thread(p_thread uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ft_thread_members where thread_id = p_thread and user_id = auth.uid());
$$;

alter table ft_threads        enable row level security;
alter table ft_thread_members enable row level security;
alter table ft_messages       enable row level security;
drop policy if exists ft_threads_read on ft_threads;
drop policy if exists ft_thread_members_read on ft_thread_members;
drop policy if exists ft_messages_read on ft_messages;
create policy ft_threads_read        on ft_threads        for select to authenticated using (ft_in_thread(id));
create policy ft_thread_members_read on ft_thread_members for select to authenticated using (ft_in_thread(thread_id));
create policy ft_messages_read       on ft_messages       for select to authenticated using (ft_in_thread(thread_id));

do $$
declare t text;
begin
  foreach t in array array['ft_messages','ft_thread_members','ft_friends'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = t) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;

-- open (or start) a direct chat with a friend
create or replace function ft_dm_open(p_user uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v_key text; v_id uuid;
begin
  if not ft_are_friends(me, p_user) then raise exception 'You can only message friends.'; end if;
  v_key := least(me, p_user)::text || ':' || greatest(me, p_user)::text;
  select id into v_id from ft_threads where dm_key = v_key;
  if v_id is null then
    insert into ft_threads (kind, dm_key, created_by) values ('dm', v_key, me) returning id into v_id;
    insert into ft_thread_members (thread_id, user_id) values (v_id, me), (v_id, p_user);
  end if;
  return v_id;
end $$;

-- start a group with some of your friends
create or replace function ft_group_create(p_name text, p_users uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v_id uuid; u uuid;
begin
  if coalesce(char_length(trim(p_name)), 0) not between 1 and 40 then raise exception 'Give the group a name (up to 40 characters).'; end if;
  if coalesce(cardinality(p_users), 0) < 1 then raise exception 'Pick at least one friend.'; end if;
  foreach u in array p_users loop
    if not ft_are_friends(me, u) then raise exception 'You can only add friends to a group.'; end if;
  end loop;
  insert into ft_threads (kind, name, created_by) values ('group', trim(p_name), me) returning id into v_id;
  insert into ft_thread_members (thread_id, user_id) select v_id, x from unnest(array_append(p_users, me)) x on conflict do nothing;
  return v_id;
end $$;

-- add one of your friends to a group you're in
create or replace function ft_group_add(p_thread uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from ft_threads where id = p_thread and kind = 'group') or not ft_in_thread(p_thread) then raise exception 'Not your group.'; end if;
  if not ft_are_friends(auth.uid(), p_user) then raise exception 'You can only add your friends.'; end if;
  insert into ft_thread_members (thread_id, user_id) values (p_thread, p_user) on conflict do nothing;
end $$;

create or replace function ft_group_rename(p_thread uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ft_in_thread(p_thread) then raise exception 'Not your group.'; end if;
  if coalesce(char_length(trim(p_name)), 0) not between 1 and 40 then raise exception 'Up to 40 characters.'; end if;
  update ft_threads set name = trim(p_name) where id = p_thread and kind = 'group';
end $$;

-- leave a group. If you owned it, it passes to whoever's been in longest; the last one out turns off the lights
create or replace function ft_group_leave(p_thread uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from ft_thread_members where thread_id = p_thread and user_id = auth.uid()
     and exists (select 1 from ft_threads where id = p_thread and kind = 'group');
  update ft_threads t set created_by = (select m.user_id from ft_thread_members m where m.thread_id = t.id order by m.joined_at, m.user_id limit 1)
   where t.id = p_thread and t.kind = 'group' and t.created_by = auth.uid();
  delete from ft_threads t where t.id = p_thread and t.kind = 'group' and not exists (select 1 from ft_thread_members m where m.thread_id = t.id);
end $$;

-- the group's owner (whoever created it, or inherited it) can remove someone
create or replace function ft_group_remove(p_thread uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from ft_threads where id = p_thread and kind = 'group' and created_by = auth.uid()) then
    raise exception 'Only the group’s owner can remove people.';
  end if;
  if p_user = auth.uid() then raise exception 'To leave, use Leave group.'; end if;
  delete from ft_thread_members where thread_id = p_thread and user_id = p_user;
end $$;

create or replace function ft_thread_mute(p_thread uuid, p_muted boolean) returns void
language sql security definer set search_path = public as $$
  update ft_thread_members set muted = coalesce(p_muted, false) where thread_id = p_thread and user_id = auth.uid();
$$;

create or replace function ft_send_message(p_thread uuid, p_body text) returns ft_messages
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v_t ft_threads; v ft_messages; v_other uuid;
begin
  select * into v_t from ft_threads where id = p_thread;
  if v_t.id is null or not ft_in_thread(p_thread) then raise exception 'You’re not in that chat.'; end if;
  if v_t.kind = 'dm' then
    select user_id into v_other from ft_thread_members where thread_id = p_thread and user_id <> me;
    if not ft_are_friends(me, v_other) then raise exception 'You’re no longer friends.'; end if;
  end if;
  if coalesce(char_length(trim(p_body)), 0) not between 1 and 1000 then raise exception 'Messages are 1 to 1000 characters.'; end if;
  insert into ft_messages (thread_id, user_id, body) values (p_thread, me, trim(p_body)) returning * into v;
  update ft_thread_members set last_read_at = now() where thread_id = p_thread and user_id = me;
  return v;
end $$;

create or replace function ft_edit_message(p_id uuid, p_body text) returns ft_messages
language plpgsql security definer set search_path = public as $$
declare v ft_messages;
begin
  if coalesce(char_length(trim(p_body)), 0) not between 1 and 1000 then raise exception 'Messages are 1 to 1000 characters.'; end if;
  update ft_messages set body = trim(p_body), edited_at = now() where id = p_id and user_id = auth.uid() and not deleted returning * into v;
  if v is null then raise exception 'You can only edit your own messages.'; end if;
  return v;
end $$;

create or replace function ft_delete_message(p_id uuid) returns ft_messages
language plpgsql security definer set search_path = public as $$
declare v ft_messages;
begin
  update ft_messages set deleted = true, body = '·', edited_at = null where id = p_id and user_id = auth.uid() and not deleted returning * into v;
  if v is null then raise exception 'You can only delete your own messages.'; end if;
  return v;
end $$;

create or replace function ft_thread_read(p_thread uuid) returns void
language sql security definer set search_path = public as $$
  update ft_thread_members set last_read_at = now() where thread_id = p_thread and user_id = auth.uid();
$$;

-- your chats: who's in each, the last message and how many you haven't read
drop function if exists ft_my_threads();
create or replace function ft_my_threads() returns table (id uuid, kind text, name text, owner uuid, members jsonb, muted boolean,
                                                           last_body text, last_user uuid, last_at timestamptz, last_deleted boolean,
                                                           unread int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select t.id, t.kind, t.name, t.created_by,
         (select jsonb_agg(jsonb_build_object('user_id', m2.user_id, 'known_as', ft_known_as(m2.user_id),
                   'real_name', case when m2.user_id = auth.uid() or ft_are_friends(auth.uid(), m2.user_id)
                                     then (select real_name from ft_people p where p.user_id = m2.user_id) end,
                   'avatar_url', (select avatar_url from ft_profiles p where p.user_id = m2.user_id)) order by m2.joined_at)
            from ft_thread_members m2 where m2.thread_id = t.id),
         me.muted, l.body, l.user_id, l.created_at, l.deleted,
         (select count(*)::int from ft_messages x where x.thread_id = t.id and x.created_at > me.last_read_at and x.user_id is distinct from auth.uid()),
         t.created_at
    from ft_thread_members me join ft_threads t on t.id = me.thread_id
    left join lateral (select body, user_id, created_at, deleted from ft_messages x where x.thread_id = t.id order by created_at desc limit 1) l on true
   where me.user_id = auth.uid()
   order by coalesce(l.created_at, t.created_at) desc;
$$;


-- ── notifications ───────────────────────────────────────────────────────────
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
           when p_kind in ('achievements','results','reminders','social','joins','friends','dm','friend_bets')
                                        then coalesce((p.prefs->>p_kind)::boolean, true)
           else false end
    from (select coalesce((select prefs from ft_profiles where user_id = p_user), '{}'::jsonb) prefs) p;
$$;

-- direct messages skip quiet hours, like chat
create or replace function ft_push_enqueue(p_user uuid, p_kind text, p_key text, p_title text, p_body text, p_url text, p_tag text default null)
returns void language plpgsql set search_path = public as $$
begin
  if p_user is null or not ft_push_wants(p_user, p_kind, p_key) then return; end if;
  insert into ft_push_queue (user_id, title, body, url, tag, send_after)
  values (p_user, p_title, coalesce(p_body, ''), coalesce(p_url, './'), p_tag,
          case when p_kind like 'chat\_%' or p_kind = 'dm' then now() else ft_push_quiet_until(p_user) end);
end $$;

-- friend requests and accepts
create or replace function ft_push_friends() returns trigger
language plpgsql set search_path = public as $$
declare v_to uuid; v_from uuid;
begin
  begin
    if tg_op = 'INSERT' and new.status = 'pending' then
      v_from := new.requested_by; v_to := case when new.a = v_from then new.b else new.a end;
      perform ft_push_enqueue(v_to, 'friends', null, '🤝 Friend request', format('%s wants to be friends', ft_known_as(v_from)),
        './?friends=1', 'friend-' || v_from);
    elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'accepted' then
      v_to := new.requested_by; v_from := case when new.a = v_to then new.b else new.a end;
      perform ft_push_enqueue(v_to, 'friends', null, '🤝 You’re now friends', format('%s accepted your friend request', ft_known_as(v_from)),
        './?friends=1', 'friend-' || v_from);
    end if;
  exception when others then raise warning 'push (friends): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_friends on ft_friends;
create trigger ft_push_friends after insert or update on ft_friends for each row execute function ft_push_friends();

-- a message in one of your chats (not yours, not muted)
create or replace function ft_push_messages() returns trigger
language plpgsql set search_path = public as $$
declare v_t ft_threads; v_name text;
begin
  begin
    select * into v_t from ft_threads where id = new.thread_id;
    v_name := ft_known_as(new.user_id);
    perform ft_push_enqueue(m.user_id, 'dm', null,
      case when v_t.kind = 'group' then format('💬 %s · %s', v_name, v_t.name) else format('💬 %s', v_name) end,
      left(new.body, 140), './?thread=' || new.thread_id, 'thread-' || new.thread_id)
      from ft_thread_members m where m.thread_id = new.thread_id and m.user_id is distinct from new.user_id and not m.muted;
  exception when others then raise warning 'push (message): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_messages on ft_messages;
create trigger ft_push_messages after insert on ft_messages for each row execute function ft_push_messages();

-- a friend you follow placed a bet in a comp you share (hidden bets stay hidden)
create or replace function ft_push_friend_bet() returns trigger
language plpgsql set search_path = public as $$
declare v_comp text; v_name text;
begin
  begin
    if new.hidden then return null; end if;
    select name into v_comp from ft_comps where id = new.comp_id;
    select username into v_name from ft_members where comp_id = new.comp_id and user_id = new.user_id;
    perform ft_push_enqueue(f.fan, 'friend_bets', null,
      format('🎯 %s placed a %s', coalesce(v_name, 'A friend'), ft_bet_label(new)),
      format('%s @ %s · %s', ft_money(new.stake), new.price, v_comp),
      './?comp=' || new.comp_id || '&player=' || new.user_id, 'fbet-' || new.id)
      from (select case when x.a = new.user_id then x.b else x.a end fan
              from ft_friends x
             where x.status = 'accepted' and new.user_id in (x.a, x.b)
               and case when x.a = new.user_id then x.notify_b else x.notify_a end) f
     where exists (select 1 from ft_members m where m.comp_id = new.comp_id and m.user_id = f.fan);
  exception when others then raise warning 'push (friend bet): %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists ft_push_friend_bet on ft_bets;
create trigger ft_push_friend_bet after insert on ft_bets for each row execute function ft_push_friend_bet();


-- ── who can call what ──
do $$
declare f text;
begin
  foreach f in array array['ft_edit_chat(uuid,text)', 'ft_delete_chat(uuid)', 'ft_set_avatar(text)', 'ft_set_real_name(text)',
                           'ft_friend_request(uuid)', 'ft_friend_respond(uuid,boolean)', 'ft_friend_remove(uuid)', 'ft_friend_notify(uuid,boolean)',
                           'ft_person(uuid)', 'ft_my_friends()', 'ft_dm_open(uuid)', 'ft_group_create(text,uuid[])', 'ft_group_add(uuid,uuid)',
                           'ft_group_rename(uuid,text)', 'ft_group_leave(uuid)', 'ft_group_remove(uuid,uuid)', 'ft_thread_mute(uuid,boolean)', 'ft_send_message(uuid,text)',
                           'ft_edit_message(uuid,text)', 'ft_delete_message(uuid)', 'ft_thread_read(uuid)', 'ft_my_threads()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['ft_push_enqueue(uuid,text,text,text,text,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
