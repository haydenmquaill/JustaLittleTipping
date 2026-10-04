<#
  JALF Footy Tipping - replay builder
  -----------------------------------
  Builds replay_seed.sql: two real 2025 rounds of AFL and NRL, moved forward so they start
  on -Start (a Thursday), ready to be played back live by the replay clock (migration 005).

  It downloads, from the official match centres:
    * the fixture and final results            -> ft_matches (season 2027, rounds 1-2, shifted dates)
    * every scoring event and player's stats   -> ft_replay_src (played back by the replay clock)
    * the ladder before and after each round   -> ft_ladders (round 0 now) / ft_replay_ladders (published as rounds finish)
  and generates odds for every match           -> ft_odds
    * head to head, line, totals, quarters/halves from each team's ladder record BEFORE the round
    * player markets from each player's stats in the two rounds BEFORE (so nothing gives the result away)

  Usage (from this folder):   powershell -ExecutionPolicy Bypass -File .\build-replay.ps1 [-Start 2026-10-08]
  Then run replay_seed.sql in the Supabase SQL editor. Re-running replaces the previous replay.
#>
param(
  [string]$Start = '2026-10-08',            # Melbourne-local date the first replay round starts (a Thursday)
  [int]$AflFrom = 20,                       # 2025 AFL rounds to replay: $AflFrom and the one after
  [int]$NrlFrom = 20                        # 2025 NRL rounds to replay: $NrlFrom and the one after
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Season = 2027                              # the season the replay is filed under (matches the page's SEASON)
$out = Join-Path $PSScriptRoot 'replay_seed.sql'
$tz = [TimeZoneInfo]::FindSystemTimeZoneById('AUS Eastern Standard Time')
$UA = 'Mozilla/5.0'
function Get-Json($url, $headers = @{}){ Invoke-RestMethod -Uri $url -Headers $headers -UserAgent $UA }

# -- maths for the odds ---------------------------------------------------------
function NCdf([double]$x){ $z = [Math]::Abs($x)/[Math]::Sqrt(2); $t = 1/(1+0.3275911*$z)
  $y = 1 - (((((1.061405429*$t - 1.453152027)*$t) + 1.421413741)*$t - 0.284496736)*$t + 0.254829592)*$t*[Math]::Exp(-$z*$z)
  if($x -ge 0){ (1+$y)/2 } else { (1-$y)/2 } }
function PoisGE([double]$lam, [int]$k){ if($k -le 0){ return 1.0 }; $term = [Math]::Exp(-$lam); $s = $term
  for($i=1; $i -lt $k; $i++){ $term *= $lam/$i; $s += $term }; [Math]::Max(0.0, 1.0 - $s) }   # 0.0 not 0: an int Max rounds the result
# a price with a bookie's margin baked in (implied chance x overround), kept in a sensible range
function Px([double]$p, [double]$over = 1.07, [double]$max = 101){
  $p = [Math]::Min(0.97, [Math]::Max(0.005, $p)); [Math]::Round([Math]::Min($max, [Math]::Max(1.01, 1/($p*$over))), 2) }
function Half([double]$x){ [Math]::Floor($x) + 0.5 }        # nearest .5 line below, so there's never a push
# an Over/Under pair at a line, optionally for one team (team totals)
function OU($pt, $team){
  $o = [ordered]@{ name='Over'; point=$pt; price=1.87 }; $u = [ordered]@{ name='Under'; point=$pt; price=1.93 }
  if($team){ $o.description = $team; $u.description = $team }
  @($o, $u) }
# both feeds' timestamps -> a UTC DateTime ("2025-07-24T09:30:00.000+0000" and "2025-07-17T09:50:00Z")
function ParseUtc([string]$s){ [DateTimeOffset]::Parse(($s -replace '\+0000$', 'Z')).UtcDateTime }

# -- dates: same Melbourne local day and time, whole weeks later ----------------
function ToLocal([datetime]$utc){ [TimeZoneInfo]::ConvertTimeFromUtc($utc.ToUniversalTime(), $tz) }
function ShiftUtc([datetime]$utc, [int]$days){
  $loc = (ToLocal $utc).AddDays($days)
  [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($loc, 'Unspecified'), $tz) }
function WeeksTo([datetime]$firstUtc){
  $first = (ToLocal $firstUtc).Date; $target = [datetime]::ParseExact($Start, 'yyyy-MM-dd', $null)
  7 * [Math]::Ceiling(($target - $first).TotalDays / 7) }

# -- SQL helpers ----------------------------------------------------------------
function Q($s){ if($null -eq $s){ 'null' } else { "'" + ([string]$s).Replace("'", "''") + "'" } }
function J($o){ Q ($o | ConvertTo-Json -Depth 10 -Compress) }

$allMatches = New-Object System.Collections.Generic.List[object]  # { row, odds, src }  (not $matches: PowerShell owns that name)
$ladders = New-Object System.Collections.Generic.List[object]     # { sport, round, rows }

# ============================================================================
#  AFL
# ============================================================================
Write-Host 'AFL: fixture...'
$aflAll = (Get-Json 'https://aflapi.afl.com.au/afl/v2/matches?compSeasonId=73&pageSize=300').matches
$tok = (Invoke-RestMethod -Method Post -Uri 'https://api.afl.com.au/cfs/afl/WMCTok' -Body '' -UserAgent $UA).token
$H = @{ 'x-media-mis-token' = $tok }
function AflPlayers($id){
  $ps = Get-Json "https://api.afl.com.au/cfs/afl/playerStats/match/$id" $H
  $rows = @()
  foreach($side in 'home','away'){
    foreach($p in $ps."${side}TeamPlayerStats"){
      $n = $p.player.player.player.playerName; $s = $p.playerStats.stats
      $rows += [ordered]@{ name = "$($n.givenName) $($n.surname)"; team = $side
        d = [int]$s.disposals; k = [int]$s.kicks; h = [int]$s.handballs; m = [int]$s.marks; t = [int]$s.tackles
        g = [int]$s.goals; b = [int]$s.behinds; af = [int]$s.dreamTeamPoints; cl = [int]$s.clearances.totalClearances }
    } }
  $rows }
# players' averages over a set of rounds (by name)
function Averages($list){
  $acc = @{}
  foreach($p in $list){ if(-not $acc.ContainsKey($p.name)){ $acc[$p.name] = @() }; $acc[$p.name] += ,$p }
  $avg = @{}
  foreach($k in $acc.Keys){ $g = $acc[$k]; $a = @{}
    foreach($f in $g[0].Keys){ if($f -notin 'name','team'){ $a[$f] = ($g | ForEach-Object { [double]$_[$f] } | Measure-Object -Average).Average } }
    $avg[$k] = $a }
  $avg }
function AflLadder($roundId){
  $l = Get-Json "https://aflapi.afl.com.au/afl/v2/compseasons/73/ladders?roundId=$roundId"
  @($l.ladders[0].entries | ForEach-Object {
    $r = $_.thisSeasonRecord; $w = $r.winLossRecord
    $form = @(([string]$_.form).ToCharArray() | Where-Object { $_ -in 'W','L','D' } | ForEach-Object { [string]$_ })
    [ordered]@{ pos = [int]$_.position; team = $_.team.name; played = [int]$w.played; won = [int]$w.wins; lost = [int]$w.losses
      drawn = [int]$w.draws; byes = 0; pf = [int]$_.pointsFor; pa = [int]$_.pointsAgainst; pct = [double]$r.percentage
      diff = [int]$_.pointsFor - [int]$_.pointsAgainst; pts = [int]$r.aggregatePoints
      form = @($form | Select-Object -Last 5)
      move = $(switch([string]$_.positionChange){ 'UP' { 1 } 'DOWN' { -1 } default { 0 } }); next = $_.nextOpponent.name } }) }

# -- AFL odds --
function AflOdds($hTeam, $aTeam, $ladder, $players, $avg){
  $lh = $ladder | Where-Object { $_.team -eq $hTeam }; $la = $ladder | Where-Object { $_.team -eq $aTeam }
  $pg = { param($x) [Math]::Max(1, $x.played) }
  # expected margin from the percentage gap, plus a small home edge; spread ~ 37 points
  $mu = ($lh.pct - $la.pct)*0.45 + 4
  $ph = NCdf ($mu/37)
  $tot = (($lh.pf/(& $pg $lh)) + ($la.pa/(& $pg $la)) + ($la.pf/(& $pg $la)) + ($lh.pa/(& $pg $lh)))/2
  $line = Half([Math]::Abs($mu)); $hp = $(if($mu -ge 0){ -$line } else { $line })
  $T = Half $tot; $th = Half ($tot/2 + $mu/2); $ta = Half ($tot/2 - $mu/2)
  $ou = { param($pt, $extra) OU $pt $extra }
  $mk = [ordered]@{
    h2h      = @([ordered]@{ name=$hTeam; price=(Px $ph) }, [ordered]@{ name=$aTeam; price=(Px (1-$ph)) })
    spreads  = @([ordered]@{ name=$hTeam; point=$hp; price=1.90 }, [ordered]@{ name=$aTeam; point=-$hp; price=1.90 })
    totals   = (& $ou $T $null)
    team_totals = @((& $ou $th $hTeam) + (& $ou $ta $aTeam))
    h2h_q1   = @([ordered]@{ name=$hTeam; price=(Px (NCdf ($mu/4/18.5))) }, [ordered]@{ name=$aTeam; price=(Px (1-(NCdf ($mu/4/18.5)))) })
    totals_q1 = (& $ou (Half ($tot/4)) $null)
    h2h_h1   = @([ordered]@{ name=$hTeam; price=(Px (NCdf ($mu/2/26))) }, [ordered]@{ name=$aTeam; price=(Px (1-(NCdf ($mu/2/26)))) })
    totals_h1 = (& $ou (Half ($tot/2)) $null)
  }
  # player markets from the last two rounds (players with no recent games just get scorer markets)
  $plist = @($players | ForEach-Object { $a = $avg[$_.name]; [ordered]@{ name=$_.name; a=$a } })
  $lamG = @{}; foreach($p in $plist){ $lamG[$p.name] = $(if($p.a){ [Math]::Max(0.06, $p.a.g) } else { 0.15 }) }
  $sumG = ($lamG.Values | Measure-Object -Sum).Sum
  $mk.player_goal_scorer_first = @($plist | ForEach-Object { [ordered]@{ name='Yes'; description=$_.name; price=(Px ($lamG[$_.name]/$sumG) 1.25 151) } })
  $mk.player_goal_scorer_anytime = @($plist | ForEach-Object { [ordered]@{ name='Yes'; description=$_.name; price=(Px (1-[Math]::Exp(-$lamG[$_.name])) 1.10 26) } })
  $overs = { param($stat, $thresholds, $minAvg, $sdF, $sdC)
    @($plist | Where-Object { $_.a -and $_.a[$stat] -ge $minAvg } | ForEach-Object { $p = $_; $m = $p.a[$stat]
      foreach($k in $thresholds){
        $pr = $(if($sdF -gt 0){ 1 - (NCdf (($k - 0.5 - $m)/($sdF*$m + $sdC))) } else { PoisGE $m $k })
        if($pr -ge 0.05 -and $pr -le 0.93){ [ordered]@{ name='Over'; description=$p.name; point=($k-0.5); price=(Px $pr 1.08 34) } } } }) }
  $mk.player_goals_scored_over      = & $overs 'g'  @(2,3,4)          0.5 0 0
  $mk.player_disposals_over         = & $overs 'd'  @(15,20,25,30,35) 13  0.22 2
  $mk.player_kicks_over             = & $overs 'k'  @(10,15,20)       8   0.25 1.5
  $mk.player_handballs_over         = & $overs 'h'  @(10,15,20)       8   0.25 1.5
  $mk.player_marks_over             = & $overs 'm'  @(4,6,8)          3   0 0
  $mk.player_tackles_over           = & $overs 't'  @(3,5,7)          2.5 0 0
  $mk.player_clearances_over        = & $overs 'cl' @(3,5,7)          2   0 0
  $mk.player_afl_fantasy_points_over = & $overs 'af' @(70,90,110,130) 60  0.2 8
  $top = @($plist | Where-Object { $_.a } | Sort-Object { -$_.a.d } | Select-Object -First 10)
  $mk.player_disposals = @($top | ForEach-Object { $l = Half $_.a.d
    [ordered]@{ name='Over'; description=$_.name; point=$l; price=1.87 }, [ordered]@{ name='Under'; description=$_.name; point=$l; price=1.93 } })
  foreach($pair in @(@('player_marks_most','m'), @('player_tackles_most','t'))){
    $cand = @($plist | Where-Object { $_.a } | Sort-Object { -$_.a[$pair[1]] } | Select-Object -First 12)
    $w = @{}; foreach($c in $cand){ $w[$c.name] = [Math]::Pow([Math]::Max(0.5, $c.a[$pair[1]]), 4) }
    $sw = ($w.Values | Measure-Object -Sum).Sum
    $mk[$pair[0]] = @($cand | ForEach-Object { [ordered]@{ name='Yes'; description=$_.name; price=(Px ($w[$_.name]/$sw) 1.2 51) } }) }
  # drop empty markets
  $clean = [ordered]@{}; foreach($k in $mk.Keys){ $vals = @($mk[$k] | Where-Object { $_ }); if($vals.Count){ $clean[$k] = $vals } }
  $clean }

$aflRounds = @($AflFrom, ($AflFrom+1))
$aflFirst = ($aflAll | Where-Object { $_.round.roundNumber -eq $AflFrom } | ForEach-Object { ParseUtc $_.utcStartTime } | Measure-Object -Minimum).Minimum
$aflDays = WeeksTo $aflFirst
foreach($ri in 0..1){
  $rn = $aflRounds[$ri]; $replayRound = $ri + 1
  $games = @($aflAll | Where-Object { $_.round.roundNumber -eq $rn } | Sort-Object utcStartTime)
  $roundId = $games[0].round.id
  Write-Host "AFL: 2025 round $rn -> replay round $replayRound ($($games.Count) games)"
  # form before the round: the ladder after the previous round, and players' last two rounds
  $pre = AflLadder ($roundId - 1)
  if($ri -eq 0){ $ladders.Add(@{ sport='afl'; round=0; rows=$pre; now=$true }) }
  $ladders.Add(@{ sport='afl'; round=$replayRound; rows=(AflLadder $roundId) })
  $hist = @()
  foreach($prev in ($rn-2),($rn-1)){
    foreach($pm in ($aflAll | Where-Object { $_.round.roundNumber -eq $prev })){ $hist += AflPlayers $pm.providerId } }
  $avg = Averages $hist
  foreach($g in $games){
    $id = $g.providerId
    $item = Get-Json "https://api.afl.com.au/cfs/afl/matchItem/$id" $H
    $events = @($item.scoringEvents | ForEach-Object {
      $n = $_.playerScore.player.playerName
      [ordered]@{ team = ([string]$_.homeOrAway).ToLower(); type = $(if($_.scoreType -eq 'GOAL'){ 'goal' } else { 'behind' })
        q = [int]$_.periodNumber; secs = [int]$_.periodSeconds; player = $(if($n){ "$($n.givenName) $($n.surname)" } else { 'Rushed' }) } })
    $players = AflPlayers $id
    # real length of each quarter: its last score plus a bit, at least 28 minutes
    $plen = @(1..4 | ForEach-Object { $q = $_; [Math]::Max(1680, (($events | Where-Object { $_.q -eq $q } | ForEach-Object secs | Measure-Object -Maximum).Maximum) + 90) })
    $hTeam = $g.home.team.name; $aTeam = $g.away.team.name
    $odds = AflOdds $hTeam $aTeam $pre $players $avg
    $allMatches.Add(@{
      row = [ordered]@{ id = "RP-$id"; sport = 'afl'; round = $replayRound; home = $hTeam; away = $aTeam; venue = $g.venue.name
        start = (ShiftUtc (ParseUtc $g.utcStartTime) $aflDays) }
      odds = $odds
      src = [ordered]@{ plen = $plen; brk = @(360, 1200, 360); events = $events; players = $players } })
  }
}

# ============================================================================
#  NRL
# ============================================================================
function NrlDraw($r){ Get-Json "https://www.nrl.com/draw/data?competition=111&season=2025&round=$r" }
function NrlCentre($url){ Get-Json ("https://www.nrl.com" + $url + "data") }
function NrlPlayers($mc){
  $names = @{}; $pos = @{}
  foreach($side in 'homeTeam','awayTeam'){ foreach($p in $mc.$side.players){ $names[[string]$p.playerId] = "$($p.firstName) $($p.lastName)"; $pos[[string]$p.playerId] = $p.position } }
  $rows = @()
  foreach($side in 'homeTeam','awayTeam'){
    foreach($s in $mc.stats.players.$side){
      if(-not $names.ContainsKey([string]$s.playerId)){ continue }
      $rows += [ordered]@{ name = $names[[string]$s.playerId]; team = $(if($side -eq 'homeTeam'){ 'home' } else { 'away' })
        rm = [int]$s.allRunMetres; t = [int]$s.tacklesMade; tr = [int]$s.tries; lb = [int]$s.lineBreaks; tb = [int]$s.tackleBreaks; o = [int]$s.offloads
        pos = $pos[[string]$s.playerId] }
    } }
  $rows }
function NrlLadder($r){
  $l = Get-Json "https://www.nrl.com/ladder/data?competition=111&season=2025&round=$r"
  $i = 0
  @($l.positions | ForEach-Object { $i++; $s = $_.stats
    $streak = [string]$s.streak; $form = @()
    if($streak -match '^(\d+)([WLD])$'){ $cnt = [Math]::Min(5, [int]$Matches[1]); $res = $Matches[2]; $form = @(1..$cnt | ForEach-Object { $res }) }
    [ordered]@{ pos = $i; team = $_.teamNickname; played = [int]$s.played; won = [int]$s.wins; lost = [int]$s.lost; drawn = [int]$s.drawn
      byes = [int]$s.byes; pf = [int]$s.'points for'; pa = [int]$s.'points against'; pct = 0; diff = [int]$s.'points difference'
      pts = [int]$s.points; form = $form; move = $(switch($_.movement){ 'up' { 1 } 'down' { -1 } default { 0 } }); next = $_.next.nickname } }) }

function NrlOdds($hTeam, $aTeam, $ladder, $players, $avg){
  $lh = $ladder | Where-Object { $_.team -eq $hTeam }; $la = $ladder | Where-Object { $_.team -eq $aTeam }
  $pg = { param($x) [Math]::Max(1, $x.played) }
  # expected margin from points difference per game, plus a small home edge; spread ~ 15 points
  $mu = ($lh.diff/(& $pg $lh) - $la.diff/(& $pg $la))*0.5 + 2.5
  $ph = NCdf ($mu/15)
  $tot = (($lh.pf/(& $pg $lh)) + ($la.pa/(& $pg $la)) + ($la.pf/(& $pg $la)) + ($lh.pa/(& $pg $lh)))/2
  $line = Half([Math]::Abs($mu)); $hp = $(if($mu -ge 0){ -$line } else { $line })
  $ou = { param($pt, $extra) OU $pt $extra }
  $mk = [ordered]@{
    h2h      = @([ordered]@{ name=$hTeam; price=(Px $ph) }, [ordered]@{ name=$aTeam; price=(Px (1-$ph)) })
    spreads  = @([ordered]@{ name=$hTeam; point=$hp; price=1.90 }, [ordered]@{ name=$aTeam; point=-$hp; price=1.90 })
    totals   = (& $ou (Half $tot) $null)
    team_totals = @((& $ou (Half ($tot/2 + $mu/2)) $hTeam) + (& $ou (Half ($tot/2 - $mu/2)) $aTeam))
    h2h_h1   = @([ordered]@{ name=$hTeam; price=(Px (NCdf ($mu/2/10.6))) }, [ordered]@{ name=$aTeam; price=(Px (1-(NCdf ($mu/2/10.6)))) })
    totals_h1 = (& $ou (Half ($tot/2)) $null)
  }
  # try scorers: a position base rate, blended with the last two rounds where we have them
  $base = @{ 'Winger'=0.55; 'Centre'=0.42; 'Fullback'=0.45; 'Five-Eighth'=0.30; 'Halfback'=0.25; 'Hooker'=0.15 }
  $lam = @{}
  foreach($p in $players){ $b = $(if($base.ContainsKey([string]$p.pos)){ $base[[string]$p.pos] } else { 0.12 })
    $a = $avg[$p.name]; $lam[$p.name] = $(if($a){ 0.5*$b + 0.5*$a.tr } else { $b }) }
  $sum = ($lam.Values | Measure-Object -Sum).Sum
  $mk.player_try_scorer_first   = @($players | ForEach-Object { [ordered]@{ name='Yes'; description=$_.name; price=(Px ($lam[$_.name]/$sum) 1.25 151) } })
  $mk.player_try_scorer_last    = @($players | ForEach-Object { [ordered]@{ name='Yes'; description=$_.name; price=(Px ($lam[$_.name]/$sum) 1.25 151) } })
  $mk.player_try_scorer_anytime = @($players | ForEach-Object { [ordered]@{ name='Yes'; description=$_.name; price=(Px (1-[Math]::Exp(-$lam[$_.name])) 1.10 26) } })
  $mk.player_try_scorer_over    = @($players | Where-Object { $lam[$_.name] -ge 0.3 } | ForEach-Object {
    [ordered]@{ name='Over'; description=$_.name; point=1.5; price=(Px (PoisGE $lam[$_.name] 2) 1.12 41) } })
  $clean = [ordered]@{}; foreach($k in $mk.Keys){ $vals = @($mk[$k] | Where-Object { $_ }); if($vals.Count){ $clean[$k] = $vals } }
  $clean }

Write-Host 'NRL: fixture...'
$nrlRounds = @($NrlFrom, ($NrlFrom+1))
$nrlDays = $null
foreach($ri in 0..1){
  $rn = $nrlRounds[$ri]; $replayRound = $ri + 1
  $draw = NrlDraw $rn
  $games = @($draw.fixtures | Where-Object { $_.type -eq 'Match' } | Sort-Object { ParseUtc $_.clock.kickOffTimeLong })
  if($null -eq $nrlDays){ $nrlDays = WeeksTo (ParseUtc $games[0].clock.kickOffTimeLong) }
  Write-Host "NRL: 2025 round $rn -> replay round $replayRound ($($games.Count) games)"
  $pre = NrlLadder ($rn - 1)
  if($ri -eq 0){ $ladders.Add(@{ sport='nrl'; round=0; rows=$pre; now=$true }) }
  $ladders.Add(@{ sport='nrl'; round=$replayRound; rows=(NrlLadder $rn) })
  $hist = @()
  foreach($prev in ($rn-2),($rn-1)){
    foreach($pf in ((NrlDraw $prev).fixtures | Where-Object { $_.type -eq 'Match' })){ $hist += NrlPlayers (NrlCentre $pf.matchCentreUrl) } }
  $avg = Averages ($hist | ForEach-Object { $h = [ordered]@{}; foreach($k in $_.Keys){ if($k -ne 'pos'){ $h[$k] = $_[$k] } }; $h })
  foreach($g in $games){
    $mc = NrlCentre $g.matchCentreUrl
    $homeId = [string]$mc.homeTeam.teamId
    $names = @{}; foreach($side in 'homeTeam','awayTeam'){ foreach($p in $mc.$side.players){ $names[[string]$p.playerId] = "$($p.firstName) $($p.lastName)" } }
    $events = @($mc.timeline | ForEach-Object {
      $ev = $_                                                    # $_ means something else inside switch
      $key = "$($ev.type)|$($ev.title)"
      $type = $null
      if($key -like 'Try|*'){ $type = 'try' }
      elseif($key -like 'Goal|Conversion-Made*'){ $type = 'conversion' }
      elseif($key -like 'Goal|Penalty Shot-Made*'){ $type = 'penalty' }
      elseif($key -like 'OnePointFieldGoal|*'){ $type = 'field_goal' }
      elseif($key -like 'TwoPointFieldGoal|*'){ $type = 'field_goal_2' }
      if($type){
        $gs = [int]$ev.gameSeconds; $q = $(if($gs -lt 2400){ 1 } else { 2 })
        [ordered]@{ team = $(if([string]$ev.teamId -eq $homeId){ 'home' } else { 'away' }); type = $type; q = $q
          secs = [Math]::Min(2400, $gs - ($q-1)*2400); player = $names[[string]$ev.playerId] } } })
    $players = @(NrlPlayers $mc)
    $odds = NrlOdds $g.homeTeam.nickName $g.awayTeam.nickName $pre $players $avg
    $allMatches.Add(@{
      row = [ordered]@{ id = "RP-NRL-2025-$rn-$($mc.matchId)"; sport = 'nrl'; round = $replayRound
        home = $g.homeTeam.nickName; away = $g.awayTeam.nickName; venue = $g.venue
        start = (ShiftUtc (ParseUtc $g.clock.kickOffTimeLong) $nrlDays) }
      odds = $odds
      src = [ordered]@{ plen = @(2400, 2400); brk = @(600); events = $events
        players = @($players | ForEach-Object { $h = [ordered]@{}; foreach($k in $_.Keys){ if($k -ne 'pos'){ $h[$k] = $_[$k] } }; $h }) } })
  }
}

# ============================================================================
#  write replay_seed.sql
# ============================================================================
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("-- JALF Footy Tipping - replay seed. GENERATED by build-replay.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm'); don't edit by hand.")
[void]$sb.AppendLine("-- AFL 2025 rounds $($aflRounds -join ' & ') and NRL 2025 rounds $($nrlRounds -join ' & '), replayed as season $Season rounds 1 & 2 from $Start.")
[void]$sb.AppendLine("-- Needs migration 005 (replay clock). Re-running replaces the previous replay.")
[void]$sb.AppendLine('begin;')
[void]$sb.AppendLine("delete from ft_matches where id like 'RP-%';                -- cascades to ft_odds and ft_replay_src")
[void]$sb.AppendLine("delete from ft_replay_ladders where season = $Season;")
[void]$sb.AppendLine("delete from ft_ladders where season = $Season;")
[void]$sb.AppendLine("delete from ft_round_closed where season = $Season;")
foreach($m in $allMatches){
  $r = $m.row
  [void]$sb.AppendLine("insert into ft_matches (id, sport, season, round, home_team, away_team, venue, commence_time, status) values (" +
    "$(Q $r.id), '$($r.sport)', $Season, $($r.round), $(Q $r.home), $(Q $r.away), $(Q $r.venue), '$($r.start.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))', 'scheduled');")
  [void]$sb.AppendLine("insert into ft_odds (match_id, bookmaker, markets, pulled_at) values ($(Q $r.id), 'Replay odds', $(J $m.odds), now());")
  [void]$sb.AppendLine("insert into ft_replay_src (match_id, plen, brk, events, players) values ($(Q $r.id), $(J $m.src.plen), $(J $m.src.brk), $(J $m.src.events), $(J $m.src.players));")
}
foreach($l in $ladders){
  $tbl = $(if($l.now){ 'ft_ladders' } else { 'ft_replay_ladders' })
  [void]$sb.AppendLine("insert into $tbl (sport, season, round, rows) values ('$($l.sport)', $Season, $($l.round), $(J $l.rows));")
}
[void]$sb.AppendLine('commit;')
[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $out - $($allMatches.Count) matches, $($ladders.Count) ladders."
$allMatches | ForEach-Object { "{0,-4} R{1}  {2,-22} v {3,-22} {4}" -f $_.row.sport, $_.row.round, $_.row.home, $_.row.away, (ToLocal $_.row.start).ToString('ddd dd MMM h:mmtt') } | Write-Host
