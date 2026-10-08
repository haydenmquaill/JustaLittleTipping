-- ════════════════════════════════════════════════════════════════════════════
-- 014 — real quarter lengths for the worm
--
--   ft_matches.live.plen   the length (s) of each period that has finished, so the worm can size
--                          its columns to the time actually played
--   ft_replay_tick()       005's version, plus plen
--
-- Run after 013. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

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
                             'home', hcum, 'away', acum, 'events', evs, 'players', pl,
                             -- finished periods only (the current one too once it's at the break)
                             'plen', (select coalesce(jsonb_agg(x order by i), '[]') from jsonb_array_elements(r.plen) with ordinality t(x, i)
                                       where done or i < q or (i = q and not run)));
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

-- finished replay matches get their lengths too
update ft_matches m set live = m.live || jsonb_build_object('plen', s.plen)
  from ft_replay_src s
 where s.match_id = m.id and m.status = 'concluded' and m.live is not null;
