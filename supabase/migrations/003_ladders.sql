-- ════════════════════════════════════════════════════════════════════════════
-- 003 — competition ladders
-- The official AFL / NRL ladder, one row per sport, season and round, written by the
-- fixture importer from the match-centre feeds (so it's right even for games we
-- haven't imported). The page shows the latest round's.
-- Run after 002. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists ft_ladders (
  sport       text not null check (sport in ('afl','nrl')),
  season      int  not null,
  round       int  not null,                      -- the ladder after this round
  -- [ { pos, team, played, won, lost, drawn, byes, pf, pa, pct, diff, pts, form:['W','L',…], move, next }, … ]
  rows        jsonb not null,
  updated_at  timestamptz not null default now(),
  primary key (sport, season, round)
);

alter table ft_ladders enable row level security;
drop policy if exists ft_ladders_read on ft_ladders;
create policy ft_ladders_read on ft_ladders for select to authenticated using (true);
