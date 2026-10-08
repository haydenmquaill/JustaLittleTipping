/* ════════════════════════════════════════════════════════════════════════════
   JALF Footy Tipping — mock mode (open the page with ?mock)
   A stand-in for the Supabase data layer: generated fixtures, odds, live games, ladders
   and comps, plus fake server behaviour (placing bets, cash out, chat replies), all kept
   in this browser's localStorage. Only loaded in mock mode, so real users never download it.

   Loaded as a plain script (not a module) so ?mock also works when the page is opened as a
   local file. The page passes in the few helpers it shares with the mock, and gets back an object with
   the same methods as liveApi() in index.html.
   ════════════════════════════════════════════════════════════════════════════ */
window.createMockApi = function(page){
  const { comboPrice, betNet, uid, onChatMessage, cashOutQuote, cur, isOpen, SPORT_INFO, TEAMS, QLEN, LEG_CAP } = page;
  return mockApi();

  /* ════════ MOCK DATA ════════
     The season is mid-way: AFL round 5 and NRL round 14 are under way. You start in
     "Quaill Family Tipping" (AFL, QUAILL, member, with some history), "Office Tipping"
     (AFL, OFFICE, which you host) and "Quaill Family League" (NRL, FAMNRL, member).
     To join: "Bendigo Footy Club" (AFL, BENDGO), "The Boys" (AFL, BOYS27) and
     "Rugby League Legends" (NRL, LEAGUE). Kick-off times are relative to page load.
     Everything persists in localStorage; Account → Reset clears it. */
  function mockApi(){
    const now = Date.now(), MIN = 60e3, HR = 60*MIN, DAY = 24*HR;
    // round far-off kick-offs to 5 min for tidy times; keep near ones exact so the countdown is visible
    const at = ms => new Date(Math.abs(ms)<HR ? now+ms : Math.round((now+ms)/(5*MIN))*(5*MIN)).toISOString();
    const season = { id:2027 };
    const ME = 'mock-user';
    const STORE = 'ft-mock-v12';
    // round, home, away, kick-off offset, status, venue, live: [quarter, clock secs, home g.b per qtr, away g.b per qtr]
    const FX = [
      [5,'Carlton Blues','Richmond Tigers',-26*HR,'concluded','MCG',
        [4, QLEN, [[3,2],[7,5],[10,8],[14,10]], [[2,4],[5,6],[8,9],[10,11]]]],
      [5,'Collingwood Magpies','Sydney Swans',-80*MIN,'live','MCG',
        [3, 761, [[2,3],[4,5],[5,8]], [[1,2],[4,4],[4,7]]]],
      [5,'Brisbane Lions','Geelong Cats',4*MIN,'scheduled','Gabba'],
      [5,'Fremantle Dockers','Western Bulldogs',3*HR,'scheduled','Optus Stadium'],
      [5,'Port Adelaide Power','Hawthorn Hawks',DAY+4*HR,'scheduled','Adelaide Oval'],
      [5,'Greater Western Sydney Giants','St Kilda Saints',2*DAY+2*HR,'scheduled','ENGIE Stadium'],
      [6,'Richmond Tigers','Collingwood Magpies',7*DAY,'scheduled','MCG'],
      [6,'Sydney Swans','Brisbane Lions',8*DAY,'scheduled','SCG'],
      [6,'Geelong Cats','Carlton Blues',8*DAY+5*HR,'scheduled','GMHBA Stadium'],
    ];
    // NRL: round, home, away, kick-off offset, status, venue, live: [half, clock secs, home pts per half, away pts per half]
    const NRL_FX = [
      [14,'Manly Warringah Sea Eagles','South Sydney Rabbitohs',-27*HR,'concluded','4 Pines Park', [2, 2400, [6,28], [12,14]]],
      [14,'Penrith Panthers','Melbourne Storm',-75*MIN,'live','BlueBet Stadium', [2, 1092, [12,18], [6,16]]],
      [14,'Brisbane Broncos','Sydney Roosters',6*MIN,'scheduled','Suncorp Stadium'],
      [14,'Parramatta Eels','Canterbury-Bankstown Bulldogs',4*HR,'scheduled','CommBank Stadium'],
      [14,'Cronulla-Sutherland Sharks','North Queensland Cowboys',DAY+3*HR,'scheduled','Ocean Protect Stadium'],
      [14,'New Zealand Warriors','Dolphins',2*DAY+HR,'scheduled','Go Media Stadium'],
      [15,'St George Illawarra Dragons','Wests Tigers',7*DAY,'scheduled','WIN Stadium'],
      [15,'Canberra Raiders','Newcastle Knights',7*DAY+5*HR,'scheduled','GIO Stadium'],
    ];
    const build = (sport, prefix, list, seedOff) => list.map((f,i) => {
      const seed = seedOff+i+1;
      const m = { id:prefix+i, sport, season:2027, round:f[0], home_team:f[1], away_team:f[2],
        commence_time:at(f[3]), status:f[4], venue:f[5], home_score:null, away_score:null, live:null };
      m.squads = mockSquads(seed);
      if(f[6]){
        const [q, secs, home, away] = f[6];
        const pts = per => !per.length ? 0 : sport==='nrl' ? per[per.length-1] : per[per.length-1][0]*6 + per[per.length-1][1];
        m.home_score = pts(home); m.away_score = pts(away);
        m.live = mockLive(m, q, secs, home, away, seed);
      }
      return m;
    });
    const matches = [...build('afl','mock-',FX,0), ...build('nrl','nrl-',NRL_FX,40)];
    const odds = {}; matches.forEach((m,i) => { odds[m.id] = mockMarkets(m, i+1); });
    const CUR = { afl:5, nrl:14 };          // the round under way in each code
    const CUR_ROUND = CUR.afl;

    // ── seed comps (rebuilt on reset) ──
    const L = (market, name, price, extra={}) => ({ match_id:'past', sport:'afl', market, name, price, description:null, point:null, ...extra });
    const pl = (market, who, price, point=null) => L(market, point!=null?'Over':'Yes', price, { description:who, point });
    const settle = (list, cr=CUR_ROUND) => list.map(([uid,round,kind,legs,stake,status],i) => {
      const price = comboPrice(legs), pay = Math.round(stake*price*100)/100;
      return { id:'sb-'+uid+'-'+i, user_id:uid, round, kind, legs, stake, price, status,
        potential_payout:pay, payout: status==='won' ? pay : 0, placed_at:at(-(cr+1-round)*7*DAY) };
    });
    function seedState(){
      const member = (name, hist, bal, joinedDaysAgo=40) => ({ display_name:name, balance:bal, history:hist, joined_at:at(-joinedDaysAgo*DAY) });
      const hist = h => Object.fromEntries(h.map((v,i) => [i+1, v]));
      const quaill = {
        id:'c-quaill', sport:'afl', name:'Quaill Family Tipping', code:'QUAILL', host_id:'q-gazza', starting_balance:1000, start_round:1,
        rules:{ max_legs:15, max_stake:0, props:true }, pinned:'qm-0', created_at:at(-40*DAY),
        members:{
          'q-gazza':  member('Gazza',  hist([1040,1110,1095,1150]), 1342),
          'q-shazza': member('Shazza', hist([980,1045,1120,1060]), 1188.5),
          'q-kev':    member('Big Kev',hist([1060,1015,1290,1310]), 1075),
          'q-tones':  member('Tones',  hist([995,1020,1050,1012]), 996),
          'q-davo':   member('Davo',   hist([1010,1290,1205,1170]), 940.25),
          'q-jules':  member('Jules',  hist([1000,960,905,1105]), 871),
          'q-sully':  member('Sully',  hist([1030,1080,1010,860]), 802),
          'q-robbo':  member('Robbo',  hist([970,930,1180,1120]), 655.5),
        },
        bets: settle([
          ['q-gazza',5,'multi',[L('h2h','Carlton Blues',1.65),L('h2h','Geelong Cats',1.8),L('h2h','Hawthorn Hawks',2.4),pl('player_disposals_over','T. Harding',3.1,29.5)],25,'won'],
          ['q-kev',5,'single',[L('h2h','Richmond Tigers',2.35)],300,'lost'],
          ['q-shazza',5,'sgm',[L('h2h','Carlton Blues',1.65),pl('player_goal_scorer_first','S. McKay',11)],20,'won'],
          ['q-robbo',5,'single',[L('spreads','Richmond Tigers',1.9,{ point:14.5 })],250,'lost'],
          ['q-davo',5,'single',[pl('player_goal_scorer_anytime','L. Doyle',2.2)],60,'won'],
          ['q-tones',4,'multi',[L('h2h','Sydney Swans',1.5),L('h2h','Essendon Bombers',2.1),L('h2h','Gold Coast Suns',1.75),L('h2h','Adelaide Crows',1.95),L('h2h','Melbourne Demons',1.6),L('h2h','West Coast Eagles',4.2)],50,'lost'],
          ['q-jules',4,'single',[L('h2h','Brisbane Lions',1.45)],200,'won'],
          ['q-sully',4,'sgm',[L('h2h','Fremantle Dockers',1.8),pl('player_disposals_over','B. Ashby',2.6,24.5),pl('player_goals_scored_over','N. Pickett',3.4,2.5)],150,'lost'],
          ['q-gazza',4,'single',[L('h2h','North Melbourne Kangaroos',3.6)],120,'lost'],
          ['q-robbo',3,'multi',[L('h2h','Geelong Cats',1.7),L('h2h','Port Adelaide Power',2.05),L('h2h','Hawthorn Hawks',2.25)],40,'won'],
          ['q-kev',3,'single',[L('h2h','Collingwood Magpies',1.9)],250,'won'],
          ['q-shazza',2,'single',[L('h2h','St Kilda Saints',2.8)],200,'lost'],
          ['q-davo',2,'multi',[L('h2h','Sydney Swans',1.55),L('h2h','Carlton Blues',2.3),L('h2h','Western Bulldogs',1.9),L('h2h','Gold Coast Suns',2.6),L('h2h','Brisbane Lions',1.75)],15,'won'],
        ]),
      };
      // you host this one, so the host tools can be tested
      const office = {
        id:'c-office', sport:'afl', name:'Office Tipping', code:'OFFICE', host_id:ME, starting_balance:500, start_round:3,
        rules:{ max_legs:5, max_stake:100, props:false }, pinned:'om-0', created_at:at(-16*DAY),
        members:{
          [ME]:      member('Hayds', { 3:500, 4:500 }, 500, 16),
          'o-priya': member('Priya', { 3:540, 4:610 }, 655, 16),
          'o-steve': member('Steve', { 3:470, 4:455 }, 410, 16),
          'o-macca': member('Macca', { 3:505, 4:520 }, 498, 15),
          // a bigger office, so the members list runs past the top-10 cut
          'o-anna':  member('Anna',  { 3:520, 4:575 }, 590, 14),
          'o-dev':   member('Dev',   { 3:480, 4:430 }, 385, 14),
          'o-kim':   member('Kim',   { 3:500, 4:540 }, 560, 13),
          'o-luke':  member('Luke',  { 3:455, 4:470 }, 452, 13),
          'o-mel':   member('Mel',   { 3:530, 4:515 }, 540, 12),
          'o-nate':  member('Nate',  { 3:500, 4:500 }, 470, 12),
          'o-olive': member('Olive', { 3:490, 4:525 }, 610, 11),
          'o-raj':   member('Raj',   { 3:515, 4:495 }, 505, 10),
        },
        bets: settle([
          ['o-priya',4,'multi',[L('h2h','Geelong Cats',1.7),L('h2h','Sydney Swans',1.6),L('h2h','Hawthorn Hawks',2.3)],20,'won'],
          ['o-steve',4,'single',[L('h2h','Essendon Bombers',3.1)],100,'lost'],
        ]),
      };
      // two more to join (codes BENDGO and BOYS27)
      const bendigo = {
        id:'c-bendigo', sport:'afl', name:'Bendigo Footy Club', code:'BENDGO', host_id:'b-bec', starting_balance:2000, start_round:2,
        rules:{ max_legs:10, max_stake:250, props:true }, pinned:null, created_at:at(-24*DAY),
        members:{
          'b-bec':   member('Bec',   { 2:2080, 3:2215, 4:2190 }, 2340, 24),
          'b-wal':   member('Wal',   { 2:1950, 3:1890, 4:2010 }, 1925, 24),
          'b-kylie': member('Kylie', { 2:2000, 3:2105, 4:1980 }, 2060, 22),
        },
        bets: settle([
          ['b-bec',4,'single',[pl('player_goals_scored_over','N. Pickett',3.4,2.5)],100,'won'],
          ['b-wal',4,'multi',[L('h2h','Sydney Swans',1.5),L('h2h','Geelong Cats',1.7)],250,'lost'],
        ]),
      };
      const boys = {
        id:'c-boys', sport:'afl', name:'The Boys', code:'BOYS27', host_id:'y-tommo', starting_balance:1000, start_round:1,
        rules:{ max_legs:15, max_stake:0, props:true }, pinned:null, created_at:at(-40*DAY),
        members:{
          'y-tommo': member('Tommo', hist([1120,980,1045,1210]), 1388),
          'y-jacko': member('Jacko', hist([960,1010,1200,1150]), 1095),
          'y-fitzy': member('Fitzy', hist([1005,900,820,790]), 640),
          'y-rooey': member('Rooey', hist([1000,1060,1010,1080]), 1022.5),
        },
        bets: settle([
          ['y-tommo',4,'multi',[L('h2h','Carlton Blues',2.1),L('h2h','Hawthorn Hawks',1.8),L('h2h','Brisbane Lions',1.6),L('h2h','Fremantle Dockers',2.05)],20,'won'],
          ['y-fitzy',4,'single',[L('h2h','West Coast Eagles',5.5)],150,'lost'],
        ]),
      };
      // ── NRL: you're in the family league comp; LEAGUE is there to join ──
      const N = (market, name, price, extra={}) => ({ ...L(market, name, price, extra), sport:'nrl' });
      const npl = (market, who, price, point=null) => ({ ...pl(market, who, price, point), sport:'nrl' });
      const nhist = h => Object.fromEntries(h.map((v,i) => [10+i, v]));      // rounds 10–13
      const famnrl = {
        id:'c-famnrl', sport:'nrl', name:'Quaill Family League', code:'FAMNRL', host_id:'q-kev', starting_balance:1000, start_round:10,
        rules:{ max_legs:10, max_stake:0, props:true }, pinned:'fm-0', created_at:at(-30*DAY),
        members:{
          [ME]:       member('Hayden',  nhist([1000,1040,980,1065]), 1065, 30),
          'q-kev':    member('Big Kev', nhist([1080,1150,1120,1210]), 1290, 30),
          'q-shazza': member('Shazza',  nhist([960,1010,1075,1040]), 1102, 29),
          'q-robbo':  member('Robbo',   nhist([1020,900,860,935]), 870, 28),
        },
        bets: settle([
          ['q-kev',13,'multi',[N('h2h','Penrith Panthers',1.45),N('h2h','Melbourne Storm',1.6),N('h2h','Cronulla-Sutherland Sharks',2.1)],40,'won'],
          ['q-robbo',13,'single',[N('h2h','Wests Tigers',3.8)],120,'lost'],
          ['q-shazza',12,'sgm',[N('h2h','Sydney Roosters',1.7),npl('player_try_scorer_anytime','J. Walker',2.4)],25,'won'],
        ], CUR.nrl),
      };
      const league = {
        id:'c-league', sport:'nrl', name:'Rugby League Legends', code:'LEAGUE', host_id:'l-mick', starting_balance:1000, start_round:12,
        rules:{ max_legs:8, max_stake:200, props:true }, pinned:null, created_at:at(-14*DAY),
        members:{
          'l-mick':  member('Mick',  { 12:1060, 13:1135 }, 1180, 14),
          'l-dazza': member('Dazza', { 12:940, 13:990 }, 925, 14),
          'l-jas':   member('Jas',   { 12:1010, 13:1000 }, 1045, 13),
        },
        bets: settle([
          ['l-mick',13,'single',[npl('player_try_scorer_first','T. Harding',9)],20,'won'],
        ], CUR.nrl),
      };
      const msg = (id, uid, name, comp_name, text, ago, sport='afl') => ({ id, user_id:uid, name, comp_name, sport, text, ts:now-ago });
      return {
        current:'c-quaill',
        comps:{ [quaill.id]:quaill, [office.id]:office, [bendigo.id]:bendigo, [boys.id]:boys, [famnrl.id]:famnrl, [league.id]:league },
        chat:{
          comp:{
            'c-quaill':[
              msg('qm-0','q-gazza','Gazza','Quaill Family Tipping','Welcome to the 2027 comp! Bets lock at the bounce. Loser shouts the Grand Final pies 🥧', 6*DAY),
              msg('qm-1','q-kev','Big Kev','Quaill Family Tipping','Tigers by a kick, mark my words', 27*HR),
              msg('qm-2','q-shazza','Shazza','Quaill Family Tipping','How’d that go Kev 😂', 22*HR),
              msg('qm-3','q-kev','Big Kev','Quaill Family Tipping','Don’t.', 21*HR),
              msg('qm-4','q-davo','Davo','Quaill Family Tipping','Pies looking good tonight, who’s on?', 70*MIN),
              msg('qm-5','q-gazza','Gazza','Quaill Family Tipping','4 leggie up and running 🙏', 12*MIN),
            ],
            'c-office':[
              msg('om-0',ME,'Hayds','Office Tipping','Player markets are off to keep it simple. $100 max per bet.', 10*DAY),
              msg('om-1','o-steve','Steve','Office Tipping','Bombers owe me $100', 3*DAY),
            ],
            'c-bendigo':[
              msg('bm-0','b-bec','Bec','Bendigo Footy Club','Training’s off Thursday, tipping is not 😄', 2*DAY),
            ],
            'c-boys':[
              msg('ym-0','y-fitzy','Fitzy','The Boys','West Coast at $5.50 was value, I stand by it', 5*DAY),
              msg('ym-1','y-tommo','Tommo','The Boys','It was not', 5*DAY-20*MIN),
            ],
            'c-famnrl':[
              msg('fm-0','q-kev','Big Kev','Quaill Family League','League comp is go. Same rules as the footy, 10-leg max on multis 🏉', 9*DAY, 'nrl'),
              msg('fm-1','q-shazza','Shazza','Quaill Family League','Kev hosting a comp after his Tigers tip, brave', 9*DAY-HR, 'nrl'),
            ],
            'c-league':[
              msg('lm-0','l-mick','Mick','Rugby League Legends','$200 max a bet, keep it sensible lads', 12*DAY, 'nrl'),
            ],
          },
          // the code rooms: everyone in any comp of that code
          sport:{
            afl:[
              msg('sa-0','b-wal','Wal','Bendigo Footy Club','Daicos 30+ disposals is the lock of the round', 5*HR),
              msg('sa-1','q-davo','Davo','Quaill Family Tipping','Not at $3.40 it isn’t', 4*HR+30*MIN),
            ],
            nrl:[
              msg('sn-0','l-dazza','Dazza','Rugby League Legends','Panthers -6.5 every week until they lose', 6*HR, 'nrl'),
              msg('sn-1','q-robbo','Robbo','Quaill Family League','Storm will make you pay for that', 5*HR, 'nrl'),
            ],
          },
          global:[
            msg('gm-0','o-macca','Macca','Office Tipping','Anyone else on the Lions tonight?', 3*HR),
            msg('gm-1','b-bec','Bec','Bendigo Footy Club','Lions at the Gabba is free money', 2*HR+40*MIN),
            msg('gm-2','q-gazza','Gazza','Quaill Family Tipping','Never free money at the Gabba. Ask Kev.', 2*HR),
            msg('gm-4','l-mick','Mick','Rugby League Legends','Footy heads, the league is where the value is 👀', 80*MIN, 'nrl'),
            msg('gm-3','y-tommo','Tommo','The Boys','Who’s got a disposals tip for Pies v Swans?', 35*MIN),
          ],
        },
        mine:{ 'c-office':[], 'c-famnrl':[] },        // compId → my bets
        // unlocks: a few of yours (two you haven't seen yet, so the pop-ups show), and some for others
        unlocks:(() => {
          const u = (ach, daysAgo, seen=true, scope='', meta={}) => ({ ach, scope, meta, unlocked_at:at(-daysAgo*DAY), seen });
          return {
            [ME]:     [u('first_blood',30), u('early_bird',24), u('leg_day',20), u('payday',9), u('banker',6), u('big_fish',4),
                       u('champion',15, true, 'c-boys-2026', { comp_name:'The Boys', season:2026 }), u('hot_hand',0, false), u('lucky_phil',0, false)],
            'q-gazza':[u('first_blood',35), u('round_winner',14), u('top_dog',7), u('quadzilla',3), u('flair_supporter',40, true, 'afl:HAW:2027', { season:2027 }),
                       u('flair_streak',40, true, 'afl:HAW:5', { streak:5 })],
            'q-shazza':[u('first_blood',33), u('nostradamus',8), u('flair_supporter',40, true, 'afl:GEE:2027', { season:2027 })],
            'q-kev':  [u('mug_punter',21), u('donation_box',12), u('first_blood',5)],
          };
        })(),
        flairs:{ [ME]:{ ach:'champion', scope:'c-boys-2026' }, 'q-gazza':{ ach:'flair_streak', scope:'afl:HAW:5' }, 'q-shazza':{ ach:'nostradamus', scope:'' }, 'q-kev':{ ach:'mug_punter', scope:'' } },
        // who barracks for whom (you haven't picked yet, so the picker can be tested)
        profiles:Object.fromEntries([
          ['q-gazza',{ afl:'HAW', nrl:'MEL' }], ['q-shazza',{ afl:'GEE' }], ['q-kev',{ afl:'RIC', nrl:'PEN' }], ['q-tones',{ afl:'COL' }],
          ['q-davo',{ afl:'COL' }], ['q-jules',{ afl:'BRI' }], ['q-robbo',{ afl:'CAR', nrl:'SOU' }],
          ['o-priya',{ afl:'GEE' }], ['o-steve',{ afl:'ESS' }], ['o-anna',{ afl:'SYD' }], ['o-kim',{ afl:'WCE' }],
          ['b-bec',{ afl:'BRI' }], ['b-wal',{ afl:'COL' }], ['y-tommo',{ afl:'CAR' }], ['y-fitzy',{ afl:'WCE' }],
          ['l-mick',{ nrl:'STG' }], ['l-dazza',{ nrl:'PEN' }], ['l-jas',{ nrl:'BRI' }],
        ].map(([id, t]) => [id, Object.fromEntries(Object.entries(t).map(([sp, team]) => [sp, { team, season:2027, since_round:1, changes:0 }]))])),
      };
    }
    let st = null;
    try{ st = JSON.parse(localStorage.getItem(STORE)); }catch(e){}
    if(!st || !st.comps){
      st = seedState();
      // you start in the family comp too, mid-season with a bit of history
      const q = st.comps['c-quaill'], h = seedMyHistory(q);
      q.members[ME] = { display_name:'Hayden', balance:h.balance, history:h.history, joined_at:at(-40*DAY) };
      // weekly-allowance comps (the rest stay one-off, so both kinds can be tested)
      ['c-quaill','c-boys','c-famnrl'].forEach(id => weeklyize(st.comps[id]));
      spendize(st.comps['c-office'], 100);
    }
    // turn a seeded one-off comp into a weekly-allowance one with the same profits: each member is
    // paid from the first round they have history for, and history becomes { b:balance, f:funded }
    function weeklyize(c){
      const A = c.starting_balance, cr = CUR[c.sport];
      c.rules = { ...c.rules, bankroll:'weekly' };
      Object.values(c.members).forEach(m => {
        const rs = Object.keys(m.history||{}).map(Number);
        const jr = rs.length ? Math.min(...rs) : cr;
        m.history = Object.fromEntries(rs.map(r => [r, { b:m.history[r] + A*(r-jr), f:A*(r-jr+1) }]));
        m.balance = Math.round((m.balance + A*(cr-jr))*100)/100;
        m.funded = A*(cr-jr+1);
      });
    }
    // turn a seeded one-off comp into a weekly spend one at amount W: each round's gain (scaled to W)
    // is banked if positive, everyone sits on W, and history becomes { b, f, k }
    function spendize(c, W){
      const old = c.starting_balance, cr = CUR[c.sport];
      c.rules = { ...c.rules, bankroll:'spend' }; c.starting_balance = W;
      Object.values(c.members).forEach(m => {
        const rs = Object.keys(m.history||{}).map(Number).sort((a,b) => a-b);
        const jr = rs.length ? rs[0] : cr;
        let prev = old, k = 0; const h = {};
        rs.forEach(r => { k += Math.max(0, (m.history[r] - prev) * W / old); prev = m.history[r]; h[r] = { b:W, f:W*(r-jr+1), k:Math.round(k*100)/100 }; });
        m.history = h;
        m.banked = Math.round((k + Math.max(0, (m.balance - prev) * W / old))*100)/100;
        m.balance = W; m.funded = W*(cr-jr+1);
      });
    }
    const save = () => { try{ localStorage.setItem(STORE, JSON.stringify(st)); }catch(e){} };
    const comp = id => { const c = st.comps[id]; if(!c) throw new Error('Competition not found.'); return c; };
    const meta = c => { const { members, bets, ...rest } = c; return JSON.parse(JSON.stringify(rest)); };
    const nameTaken = (c, name, except) => Object.entries(c.members).some(([id,m]) => id!==except && m.display_name.toLowerCase()===name.toLowerCase());
    const newCode = () => {
      const A = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
      let code; do{ code = Array.from({ length:6 }, () => A[Math.floor(Math.random()*A.length)]).join(''); }
      while(Object.values(st.comps).some(c => c.code===code));
      return code;
    };
    const priceOf = l => (odds[l.match_id].markets[l.market].find(o => o.name===l.name
      && (o.description??null)===(l.description??null) && (o.point??null)===(l.point??null)) || {}).price;
    const strip = m => { const { squads, ...rest } = m; return rest; };
    // joining the family comp mid-season gives you some history, so highlights and the leaderboard have something to show
    function seedMyHistory(c){
      const m = matches[0], o = odds[m.id].markets.h2h[0];
      const bets = settle([
        [ME,3,'single',[L('h2h','Geelong Cats',1.75)],100,'won'],
        [ME,3,'single',[pl('player_disposals_over','J. Walker',2.1,24.5)],50,'lost'],
        [ME,4,'multi',[L('h2h','Sydney Swans',1.5),L('h2h','Carlton Blues',2.1),L('h2h','Hawthorn Hawks',1.8),L('h2h','Fremantle Dockers',1.74)],20,'won'],
        [ME,4,'sgm',[L('h2h','Gold Coast Suns',1.6),pl('player_goal_scorer_anytime','K. Mercer',4)],25,'lost'],
        [ME,5,'single',[{ match_id:m.id, sport:'afl', round:5, market:'h2h', name:o.name, description:null, point:null, price:o.price }],50,'won'],
      ]).reverse();
      const upTo = r => Math.round(bets.filter(b => b.round<=r).reduce((a,b) => a+betNet(b), c.starting_balance)*100)/100;
      st.mine[c.id] = bets;
      return { history:{ 1:c.starting_balance, 2:c.starting_balance, 3:upTo(3), 4:upTo(4) }, balance:upTo(5) };
    }
    // mock realtime: someone answers you now and then
    const REPLIES = {
      comp:['Bold. I like it.','You’ll regret that 😂','Same, I’m on it too','Not a chance','Big call','Get on!','Ask me again at half time'],
      sport:['Haha good luck with that','Who’s your best bet this round?','Taking the under on that one','Big call','Mate, no'],
      global:['Haha good luck with that','Who’s your best bet this round?','Taking the under on that one','Lions by 20','Panthers by 12'],
    };
    // which list a room's messages live in
    // every chat message, in every room
    function allChat(){ return [...Object.values(st.chat.comp).flat(), ...Object.values(st.chat.sport).flat(), ...st.chat.global]; }
    // the name someone goes by (their username in a comp you can see); strict: null if no one has that id
    function knownAs(id, strict){
      for(const c of Object.values(st.comps)) if(c.members[id]) return c.members[id].display_name;
      return strict ? null : 'Someone';
    }
    // friends, real names, avatars and friends chats (seeded on first use)
    function social(){
      if(st.social) return st.social;
      const ago = ms => Date.now() - ms;
      st.social = {
        avatars:{}, realNames:{ 'q-gazza':'Gary Quaill', 'q-shazza':'Sharon Quaill', 'q-kev':'Kevin Quaill', 'o-priya':'Priya Shah' },
        friends:{ 'q-gazza':{ status:'accepted', since:new Date(ago(9*864e5)).toISOString() },
                  'q-shazza':{ status:'pending', incoming:true, since:new Date(ago(864e5)).toISOString() },
                  'o-priya':{ status:'pending', incoming:false, since:new Date(ago(2*864e5)).toISOString() } },
        threads:[ { id:'th-gazza', kind:'dm', members:[ME, 'q-gazza'], created_at:new Date(ago(5*864e5)).toISOString() },
                  { id:'th-crew', kind:'group', name:'Quaill crew', owner:'q-gazza', members:['q-gazza', ME, 'q-kev'], created_at:new Date(ago(3*864e5)).toISOString() } ],
        msgs:{ 'th-gazza':[ { id:'dm-1', user_id:'q-gazza', text:'You on the Hawks this week?', ts:ago(26*36e5) },
                            { id:'dm-2', user_id:ME, text:'Always. Hawks by 30', ts:ago(25*36e5) },
                            { id:'dm-3', user_id:'q-gazza', text:'Bold. Tailing it 😂', ts:ago(40*6e4) } ],
               'th-crew':[ { id:'gc-1', user_id:'q-kev', text:'Who’s hosting the Grand Final BBQ?', ts:ago(5*36e5) },
                           { id:'gc-2', user_id:'q-gazza', text:'Loser of the comp, obviously', ts:ago(4*36e5) } ] },
        read:{ 'th-gazza':ago(24*36e5), 'th-crew':ago(4.5*36e5) },
      };
      return st.social;
    }
    function roomList(room, compId){
      if(room==='comp') return (st.chat.comp[compId] = st.chat.comp[compId] || []);
      if(room==='sport'){ const s = st.comps[compId].sport; return (st.chat.sport[s] = st.chat.sport[s] || []); }
      return st.chat.global;
    }
    function maybeReply(room, compId){
      if(Math.random() > 0.6) return;
      setTimeout(() => {
        const mine = st.comps[compId]; if(!mine) return;
        // comp room: a member of this comp. sport room: anyone in a comp of the same code. global: anyone.
        const pool = Object.values(st.comps)
          .filter(c => room==='comp' ? c.id===compId : room==='sport' ? c.sport===mine.sport : true)
          .flatMap(c => Object.entries(c.members).filter(([id]) => id!==ME).map(([id,mm]) => ({ user_id:id, name:mm.display_name, comp_name:c.name, sport:c.sport })));
        if(!pool.length) return;
        const from = pool[Math.floor(Math.random()*pool.length)];
        const lines = REPLIES[room];
        const msg = { id:uid(), ...from, text:lines[Math.floor(Math.random()*lines.length)], ts:Date.now() };
        roomList(room, compId).push(msg); save();
        onChatMessage(room, compId, msg);
      }, 2500 + Math.random()*3000);
    }

    return {
      // auth: the mock is always "signed in"
      async user(){ return { id:ME, email:'you@mock.local' }; },
      async signIn(){}, async signUp(){ return true; }, async signOut(){}, async resetPassword(){}, async updatePassword(){},
      subscribe(){ return () => {}; },  // mock "realtime" is the replies in maybeReply
      async season(){ return season; },
      lastComp(){ return st.current; },
      setLastComp(id){ st.current = id; save(); },
      // ── comps ──
      async myComps(){
        return Object.values(st.comps).filter(c => c.members[ME]).map(c => ({ id:c.id, sport:c.sport, name:c.name, code:c.code, host_id:c.host_id,
          display_name:c.members[ME].display_name, members:Object.keys(c.members).length }));
      },
      async comp(id){ return meta(comp(id)); },
      async entrant(id){ const m = comp(id).members[ME]; return m ? { ...m, user_id:ME } : null; },
      async findComp(code){
        const c = Object.values(st.comps).find(x => x.code===code.toUpperCase());
        return c ? { id:c.id, name:c.name, sport:c.sport, member:!!c.members[ME], members:Object.keys(c.members).length,
          starting_balance:c.starting_balance, bankroll:(c.rules && c.rules.bankroll) || 'once' } : null;
      },
      async hostComp({ name, display_name, sport='afl', starting_balance, rules }){
        const id = 'c-'+uid().slice(0,8);
        rules = { ...rules, bankroll: rules && ['once','spend'].includes(rules.bankroll) ? rules.bankroll : 'weekly' };
        st.comps[id] = { id, sport, name, code:newCode(), host_id:ME, starting_balance, start_round:CUR[sport], rules, pinned:null,
          created_at:new Date().toISOString(),
          members:{ [ME]:{ display_name, balance:starting_balance, funded:starting_balance, history:{}, joined_at:new Date().toISOString() } }, bets:[] };
        st.chat.comp[id] = [];
        st.mine[id] = [];
        save();
        return meta(st.comps[id]);
      },
      async joinComp(id, display_name){
        const c = comp(id);
        if(c.members[ME]) return { ...c.members[ME], user_id:ME };
        if(nameTaken(c, display_name)) throw new Error('That username is taken in this comp.');
        // a new member gets this round's allowance (or the one-off balance) — no back-pay
        if(!st.mine[id]) st.mine[id] = [];
        c.members[ME] = { display_name, balance:c.starting_balance, funded:c.starting_balance, history:{}, joined_at:new Date().toISOString() };
        save();
        return { ...c.members[ME], user_id:ME };
      },
      async updateName(id, name){
        const c = comp(id);
        if(nameTaken(c, name, ME)) throw new Error('That username is taken in this comp.');
        c.members[ME].display_name = name; save();
        return { ...c.members[ME], user_id:ME };
      },
      // ── host tools ──
      async renameComp(id, name){ const c = comp(id); if(c.host_id!==ME) throw new Error('Only the host can do that.'); c.name = name; save(); return meta(c); },
      async regenCode(id){ const c = comp(id); if(c.host_id!==ME) throw new Error('Only the host can do that.'); c.code = newCode(); save(); return meta(c); },
      async removeMember(id, userId){
        const c = comp(id); if(c.host_id!==ME || userId===ME) throw new Error('Only the host can do that.');
        delete c.members[userId]; save();
      },
      async pin(id, msgId){ const c = comp(id); if(c.host_id!==ME) throw new Error('Only the host can do that.'); c.pinned = msgId; save(); return meta(c); },
      async members(id){
        // oldest members first
        return Object.entries(comp(id).members).map(([user_id,m]) => ({ user_id, display_name:m.display_name, balance:m.balance, funded:m.funded, banked:m.banked, joined_at:m.joined_at }))
          .sort((a,b) => new Date(a.joined_at) - new Date(b.joined_at));
      },
      // ── leaderboard ──
      async standings(id){
        return Object.entries(comp(id).members).map(([user_id,m]) => ({ user_id, display_name:m.display_name, balance:m.balance, funded:m.funded, banked:m.banked,
          history:m.history||{}, joined_at:m.joined_at }));
      },
      // someone else's bets as you'd see them: settled ones, plus pending ones that aren't hidden.
      // Every other member also gets a live multi on the next open games, so Tail can be tried.
      async playerBets(id, userId){
        const c = comp(id), mine = userId===ME;
        if(mine) return (st.mine[id]||[]).slice();
        const settled = (c.bets||[]).filter(b => b.user_id===userId);
        const open = matches.filter(m => m.sport===c.sport && isOpen(m));
        const ids = Object.keys(c.members), i = ids.indexOf(userId);
        const pending = [];
        if(open.length && i % 2 === 0){
          const pickM = open.slice(i % Math.max(1, open.length-1), (i % Math.max(1, open.length-1)) + 2);
          const legs = pickM.map(m => { const o = odds[m.id].markets.h2h[(i/2) % 2];
            return { match_id:m.id, sport:m.sport, round:m.round, market:'h2h', name:o.name, description:null, point:null, price:o.price }; });
          const price = comboPrice(legs), stake = 20 + i*5;
          pending.push({ id:`pend-${id}-${userId}`, user_id:userId, round:Math.max(...legs.map(l => l.round)), kind:legs.length>1 ? 'multi' : 'single',
            legs, stake, price, status:'pending', potential_payout:Math.round(stake*price*100)/100, payout:null, hidden:false, placed_at:new Date().toISOString() });
        }
        return [...pending, ...settled];
      },
      async hideBet(betId, hidden){
        const b = Object.values(st.mine).flat().find(x => x.id===betId);
        if(!b || b.status!=='pending') throw new Error('Only your own pending bets can be hidden.');
        b.hidden = !!hidden; save();
        return { ...b };
      },
      // ── who you barrack for (same rules as ft_set_team) ──
      async profiles(ids){
        st.profiles = st.profiles || {}; st.flairs = st.flairs || {};
        const av = social().avatars;
        return Object.fromEntries(ids.filter(id => st.profiles[id] || st.flairs[id] || av[id])
          .map(id => [id, { teams:JSON.parse(JSON.stringify(st.profiles[id] || {})), flair:st.flairs[id] || null, avatar_url:av[id] || null }]));
      },
      // ── achievements (the real ones are worked out by the database) ──
      async unlocks(userId){ return JSON.parse(JSON.stringify(((st.unlocks || {})[userId || ME]) || [])); },
      async achProgress(){
        const mine = Object.values(st.mine).flat();
        const chats = [...Object.values(st.chat.comp).flat(), ...Object.values(st.chat.sport).flat(), ...st.chat.global].filter(m => m.user_id===ME).length;
        return [{ key:'centurion', have:mine.length, need:100 }, { key:'chatterbox', have:chats, need:100 },
                { key:'odds_on_bore', have:mine.filter(b => b.status==='won' && b.price < 1.5).length, need:10 }, { key:'tipster', have:1, need:5 }];
      },
      async seenUnlocks(){ ((st.unlocks || {})[ME] || []).forEach(u => { u.seen = true; }); save(); },
      async setFlair(ach, scope){
        st.flairs = st.flairs || {};
        if(ach && !((st.unlocks || {})[ME] || []).some(u => u.ach===ach && (u.scope||'')===(scope||''))) throw new Error('You haven’t unlocked that one yet.');
        st.flairs[ME] = ach ? { ach, scope:scope || '' } : null; save();
        return st.flairs[ME];
      },
      async seenRound(id, round){ const m = comp(id).members[ME]; if(m){ m.seen_round = Math.max(m.seen_round || 0, round); save(); } },
      // ── notifications: settings are kept, nothing is sent ──
      async myPrefs(){ return JSON.parse(JSON.stringify(st.prefs || {})); },
      async setPrefs(p){ st.prefs = JSON.parse(JSON.stringify(p)); save(); },
      async pushSubscribe(){}, async pushUnsubscribe(){},
      async setTeam(sport, team){
        st.profiles = st.profiles || {};
        const p = st.profiles[ME] = st.profiles[ME] || {}, cur = p[sport];
        if(cur && cur.team===team) return JSON.parse(JSON.stringify(p));
        let changes = 0;
        if(cur && cur.season===season.id){
          if((cur.changes||0) >= 1) throw new Error(`You’ve already changed your ${sport.toUpperCase()} team this season. It unlocks again next season.`);
          changes = (cur.changes||0) + 1;
        }
        p[sport] = { team, season:season.id, since_round:CUR[sport], changes };
        // that season's supporter flair (a change replaces it)
        st.unlocks = st.unlocks || {}; const ul = st.unlocks[ME] = st.unlocks[ME] || [];
        const pre = `${sport}:`, suf = `:${season.id}`;
        st.unlocks[ME] = ul.filter(u => !(u.ach==='flair_supporter' && u.scope.startsWith(pre) && u.scope.endsWith(suf)));
        st.unlocks[ME].push({ ach:'flair_supporter', scope:`${sport}:${team}:${season.id}`, meta:{ sport, team, season:season.id }, unlocked_at:new Date().toISOString(), seen:false });
        if(st.flairs && st.flairs[ME] && st.flairs[ME].ach==='flair_supporter' && st.flairs[ME].scope.startsWith(pre)) st.flairs[ME] = null;
        save();
        return JSON.parse(JSON.stringify(p));
      },
      async moments(id, round){
        const c = comp(id);
        const who = u => (c.members[u] && c.members[u].display_name) || 'Former member';
        const all = [...(c.bets||[]), ...(st.mine[id]||[]).map(b => ({ ...b, user_id:ME }))].map(b => ({ ...b, who:who(b.user_id) }));
        return all.filter(b => round==null || b.round===round);
      },
      // ── fixture + odds (shared by every comp) ──
      async matches(_s, sport){ return matches.filter(m => m.sport===sport).map(m => { const { live, ...rest } = strip(m); return rest; }); },
      async matchLive(id){ const m = matches.find(x => x.id===id); return m ? m.live : null; },
      // round list: head-to-head prices plus which markets exist (for the tile's market count)
      async h2h(ids){
        const o = {};
        ids.forEach(id => { o[id] = odds[id] ? { h2h:odds[id].markets.h2h, keys:Object.keys(odds[id].markets) } : { h2h:[], keys:[] }; });
        return o;
      },
      async markets(id){ return odds[id] || null; },
      // a plausible ladder after the last completed round, deterministic per code
      async ladder(_s, sport, at){
        const round = at!=null ? at : CUR[sport] - 1, nrl = sport==='nrl';
        let s = (nrl ? 7 : 3) * 104729 % 233280;
        const rnd = () => (s = (s*9301 + 49297) % 233280) / 233280;
        const names = (TEAMS[sport] || []).filter(t => !t.joins || t.joins <= 2027).map(t => t.name);
        const rows = names.map(team => {
          const byes = nrl ? (rnd() < .6 ? 1 : 2) : 0;
          const played = round - byes;
          const strength = rnd();
          // play out the games so the W/L/D columns and the form line agree
          const results = Array.from({ length:played }, () => { const x = rnd(); return x < .2 + strength*.6 ? 'W' : x > .985 ? 'D' : 'L'; });
          const won = results.filter(x => x==='W').length, drawn = results.filter(x => x==='D').length;
          const lost = played - won - drawn;
          const avg = nrl ? 21 : 82, swing = nrl ? 6 : 16;
          const pf = Math.round(played*(avg + (strength-.5)*swing*2 + rnd()*4));
          const pa = Math.round(played*(avg - (strength-.5)*swing*2 + rnd()*4));
          const form = results.slice(-5), hw = Math.ceil(won/2), hl = Math.floor(lost/2);
          const rec = (w, l) => `${w} - ${l}`;
          return { team, played, won, lost, drawn, byes, pf, pa, pct:pa ? Math.round(pf/pa*1000)/10 : 0, diff:pf-pa,
            pts:won*(nrl?2:4) + drawn*(nrl?1:2) + byes*2, form,
            ...(nrl ? { home:rec(hw, hl), away:rec(won - hw, lost - hl), fs:rec(form.filter(x => x==='W').length, form.filter(x => x==='L').length) } : {}) };
        }).sort((a,b) => b.pts-a.pts || (nrl ? b.diff-a.diff : b.pct-a.pct));
        rows.forEach((r,i) => {
          r.pos = i+1;
          r.move = Math.round((rnd()-.5)*4);
          r.next = rows[(i*7+3) % rows.length].team === r.team ? rows[(i+1) % rows.length].team : rows[(i*7+3) % rows.length].team;
        });
        return { round, rows };
      },
      async ladderList(sport){ return Array.from({ length:CUR[sport] }, (_, i) => ({ season:season.id, round:CUR[sport] - 1 - i })); },
      // ── betting (per comp) ──
      async myBets(id){ return (st.mine[id]||[]).slice(); },
      // mock cash out uses the page's own pricing (the live version re-prices on the server)
      async cashOut(id, quote){
        const c = comp(st.current), me = c.members[ME];
        const b = (st.mine[c.id]||[]).find(x => x.id===id);
        if(!b || b.status!=='pending') throw new Error('This bet has already been settled.');
        const v = cashOutQuote(b);
        if(v==null) throw new Error('Cash out isn’t available on this bet right now.');
        if(Math.abs(v - quote) > Math.max(0.5, quote*0.03)) throw new Error(`cash out value changed: ${v}`);
        b.status = 'cashed_out'; b.payout = v; b.settled_at = new Date().toISOString();
        me.balance = Math.round((me.balance + v)*100)/100;
        save();
        return { payout:v, balance:me.balance };
      },
      async placeBets(id, p){
        const c = comp(id), me = c.members[ME];
        const total = p.reduce((a,b) => a+b.stake, 0);
        if(total > me.balance) throw new Error('insufficient balance');
        const cap = Math.min(LEG_CAP, c.rules.max_legs||LEG_CAP);
        p.forEach(b => {
          if(b.legs.length > cap) throw new Error(`This comp allows at most ${cap} legs`);
          if(c.rules.max_stake && b.stake > c.rules.max_stake) throw new Error(`This comp’s max stake is ${cur(c.rules.max_stake)} per bet`);
          if(c.rules.props===false && b.legs.some(l => l.market.startsWith('player_'))) throw new Error('Player markets are off in this comp');
          b.legs.forEach(l => {
            const m = matches.find(x => x.id===l.match_id);
            if(!isOpen(m)) throw new Error(`Betting closed for ${m.home_team} v ${m.away_team}`);
          });
        });
        p.forEach(b => {
          const legs = b.legs.map(l => { const m = matches.find(x => x.id===l.match_id); return { ...l, sport:m.sport, round:m.round, price:priceOf(l) }; });
          // a bet belongs to the round it settles in — a multi's last leg
          const round = Math.max(...legs.map(l => l.round));
          (st.mine[id] = st.mine[id]||[]).unshift({ id:uid(), sport:'afl', round, kind:b.kind, status:'pending', stake:b.stake,
            price:b.price, potential_payout:Math.round(b.stake*b.price*100)/100, payout:null, placed_at:new Date().toISOString(), legs,
            hidden:!!b.hidden, tail_of:b.tail_of || null });
        });
        me.balance = Math.round((me.balance - total)*100)/100;
        save();
        return me.balance;
      },
      // ── chat: edit / delete (yours; the host can delete anything in the comp room) ──
      async editChat(id, body){
        const m = allChat().find(x => x.id===id);
        if(!m || m.user_id!==ME || m.deleted) throw new Error('You can only edit your own messages.');
        m.text = body.slice(0,280); m.edited = true; save(); return { ...m };
      },
      async deleteChat(id){
        const m = allChat().find(x => x.id===id); if(!m) throw new Error('Message not found.');
        const host = Object.values(st.comps).some(c => c.host_id===ME && (st.chat.comp[c.id]||[]).includes(m));
        if(m.user_id!==ME && !host) throw new Error('You can’t delete that message.');
        m.deleted = true; m.text = '·'; m.edited = false;
        Object.values(st.comps).forEach(c => { if(c.pinned===m.id) c.pinned = null; });
        save(); return { ...m };
      },

      // ── you: avatar + real name ──
      async setAvatar(blob){
        const url = await new Promise(res => { const r = new FileReader(); r.onload = () => res(r.result); r.readAsDataURL(blob); });
        social().avatars[ME] = url; save(); return url;
      },
      async removeAvatar(){ delete social().avatars[ME]; save(); },
      async myRealName(){ return social().realNames[ME] || ''; },
      async setRealName(name){ social().realNames[ME] = name || ''; save(); },

      // ── friends ──
      async person(id){
        const so = social(), f = so.friends[id];
        const shared = Object.values(st.comps).filter(c => c.members[ME] && c.members[id])
          .map(c => ({ comp_id:c.id, comp_name:c.name, sport:c.sport, username:c.members[id].display_name }));
        return { user_id:id, known_as:knownAs(id), avatar_url:so.avatars[id] || null, shared,
          real_name: (id===ME || (f && f.status==='accepted')) ? (so.realNames[id] || null) : null,
          friend: !f ? 'none' : f.status==='accepted' ? 'friends' : f.incoming ? 'incoming' : 'requested',
          notify: f && f.status==='accepted' ? !!f.notify : null };
      },
      async friends(){
        const so = social();
        return Object.entries(so.friends).map(([id, f]) => ({ user_id:id, status:f.status, incoming:!!f.incoming && f.status==='pending', notify:!!f.notify,
          known_as:knownAs(id), real_name:f.status==='accepted' ? (so.realNames[id] || null) : null, avatar_url:so.avatars[id] || null, since:f.since }));
      },
      async friendRequest(id){
        if(id===ME) throw new Error('That’s you!');
        if(!knownAs(id, true)) throw new Error('No one has that user ID. Check it and try again.');
        const so = social(), f = so.friends[id];
        if(f && f.status==='pending' && f.incoming){ f.status = 'accepted'; f.incoming = false; save(); return 'accepted'; }
        if(f) return f.status;
        so.friends[id] = { status:'pending', incoming:false, since:new Date().toISOString() }; save(); return 'pending';
      },
      async friendRespond(id, accept){
        const so = social(), f = so.friends[id]; if(!f || !f.incoming) return;
        if(accept){ f.status = 'accepted'; f.incoming = false; } else delete so.friends[id];
        save();
      },
      async friendRemove(id){ delete social().friends[id]; save(); },
      async friendNotify(id, on){ const f = social().friends[id]; if(f) f.notify = !!on; save(); },

      // ── friends chats ──
      async threads(){
        const so = social();
        return so.threads.filter(t => t.members.includes(ME)).map(t => {
          const msgs = so.msgs[t.id] || [], last = msgs[msgs.length-1];
          const read = so.read[t.id] || 0;
          return { id:t.id, kind:t.kind, name:t.name, owner:t.owner || null, muted:!!t.muted, created_at:t.created_at,
            members:t.members.map(id => ({ user_id:id, known_as:knownAs(id), avatar_url:so.avatars[id] || null,
              real_name:(id===ME || (so.friends[id] && so.friends[id].status==='accepted')) ? (so.realNames[id] || null) : null })),
            last_body:last && last.text, last_user:last && last.user_id, last_at:last && new Date(last.ts).toISOString(), last_deleted:!!(last && last.deleted),
            unread:msgs.filter(m => m.ts > read && m.user_id!==ME).length };
        }).sort((a, b) => new Date(b.last_at || b.created_at) - new Date(a.last_at || a.created_at));
      },
      async threadMessages(id){ return (social().msgs[id] || []).map(m => ({ ...m, thread_id:id })); },
      async dmOpen(id){
        const so = social();
        if(!(so.friends[id] && so.friends[id].status==='accepted')) throw new Error('You can only message friends.');
        let t = so.threads.find(x => x.kind==='dm' && x.members.includes(id) && x.members.includes(ME));
        if(!t){ t = { id:'th-'+uid().slice(0,8), kind:'dm', members:[ME, id], created_at:new Date().toISOString() }; so.threads.push(t); save(); }
        return t.id;
      },
      async groupCreate(name, ids){
        const t = { id:'th-'+uid().slice(0,8), kind:'group', name, members:[ME, ...ids], owner:ME, created_at:new Date().toISOString() };
        social().threads.push(t); save(); return t.id;
      },
      async groupAdd(tid, id){ const t = social().threads.find(x => x.id===tid); if(t && !t.members.includes(id)) t.members.push(id); save(); },
      async groupRename(tid, name){ const t = social().threads.find(x => x.id===tid); if(t) t.name = name; save(); },
      async groupLeave(tid){
        const so = social(), t = so.threads.find(x => x.id===tid); if(!t) return;
        t.members = t.members.filter(x => x!==ME);
        if(t.owner===ME) t.owner = t.members[0] || null;            // passes to whoever's been in longest
        save();
      },
      async groupRemove(tid, id){
        const t = social().threads.find(x => x.id===tid);
        if(!t || t.owner!==ME) throw new Error('Only the group’s owner can remove people.');
        t.members = t.members.filter(x => x!==id); save();
      },
      async threadMute(tid, on){ const t = social().threads.find(x => x.id===tid); if(t) t.muted = !!on; save(); },
      async threadRead(tid){ social().read[tid] = Date.now(); save(); },
      async sendMessage(tid, body){
        const so = social(), t = so.threads.find(x => x.id===tid);
        if(t && t.kind==='dm'){ const o = t.members.find(x => x!==ME); if(!(so.friends[o] && so.friends[o].status==='accepted')) throw new Error('You’re no longer friends.'); }
        const m = { id:uid(), user_id:ME, text:body.slice(0,1000), ts:Date.now() };
        (so.msgs[tid] = so.msgs[tid] || []).push(m); so.read[tid] = Date.now(); save();
        return { ...m, thread_id:tid };
      },
      async editMessage(id, body){
        const m = Object.values(social().msgs).flat().find(x => x.id===id);
        if(!m || m.user_id!==ME) throw new Error('You can only edit your own messages.');
        m.text = body.slice(0,1000); m.edited = true; save(); return { ...m };
      },
      async deleteMessage(id){
        const m = Object.values(social().msgs).flat().find(x => x.id===id);
        if(!m || m.user_id!==ME) throw new Error('You can only delete your own messages.');
        m.deleted = true; m.text = '·'; m.edited = false; save(); return { ...m };
      },

      // ── chat ──
      async chat(room, compId){ return roomList(room, compId).slice(); },
      async send(room, compId, text){
        const c = comp(compId);
        const msg = { id:uid(), user_id:ME, name:c.members[ME].display_name, comp_name:c.name, sport:c.sport, text:text.slice(0,280), ts:Date.now() };
        roomList(room, compId).push(msg);
        save();
        maybeReply(room, compId);
        return msg;
      },
      reset(){
        try{
          ['ft-mock-v1','ft-mock-v2','ft-mock-v3','ft-mock-v4','ft-mock-v5','ft-mock-v6','ft-mock-v7','ft-mock-v8','ft-mock-v9','ft-mock-v10','ft-mock-v11', STORE].forEach(k => localStorage.removeItem(k));
          Object.keys(localStorage).filter(k => k.startsWith('ft-slip-') || k.startsWith('ft-chat-read-')).forEach(k => localStorage.removeItem(k));
        }catch(e){}
      },
    };
  }
  // 22 players a side, shared by the markets and the live feed so names line up
  function mockSquads(seed){
    const FIRST = ['J.','T.','S.','M.','L.','C.','B.','N.','H.','R.','D.','K.','A.','P.','W.','G.'];
    const LAST  = ['Walker','Harding','McKay','Doyle','Brennan','Ashby','Pickett','Rowe','Langley','Sutton','Kirby','Mercer',
                   'Fallon','Draper','Quill','Hendry','Ablett','Cotchin','Riewoldt','Pendlebury','Selwood','Dangerfield',
                   'Bontempelli','Petracca','Oliver','Cripps','Macrae','Neale','Merrett','Heeney','Daicos','Gulden'];
    // 44 distinct names: surnames cycle every 32, and the second lap shifts the initial
    const nameAt = k => `${FIRST[(k + Math.floor(k/32)*5) % FIRST.length]} ${LAST[(k*3 + seed) % LAST.length]}`;
    return { home:Array.from({ length:22 }, (_,i) => nameAt(i)), away:Array.from({ length:22 }, (_,i) => nameAt(22+i)) };
  }
  // live feed snapshot: scoring events consistent with the quarter scores, plus player stats
  function mockLive(m, q, clockSecs, home, away, seed){
    if(m.sport==='nrl') return mockLiveNrl(m, q, clockSecs, home, away, seed);
    let s = seed*104729 % 233280;
    const rnd = () => (s = (s*9301 + 49297) % 233280) / 233280;
    const events = [];
    const add = (side, gb) => gb.forEach(([g,b], i) => {
      const pg = i ? gb[i-1][0] : 0, pb = i ? gb[i-1][1] : 0;
      const len = (i+1===q && m.status!=='concluded') ? clockSecs : QLEN - 60;
      const squad = m.squads[side];
      const scorer = () => squad[rnd()<.75 ? Math.floor(rnd()*6) : 6+Math.floor(rnd()*8)];
      for(let n=0; n<g-pg; n++) events.push({ team:side, type:'goal', q:i+1, secs:Math.floor(20+rnd()*(len-20)), player:scorer() });
      for(let n=0; n<b-pb; n++) events.push({ team:side, type:'behind', q:i+1, secs:Math.floor(20+rnd()*(len-20)), player:scorer() });
    });
    add('home', home); add('away', away);
    const progress = m.status==='concluded' ? 1 : ((q-1) + clockSecs/QLEN)/4;
    const players = [];
    ['home','away'].forEach(side => m.squads[side].forEach((name, i) => {
      const role = i<6 ? 'fwd' : i<14 ? 'mid' : 'def';
      const base = role==='mid' ? 22+rnd()*12 : role==='fwd' ? 9+rnd()*7 : 13+rnd()*8;
      const d = Math.round(base*progress);
      const k = Math.round(d*(0.5+rnd()*0.15)), h = d-k;
      const mk = Math.round((role==='fwd' ? 4+rnd()*4 : 2+rnd()*5)*progress);
      const t = Math.round((role==='mid' ? 3+rnd()*5 : 1+rnd()*4)*progress);
      const g = events.filter(e => e.player===name && e.team===side && e.type==='goal').length;
      const b = events.filter(e => e.player===name && e.team===side && e.type==='behind').length;
      players.push({ name, team:side, d, k, h, m:mk, t, g, b, af: 3*k + 2*h + 3*mk + 4*t + 6*g + b });
    }));
    return { q, clockSecs, home, away, events, players };
  }
  function mockMarkets(m, seed){
    if(m.sport==='nrl') return mockMarketsNrl(m, seed);
    let s = seed*7919 % 233280;
    const rnd = () => (s = (s*9301 + 49297) % 233280) / 233280;
    const px = p => Math.max(1.01, Math.round(0.94/p*100)/100);          // price from probability, with margin
    const ph = 0.28 + rnd()*0.44;
    const H = m.home_team, A = m.away_team;
    const line = Math.round((ph-0.5)*70) + 0.5;
    const tot = 160.5 + Math.round(rnd()*20);
    const ou = (point, extra={}) => [{ name:'Over', point, price:1.87, ...extra }, { name:'Under', point, price:1.93, ...extra }];
    const mk = {
      h2h:[{ name:H, price:px(ph) }, { name:A, price:px(1-ph) }],
      spreads:[{ name:H, point:-line, price:1.90 }, { name:A, point:line, price:1.90 }],
      totals:ou(tot),
      team_totals:[...ou(Math.round(tot*ph)+0.5, { description:H }), ...ou(Math.round(tot*(1-ph))+0.5, { description:A })],
    };
    ['q1','h1'].forEach(p => {
      mk['h2h_'+p] = [{ name:H, price:px(ph*0.9+0.05) }, { name:A, price:px((1-ph)*0.9+0.05) }];
      mk['totals_'+p] = ou(Math.round(tot*(p==='q1'?0.25:0.5))+0.5);
    });
    const players = [...m.squads.home.map((n,i) => ({ n, i })), ...m.squads.away.map((n,i) => ({ n, i }))];
    const yes = (list, lo, hi) => list.map(p => ({ name:'Yes', description:p.n, price:Math.round((lo + rnd()*(hi-lo))*100)/100 }));
    const overs = (list, points, base) => list.flatMap(p => points.map((pt,j) => ({ name:'Over', description:p.n, point:pt,
      price:Math.round((base[j] + rnd()*base[j]*0.5)*100)/100 })));
    const fwds = players.filter(p => p.i<6), mids = players.filter(p => p.i>=6 && p.i<14);
    mk.player_goal_scorer_first = yes(players, 7, 41);
    mk.player_goal_scorer_anytime = yes(players, 1.45, 9);
    mk.player_goals_scored_over = overs(fwds, [1.5, 2.5, 3.5], [2.1, 4.2, 8]);
    mk.player_disposals_over = overs(mids, [19.5, 24.5, 29.5], [1.25, 1.9, 3.4]);
    mk.player_disposals = mids.slice(0,6).flatMap((p,i) => ou(22.5 + (i%3)*3, { description:p.n }));
    mk.player_marks_over = overs(players.filter(p => p.i<8), [4.5, 6.5], [1.5, 2.8]);
    mk.player_tackles_over = overs(mids, [3.5, 5.5], [1.6, 3.1]);
    mk.player_marks_most = yes(players.filter(p => p.i<10), 5, 21);
    mk.player_afl_fantasy_points_over = overs(mids, [89.5, 109.5], [1.6, 2.9]);
    return { markets:mk, bookmaker:'Sportsbet (mock)', pulled_at:new Date(Date.now()-3*3600e3).toISOString() };
  }

  // NRL live feed snapshot: tries / conversions / penalty goals consistent with the half scores,
  // plus player stats. home/away = cumulative points at the end of each half played.
  function mockLiveNrl(m, q, clockSecs, home, away, seed){
    let s = seed*104729 % 233280;
    const rnd = () => (s = (s*9301 + 49297) % 233280) / 233280;
    const LEN = SPORT_INFO.nrl.periodLen;
    const events = [];
    const add = (side, per) => per.forEach((pts, i) => {
      let d = pts - (i ? per[i-1] : 0);
      const len = (i+1===q && m.status!=='concluded') ? clockSecs : LEN - 60;
      const squad = m.squads[side].slice(0, 17);
      const kicker = squad[6];                                        // the halfback kicks the goals
      const at = () => Math.floor(30 + rnd()*(len-120));
      const tryScorer = () => squad[rnd()<.8 ? Math.floor(rnd()*9) : 9+Math.floor(rnd()*8)];
      // break the half's points into converted tries, tries, penalty goals and a field goal
      while(d >= 6){ const t = at(); events.push({ team:side, type:'try', q:i+1, secs:t, player:tryScorer() },
                                                  { team:side, type:'conversion', q:i+1, secs:t+60, player:kicker }); d -= 6; }
      if(d >= 4){ events.push({ team:side, type:'try', q:i+1, secs:at(), player:tryScorer() }); d -= 4; }
      while(d >= 2){ events.push({ team:side, type:'penalty', q:i+1, secs:at(), player:kicker }); d -= 2; }
      if(d === 1) events.push({ team:side, type:'field_goal', q:i+1, secs:at(), player:kicker });
    });
    add('home', home); add('away', away);
    const progress = m.status==='concluded' ? 1 : ((q-1) + clockSecs/LEN)/2;
    const players = [];
    ['home','away'].forEach(side => m.squads[side].slice(0, 17).forEach((name, i) => {
      const fwd = i>=9;                                               // 1–9 backs, 10–17 forwards
      const rm = Math.round((fwd ? 90+rnd()*110 : 70+rnd()*120)*progress);
      const t  = Math.round((fwd ? 22+rnd()*22 : 5+rnd()*12)*progress);
      const tr = events.filter(e => e.player===name && e.team===side && e.type==='try').length;
      players.push({ name, team:side, rm, t, tr,
        lb:Math.round((fwd ? rnd()*1.2 : rnd()*2.5)*progress), tb:Math.round((1+rnd()*5)*progress), o:Math.round(rnd()*3*progress) });
    }));
    return { q, clockSecs, home, away, events, players };
  }
  function mockMarketsNrl(m, seed){
    let s = seed*7919 % 233280;
    const rnd = () => (s = (s*9301 + 49297) % 233280) / 233280;
    const px = p => Math.max(1.01, Math.round(0.94/p*100)/100);
    const ph = 0.28 + rnd()*0.44;
    const H = m.home_team, A = m.away_team;
    const line = Math.round((ph-0.5)*36) + 0.5;
    const tot = 38.5 + Math.round(rnd()*10);
    const ou = (point, extra={}) => [{ name:'Over', point, price:1.87, ...extra }, { name:'Under', point, price:1.93, ...extra }];
    const mk = {
      h2h:[{ name:H, price:px(ph) }, { name:A, price:px(1-ph) }],
      spreads:[{ name:H, point:-line, price:1.90 }, { name:A, point:line, price:1.90 }],
      totals:ou(tot),
      team_totals:[...ou(Math.round(tot*ph)+0.5, { description:H }), ...ou(Math.round(tot*(1-ph))+0.5, { description:A })],
      h2h_h1:[{ name:H, price:px(ph*0.9+0.05) }, { name:A, price:px((1-ph)*0.9+0.05) }],
      totals_h1:ou(Math.round(tot*0.5)+0.5),
    };
    const players = [...m.squads.home.slice(0,17).map((n,i) => ({ n, i })), ...m.squads.away.slice(0,17).map((n,i) => ({ n, i }))];
    const yes = (list, lo, hi) => list.map(p => ({ name:'Yes', description:p.n, price:Math.round((lo + rnd()*(hi-lo))*100)/100 }));
    const backs = players.filter(p => p.i<9);
    mk.player_try_scorer_first = yes(players, 6, 41);
    mk.player_try_scorer_anytime = yes(players, 1.7, 9);
    mk.player_try_scorer_last = yes(players, 6, 41);
    mk.player_try_scorer_over = backs.map(p => ({ name:'Over', description:p.n, point:1.5, price:Math.round((5 + rnd()*10)*100)/100 }));
    return { markets:mk, bookmaker:'Sportsbet (mock)', pulled_at:new Date(Date.now()-3*3600e3).toISOString() };
  }

};
