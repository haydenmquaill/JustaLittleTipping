-- ════════════════════════════════════════════════════════════════════════════
-- 002 — chat messages carry the sender's comp name
-- The sport and global rooms show where a message came from ("Gazza · Quaill Family
-- Tipping"), but players can't read other comps' rows. So the name is stamped on the
-- message when it's sent — the same way the username already is.
-- Run after schema.sql. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

alter table ft_chats add column if not exists comp_name text not null default '';

-- post as your username in p_comp; p_room is 'comp', 'sport' or 'global'
create or replace function ft_send_chat(p_comp uuid, p_body text, p_room text default 'comp') returns ft_chats
language plpgsql security definer set search_path = public as $$
declare
  v_name  text;
  v_sport text;
  v_comp  text;
  v_row   ft_chats;
begin
  select m.username, c.sport, c.name into v_name, v_sport, v_comp
    from ft_members m join ft_comps c on c.id = m.comp_id
   where m.comp_id = p_comp and m.user_id = auth.uid();
  if v_name is null then raise exception 'not a member of this comp'; end if;
  if coalesce(p_room,'comp') not in ('comp','sport','global') then raise exception 'unknown chat room'; end if;
  insert into ft_chats (comp_id, user_id, username, body, room, sport, comp_name)
  values (p_comp, auth.uid(), v_name, left(trim(p_body), 280), coalesce(p_room,'comp'), v_sport, v_comp)
  returning * into v_row;
  return v_row;
end $$;

revoke all on function ft_send_chat(uuid,text,text) from public, anon;
grant execute on function ft_send_chat(uuid,text,text) to authenticated;
