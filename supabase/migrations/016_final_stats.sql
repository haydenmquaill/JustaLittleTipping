-- ════════════════════════════════════════════════════════════════════════════
-- 016 — no estimated stats: player and team stats show once they're real
--
--   ft_replay_src.extra    each team's match totals, possession and scoring breakdown (AFL), from the builder
--   live.players           during play: who's playing (name, team, jumper, photo) and their goals / behinds /
--                          tries, counted from the scores. Every other stat arrives at full time.
--   live.final             the team stats (extra), at full time
--   live.inter             interchanges per quarter, for the quarters that have finished
--   ft_replay_final()      the full-time additions to live, shared with the stats update script
--   ft_replay_tick()       014's version without the scaled-down player stats
--
-- Player markets other than goals / tries now settle at full time. Run after 015. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

alter table ft_replay_src add column if not exists extra jsonb;

-- what a finished replay adds to live: everyone's stats, and the team stats
create or replace function ft_replay_final(s ft_replay_src) returns jsonb
language sql stable as $$
  select jsonb_build_object('players', s.players, 'final', s.extra,
    'inter', case when s.extra is null then null
                  else jsonb_build_object('home', s.extra->'home'->'ic', 'away', s.extra->'away'->'ic', 'cap', s.extra->'cap') end);
$$;

create or replace function ft_replay_tick() returns int
language plpgsql set search_path = public as $$
declare
  r record;
  n int; q int; clk float8; done boolean; e float8; per float8; brk float8;
  evs jsonb; hcum jsonb; acum jsonb; hs int; as_ int; hg int; hb int; ag int; ab int; k int; pl jsonb; cnt int := 0;
  run boolean; st text; nl jsonb; fin int; inter jsonb;
begin
  for r in
    select m.id, m.sport, m.commence_time, m.status, m.home_score, m.away_score, m.live, m.updated_at,
           s.plen, s.brk, s.events, s.players, s.extra
      from ft_matches m join ft_replay_src s on s.match_id = m.id
     where m.status <> 'concluded' and m.commence_time <= now()
  loop
    -- where the game is up to: walk the periods and breaks from the bounce
    n := jsonb_array_length(r.plen);
    e := extract(epoch from now() - r.commence_time);
    q := 1; clk := 0; done := false; run := false;
    loop
      per := (r.plen->>(q-1))::float8;
      if e < per then clk := e; run := true; exit; end if;
      e := e - per;
      if q = n then done := true; clk := per; exit; end if;
      brk := (r.brk->>(q-1))::float8;
      if e < brk then clk := per; exit; end if;           -- at the break: clock held at the end of the period
      e := e - brk; q := q + 1;
    end loop;

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

    -- players during play: who they are, and their scores so far (exact, from the scoring events)
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('name', p->'name', 'team', p->'team', 'n', p->'n', 'photo', p->'photo',
             'g',  case when r.sport = 'afl' then (select count(*) from jsonb_array_elements(evs) x
                     where x->>'player' = p->>'name' and x->>'team' = p->>'team' and x->>'type' = 'goal') end,
             'b',  case when r.sport = 'afl' then (select count(*) from jsonb_array_elements(evs) x
                     where x->>'player' = p->>'name' and x->>'team' = p->>'team' and x->>'type' = 'behind') end,
             'tr', case when r.sport = 'nrl' then (select count(*) from jsonb_array_elements(evs) x
                     where x->>'player' = p->>'name' and x->>'team' = p->>'team' and x->>'type' = 'try') end))), '[]')
      into pl
      from jsonb_array_elements(r.players) p;

    -- interchanges for the quarters that have finished (the current one too once it's at the break)
    fin := case when done then n when run then q - 1 else q end;
    inter := case when r.extra is null then null else jsonb_build_object(
      'home', (select coalesce(jsonb_agg(x order by i), '[]') from jsonb_array_elements(r.extra->'home'->'ic') with ordinality t(x, i) where i <= fin),
      'away', (select coalesce(jsonb_agg(x order by i), '[]') from jsonb_array_elements(r.extra->'away'->'ic') with ordinality t(x, i) where i <= fin),
      'cap', r.extra->'cap') end;

    -- running: the clock is going (false at the breaks and after the siren); at: when clockSecs was read
    st := case when done then 'concluded' else 'live' end;
    nl := jsonb_build_object('q', q, 'clockSecs', round(clk), 'running', run, 'at', round(extract(epoch from now())::numeric, 1),
                             'home', hcum, 'away', acum, 'events', evs, 'players', pl, 'inter', inter,
                             -- finished periods only (the current one too once it's at the break)
                             'plen', (select coalesce(jsonb_agg(x order by i), '[]') from jsonb_array_elements(r.plen) with ordinality t(x, i)
                                       where done or i < q or (i = q and not run)));
    if done then nl := nl || ft_replay_final((select s from ft_replay_src s where s.match_id = r.id)); end if;
    if st is distinct from r.status or hs is distinct from r.home_score or as_ is distinct from r.away_score
       or (nl - 'clockSecs' - 'at') is distinct from (coalesce(r.live, '{}') - 'clockSecs' - 'at')
    then
      update ft_matches set status = st, home_score = hs, away_score = as_, live = nl, updated_at = now() where id = r.id;
      cnt := cnt + 1;
    end if;
  end loop;
  return cnt;
end $$;
