-- ════════════════════════════════════════════════════════════════════════════
-- 007 — player view: hide-until-settled and Tail
--
--   ft_bets.hidden   the punter's choice to keep a pending bet to themselves. Other members see
--                    every bet (pending ones too) unless it's hidden; once a bet settles it's
--                    visible regardless, so Key Moments stays honest.
--   ft_bets.tail_of  the bet this one copied (Tail button), for Copycat / Tipster achievements later.
--   ft_hide_bet()    hide or unhide one of your pending bets.
--   ft_place_bets()  now takes { hidden, tail_of } per bet.
--
-- Run after 006. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

alter table ft_bets add column if not exists hidden  boolean not null default false;
alter table ft_bets add column if not exists tail_of uuid references ft_bets(id) on delete set null;

-- your own bets, plus other members' bets unless they're pending and hidden
drop policy if exists ft_bets_read on ft_bets;
create policy ft_bets_read on ft_bets for select to authenticated
  using (user_id = auth.uid() or (ft_is_member(comp_id) and (status <> 'pending' or not hidden)));

-- hide / unhide one of your pending bets
create or replace function ft_hide_bet(p_bet uuid, p_hidden boolean) returns ft_bets
language plpgsql security definer set search_path = public as $$
declare v ft_bets;
begin
  update ft_bets set hidden = coalesce(p_hidden, false)
   where id = p_bet and user_id = auth.uid() and status = 'pending'
  returning * into v;
  if v is null then raise exception 'Only your own pending bets can be hidden.'; end if;
  return v;
end $$;

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
  v_legs jsonb; v_matches text[]; v_keys text[]; v_key text; v_round int; v_tail uuid;
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

    -- tailing: must be someone else's bet in this comp; anything else is just ignored
    select id into v_tail from ft_bets where id = (case when (b->>'tail_of') ~ '^[0-9a-f-]{36}$' then (b->>'tail_of')::uuid end)
       and comp_id = p_comp and user_id <> auth.uid();
    insert into ft_bets (comp_id, user_id, kind, legs, stake, price, potential_payout, round, hidden, tail_of)
    values (p_comp, auth.uid(), v_kind, v_legs, v_stake, v_price, round(v_stake * v_price, 2), v_round,
            coalesce((b->>'hidden')::boolean, false), v_tail);
  end loop;

  update ft_members set balance = balance - v_total
   where comp_id = p_comp and user_id = auth.uid()
  returning balance into v_member.balance;
  return v_member.balance;
end $$;


-- ── who can call what (006's new functions included) ──
do $$
declare f text;
begin
  foreach f in array array['ft_hide_bet(uuid,boolean)', 'ft_place_bets(uuid,jsonb)', 'ft_find_comp(text)', 'ft_set_team(text,text,int)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
