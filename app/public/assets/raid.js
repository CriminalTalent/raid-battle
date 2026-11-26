// 네 창(로비·관전·참여·관리자)이 함께 쓰는 도우미
const COLS = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];
const ROWS = [1, 2, 3, 4, 5, 6, 7, 8];
const ARROW = { '상': '▲', '하': '▼', '좌': '◀', '우': '▶' };
const PHASE = { lobby: '참여자 준비 중', prep: '시작 위치 입력', boss_command: '보스 행동 대기 (진행자가 고르는 중)', announcing: '라운드 준비', battle: '행동 입력', settling: '정산 중' };

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pct = (hp, max) => Math.max(0, Math.min(100, Math.round(hp / Math.max(max, 1) * 100)));
const short = s => [...String(s)].slice(0, 2).join('');
const $ = id => document.getElementById(id);

/* 라이트/다크 모드 (처음엔 컴퓨터 설정을 따름, 버튼으로 바꾸면 기억) */
(function () {
  const saved = localStorage.getItem('raidTheme');
  const sys = window.matchMedia && matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
  document.documentElement.dataset.theme = saved || sys;
})();
function toggleTheme() {
  const t = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
  document.documentElement.dataset.theme = t; localStorage.setItem('raidTheme', t);
  const b = $('themebtn'); if (b) b.textContent = t === 'light' ? '☾' : '☀';
}
addEventListener('storage', e => { if (e.key === 'raidTheme' && e.newValue) document.documentElement.dataset.theme = e.newValue; });

/* 공통 상단 메뉴 */
function navBar(active, extra = '') {
  const items = [['/', '로비', 'lobby'], ['/watch', '관전', 'watch']];
  if (isAdmin() || active === 'admin') items.push(['/admin', '관리자', 'admin']);
  const el = document.createElement('nav');
  el.className = 'nav';
  el.innerHTML = `<span class="brand">RAID</span>` +
    items.map(([href, label, key]) => `<a class="item ${active === key ? 'on' : ''}" href="${href}" ${key === 'admin' && active !== 'admin' ? 'target="raid-admin"' : ''}>${label}</a>`).join('') +
    extra + `<span class="live"><span class="dot" id="livedot"></span><span id="livetext">연결 중</span></span>` +
    `<button class="themebtn ghost" id="themebtn" title="라이트/다크 모드">${document.documentElement.dataset.theme === 'light' ? '☾' : '☀'}</button>`;
  document.body.prepend(el);
  $('themebtn').onclick = toggleTheme;
}

/* 다른 창에서 무언가 바뀌면 곧바로 onChange 를 부른다.
   서버는 변화가 생길 때까지 답을 미루고(/api/wait), 같은 브라우저의 여러 창은
   그중 한 창만 서버에 묻고 나머지 창에 알려 준다 (브라우저 동시 연결 수 제한 대비). */
function live(onChange) {
  let v = -1, busy = false, again = false;
  const set = ok => { const d = $('livedot'), t = $('livetext'); if (d) d.classList.toggle('on', ok); if (t) t.textContent = ok ? '실시간 연결' : '연결 끊김, 다시 시도 중'; };
  const run = async () => {
    if (busy) { again = true; return; }
    busy = true;
    try { await onChange(); set(true); } catch (e) { set(false); }
    busy = false;
    if (again) { again = false; run(); }
  };
  const seen = nv => { if (nv !== v) { v = nv; run(); } else set(true); };
  const ch = 'BroadcastChannel' in window ? new BroadcastChannel('raid-live') : null;
  if (ch) ch.onmessage = e => e.data && e.data.v != null ? seen(e.data.v) : e.data === 'down' && set(false);
  async function poll() {
    let lv = 0, fails = 0;
    for (;;) {
      try {
        const r = await api('/api/wait?v=' + lv);
        lv = r.v; fails = 0; ch?.postMessage({ v: r.v }); seen(r.v);
      } catch (e) {
        set(false); ch?.postMessage('down'); fails++;
        await new Promise(res => setTimeout(res, Math.min(5000, 800 * fails)));
      }
    }
  }
  run();   // 처음 한 번은 바로 불러오기
  if (navigator.locks && ch) navigator.locks.request('raid-live', poll);  // 한 창만 서버에 묻기
  else poll();
}

function parsePos(p) {
  const m = /^([A-G])([1-8])$/.exec(String(p || '').toUpperCase());
  return m ? [COLS.indexOf(m[1]), Number(m[2]) - 1] : null;
}
function chebyshev(a, b) { const p = parsePos(a), q = parsePos(b); return p && q ? Math.max(Math.abs(p[0] - q[0]), Math.abs(p[1] - q[1])) : 99; }
function manhattan(a, b) { const p = parsePos(a), q = parsePos(b); return p && q ? Math.abs(p[0] - q[0]) + Math.abs(p[1] - q[1]) : 99; }
// 기존 규칙: "근접" = 대각선 포함 1칸, 숫자 사거리 = 가로+세로 칸 수
function inRange(from, to, range) {
  if (range === '근접') return chebyshev(from, to) <= 1;
  if (range === '제한 없음') return true;
  const n = parseInt(range, 10);
  return Number.isFinite(n) ? manhattan(from, to) <= n : false;
}

// 격자. opts: { me, picks:Set, pickable:fn(pos), inrange:Set }
function gridHTML(b, opts = {}) {
  const c = b.creature || {};
  const dead = new Set(b.dead || []), done = new Set(b.submitted || []);
  const bossCells = new Set(c.cells || []), skillCells = new Set(c.skill_cells || []);
  const byPos = {};
  (b.runners || []).forEach(r => { if (!dead.has(r.name) && r.hp > 0 && r.pos) byPos[r.pos] = r; });
  let h = '<div class="grid"><div class="lbl"></div>' + COLS.map(x => `<div class="lbl">${x}</div>`).join('');
  ROWS.forEach(y => {
    h += `<div class="lbl">${y}</div>`;
    COLS.forEach(x => {
      const pos = x + y, r = byPos[pos];
      const cls = ['cell', bossCells.has(pos) && 'boss', skillCells.has(pos) && 'skill', opts.inrange?.has(pos) && 'inrange',
        opts.pickable?.(pos) && 'pick', opts.picks?.has(pos) && 'picked'].filter(Boolean).join(' ');
      let inner = '';
      const hpb = (hp, max, boss) => `<span class="hpb${boss ? ' boss' : ''}${pct(hp, max) <= 30 ? ' low' : ''}" title="${hp} / ${max}"><i style="width:${pct(hp, max)}%"></i></span>`;
      if (r) inner = hpb(r.hp, r.max_hp) + `<div class="token ${esc(r.role || '')} ${r.img ? 'pic' : ''} ${r.name === opts.me ? 'me' : ''} ${done.has(r.name) ? 'done' : ''}" title="${esc(r.display)}${r.role ? ' · ' + esc(r.role) : ''}"${r.img ? ` style="background-image:url('${esc(r.img)}')"` : ''}>${r.img ? '' : esc(short(r.display))}</div>`;
      else if (pos === c.pos) inner = hpb(c.hp, c.max_hp, true) + `${c.img ? `<span class="bosspic" style="background-image:url('${esc(c.img)}')"></span>` : esc(short(c.name))}<span class="arrow f-${esc(c.facing || '')}">${ARROW[c.facing] || ''}</span>`;
      h += `<div class="${cls}" data-pos="${pos}" title="${pos}">${inner}</div>`;
    });
  });
  return h + '</div>';
}
function bindGrid(el, onPick) { el?.querySelectorAll('.cell.pick').forEach(n => n.onclick = ev => onPick(n.dataset.pos, ev)); }

function bossHTML(b) {
  const c = b.creature || {};
  return `<div class="unit"><div class="top"><span class="n"><b>${esc(c.name)}</b>${c.skill ? `<span class="tag warn">${esc(c.skill)}</span>` : ''}</span><span class="hp">${c.hp} / ${c.max_hp}</span></div><div class="bar boss"><i style="width:${pct(c.hp, c.max_hp)}%"></i></div></div>`;
}
function runnersHTML(b, me) {
  const dead = new Set(b.dead || []), done = new Set(b.submitted || []);
  return (b.runners || []).map(r => {
    const isDead = dead.has(r.name) || r.hp <= 0;
    const tag = isDead ? '<span class="tag bad">전투불능</span>' : (b.phase === 'battle' ? (done.has(r.name) ? '<span class="tag ok">제출</span>' : '<span class="tag">대기</span>') : '');
    return `<div class="unit ${isDead ? 'dead' : ''}"><div class="top"><span class="n">${esc(r.display)}${r.name === me ? ' <span class="sub">(나)</span>' : ''} ${tag}</span><span class="hp">${r.hp} / ${r.max_hp}</span></div><div class="bar"><i style="width:${pct(r.hp, r.max_hp)}%"></i></div></div>`;
  }).join('');
}
function statusHTML(b, skew) {
  return `<div class="status"><span><b>${b.phase === 'lobby' ? '대기' : b.phase === 'prep' ? '준비' : b.round + 'R'}</b> <span class="sub">${esc(b.active ? (PHASE[b.phase] || '') : '전투 종료')}</span></span><span class="timer" data-timer="${esc(b.id)}">${timerText(b, skew)}</span></div>`;
}
function logHTML(b, limit = 30) {
  return (b.log || []).slice(-limit).reverse().map(l =>
    `<article><time>${l.round}R · ${new Date(l.at * 1000).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</time>${esc(l.text)}</article>`
  ).join('') || '<div class="empty">아직 기록이 없습니다.</div>';
}
function timerText(b, skew) {
  if (!b || !b.active || (b.phase !== 'battle' && b.phase !== 'prep')) return '';
  const left = Math.max(0, b.round_started_at + b.action_wait - (Math.floor(Date.now() / 1000) + (skew || 0)));
  const n = (b.submitted || []).length;
  return `${b.phase === 'battle' ? `제출 ${n}/${b.required} · ` : ''}${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
}
function startTimers(getBattles, getSkew) {
  setInterval(() => {
    document.querySelectorAll('[data-timer]').forEach(el => { const b = getBattles().find(x => x.id === el.dataset.timer); el.textContent = timerText(b, getSkew()); });
    document.querySelectorAll('[data-bigtimer]').forEach(el => { const b = getBattles().find(x => x.id === el.dataset.bigtimer); el.textContent = bigTimer(b, getSkew()); });
    document.querySelectorAll('[data-ring]').forEach(el => { const b = getBattles().find(x => x.id === el.dataset.ring); setRing(el, b, getSkew()); });
  }, 1000);
}

async function api(path, body, headers = {}) {
  const res = await fetch(path, body === undefined ? { headers, cache: 'no-store' } : {
    method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, headers), body: JSON.stringify(body)
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) { const e = new Error(data.error || `오류 (${res.status})`); e.login = !!data.login; throw e; }
  return data;
}

/* 아바타 (이미지 주소가 있으면 사진, 없으면 역할 색 동그라미) */
function avatarHTML(name, role, img, cls = '') {
  const st = img ? ` style="background-image:url('${esc(img)}')"` : '';
  return `<div class="av ${esc(role || '')} ${cls}"${st}>${img ? '' : esc(short(name))}</div>`;
}
/* 팀 패널: 러너 한 명씩 아바타·역할·체력·상태 */
function teamHTML(b, me) {
  const dead = new Set(b.dead || []), done = new Set(b.submitted || []);
  const list = (b.runners || []).map(r => {
    const isDead = dead.has(r.name) || r.hp <= 0;
    const st = isDead ? '<span class="tag bad">전투불능</span>' : (b.phase === 'battle' ? (done.has(r.name) ? '<span class="tag ok">제출</span>' : '<span class="tag">대기</span>') : '');
    return `<div class="member ${r.name === me ? 'me' : ''} ${isDead ? 'dead' : ''}">${avatarHTML(r.display, r.role, r.img)}
      <div class="body"><div class="line1">${esc(r.display)} ${r.role ? `<span class="role ${esc(r.role)}">${esc(r.role)}</span>` : ''}<span class="hp">${r.hp}/${r.max_hp}</span></div>
      <div class="bar"><i style="width:${pct(r.hp, r.max_hp)}%"></i></div><div class="act">${r.pos ? esc(r.pos) + ' · ' : ''}${st}</div></div></div>`;
  }).join('');
  return list ? `<div class="teamlist">${list}</div>` : '<div class="empty">러너 없음</div>';
}
function bossCardHTML(b) {
  const c = b.creature || {};
  return `<div class="member">${avatarHTML(c.name, '', c.img, 'lg boss')}<div class="body"><div class="line1">${esc(c.name)}<span class="hp">${c.hp}/${c.max_hp}</span></div>
    <div class="bar boss"><i style="width:${pct(c.hp, c.max_hp)}%"></i></div>
    <div class="act">${c.pos ? '머리 ' + esc(c.pos) + ' ' + (ARROW[c.facing] || '') + ' · ' : ''}${esc(c.size || '')}${c.skill ? ` · <span class="tag warn">${esc(c.skill)}</span>` : ''}</div></div></div>
    ${c.omen ? `<div class="omen">⚠ ${esc(c.omen)}</div>` : ''}`;
}
function bigTimer(b, skew) {
  if (!b || !b.active || (b.phase !== 'battle' && b.phase !== 'prep')) return '';
  const left = Math.max(0, b.round_started_at + b.action_wait - (Math.floor(Date.now() / 1000) + (skew || 0)));
  return `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
}

/* 관리자로 로그인한 브라우저인지 (화면 표시용 표식일 뿐, 권한 확인은 서버가 한다) */
function isAdmin() { return /(?:^|;\s*)raid_is_admin=1/.test(document.cookie); }

/* 응원: 관전자가 누른 버튼 집계와 최근 기록 */
const CHEERS = { clap: '박수', fire: '힘내!', guard: '버텨!', star: '멋져요!', wow: '조심!' };
function cheerFeedHTML(b, limit = 8) {
  const list = (b.cheers?.recent || []).slice(0, limit);
  const w = b.watchers || [];
  return `<div class="cheerfeed">${list.map(c => `<div><b>${esc(c.name)}</b>${esc(CHEERS[c.kind] || c.text)}</div>`).join('') || '<div class="sub" style="border:0">아직 응원이 없어요.</div>'}</div>
    <div class="watchers">관전 중 ${w.length}명${w.length ? ' · ' + w.slice(0, 12).map(esc).join(', ') + (w.length > 12 ? ' …' : '') : ''}</div>`;
}

/* 원형 타이머: 남은 시간만큼 고리가 줄어든다 */
const RING_C = 2 * Math.PI * 52;
function ringHTML(b, skew) {
  return `<div class="ring" data-ring="${esc(b.id)}"><svg viewBox="0 0 120 120"><circle class="ticks" cx="60" cy="60" r="58"/><circle class="track" cx="60" cy="60" r="52"/><circle class="arc" cx="60" cy="60" r="52" stroke-dasharray="${RING_C}" stroke-dashoffset="0" transform="rotate(-90 60 60)"/></svg><span class="t"></span></div>`;
}
function setRing(el, b, skew) {
  const t = el.querySelector('.t'), arc = el.querySelector('.arc');
  if (!b || !b.active || (b.phase !== 'battle' && b.phase !== 'prep')) {
    t.textContent = b && !b.active ? '종료' : '··'; arc.style.strokeDashoffset = RING_C; return;
  }
  const left = Math.max(0, b.round_started_at + b.action_wait - (Math.floor(Date.now() / 1000) + (skew || 0)));
  t.textContent = `${String(Math.floor(left / 60)).padStart(2, '0')}:${String(left % 60).padStart(2, '0')}`;
  arc.style.strokeDashoffset = RING_C * (1 - left / Math.max(b.action_wait, 1));
  el.classList.toggle('low', left <= 30);
}
function initRings(getBattles, getSkew) {
  document.querySelectorAll('[data-ring]').forEach(el => setRing(el, getBattles().find(x => x.id === el.dataset.ring), getSkew()));
}

/* 채팅: 참여자·진행자는 보내고, 관전자는 보기만 한다. mine = 내 메시지 표시용 키 */
function chatHTML(b, { mine = '', canSend = false, note = '' } = {}) {
  const fmt = at => new Date(at * 1000).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false });
  const list = (b.chat || []).map(m => `<div class="cm ${m.who === mine ? 'mine' : ''} ${m.role === 'admin' ? 'gm' : ''}">
      <div class="h"><b>${esc(m.name)}</b><time>${fmt(m.at)}</time></div><div class="x">${esc(m.text)}</div></div>`).join('');
  return `<div class="chatbox"><div class="chatlist" data-chatlist="${esc(b.id)}">${list || '<div class="empty" style="padding:14px">아직 대화가 없어요.</div>'}</div>
    ${canSend ? `<form class="chatform" data-chatform="${esc(b.id)}"><input id="chat-${esc(b.id)}" maxlength="200" autocomplete="off" placeholder="메시지 (200자까지)"><button class="primary sm">전송</button></form>` : `<div class="sub" style="margin-top:6px">${esc(note || '관전자는 채팅을 볼 수만 있어요.')}</div>`}</div>`;
}
function bindChat(send) {
  document.querySelectorAll('[data-chatlist]').forEach(el => { el.scrollTop = el.scrollHeight; });
  document.querySelectorAll('[data-chatform]').forEach(f => f.onsubmit = async ev => {
    ev.preventDefault();
    const inp = f.querySelector('input'), text = inp.value.trim(); if (!text) return;
    inp.value = '';
    try { await send(f.dataset.chatform, text); }
    catch (e) { const i = document.getElementById(inp.id) || inp; i.value = text; i.setCustomValidity(e.message); i.reportValidity(); setTimeout(() => i.setCustomValidity(''), 1500); }
  });
}

/* 화면을 다시 그려도 입력 중이던 칸(값·커서)이 지워지지 않게 */
function keepInputs(draw) {
  const vals = {}, a = document.activeElement;
  document.querySelectorAll('input[id]:not([type=checkbox]), textarea[id]').forEach(i => { vals[i.id] = i.value; });
  const focus = a && a.id ? [a.id, a.selectionStart, a.selectionEnd] : null;
  draw();
  Object.entries(vals).forEach(([id, v]) => { const i = document.getElementById(id); if (i && i.value !== v && i.type !== 'file') i.value = v; });
  if (focus) { const i = document.getElementById(focus[0]); if (i) { i.focus(); try { i.setSelectionRange(focus[1], focus[2]); } catch {} } }
}

/* 발동 오버레이: "(누구) 스킬 「이름」 발동", 보스 전조, 보스 스킬, 전투 결과를 화면 가운데 잠깐 띄운다.
   처음 연 순간의 지난 알림은 다시 띄우지 않는다. */
const ovl = { seen: {}, queue: [], busy: false };
function overlayEvents(battles) {
  (battles || []).forEach(b => {
    ovl.battles = ovl.battles || {}; ovl.battles[b.id] = b;
    const evs = b.events || [], max = evs.reduce((m, e) => Math.max(m, e.seq), 0);
    if (!(b.id in ovl.seen)) { ovl.seen[b.id] = max; return; }
    evs.filter(e => e.seq > ovl.seen[b.id]).sort((x, y) => x.seq - y.seq).forEach(e => ovl.queue.push(e));
    ovl.seen[b.id] = Math.max(ovl.seen[b.id], max);
  });
  if (ovl.queue.length > 8) ovl.queue = ovl.queue.slice(-8);
  showNextOverlay();
}
function showNextOverlay() {
  if (ovl.busy || !ovl.queue.length) return;
  const e = ovl.queue.shift(); ovl.busy = true;
  if (e.kind === 'end') return showResult(e);
  const T = {
    skill: [esc(e.who), `스킬 「${esc(e.name)}」 발동`, e.text ? '대상 ' + esc(e.text) : ''],
    boss: [esc(e.who), `보스 스킬 「${esc(e.name)}」 발동`, e.text ? '대상 ' + esc(e.text) : ''],
    target: ['◎ 표적', `${esc(e.text)}`, `${esc(e.who)}이(가) 노립니다${e.name ? ' · 「' + esc(e.name) + '」' : ''}`],
    omen: ['⚠ 전조', esc(e.text), e.name ? `${esc(e.who)} · 「${esc(e.name)}」` : esc(e.who)],
    end: [esc(e.who), esc(e.name), '']
  }[e.kind] || [esc(e.who), esc(e.name), ''];
  const el = document.createElement('div');
  el.className = `ovl k-${e.kind}`;
  el.innerHTML = `<div class="ovl-in"><span class="chev">❮❮❮</span><div class="ovl-txt"><div class="ovl-who">${T[0]}</div><div class="ovl-main">${T[1]}</div>${T[2] ? `<div class="ovl-sub">${T[2]}</div>` : ''}</div><span class="chev">❯❯❯</span></div>`;
  el.onclick = () => el.remove();
  document.body.appendChild(el);
  requestAnimationFrame(() => el.classList.add('show'));
  const ms = e.kind === 'omen' || e.kind === 'target' ? 3200 : 2000;
  setTimeout(() => { el.classList.remove('show'); setTimeout(() => { el.remove(); ovl.busy = false; showNextOverlay(); }, 300); }, ms);
}

/* 마우스 옆에 뜨는 작은 창. html 을 넣고, 바깥을 누르면 닫힌다. 닫는 함수(close)를 돌려준다 */
function popAt(ev, html, { keepOnGrid = false } = {}) {
  document.querySelector('.pop')?.remove();
  const d = document.createElement('div'); d.className = 'pop'; d.innerHTML = html;
  document.body.appendChild(d);
  const w = d.offsetWidth, h = d.offsetHeight, x = ev.clientX, y = ev.clientY;
  d.style.left = Math.max(8, Math.min(x + 12, innerWidth - w - 8)) + 'px';
  d.style.top = Math.max(8, Math.min(y + 12, innerHeight - h - 8)) + 'px';
  const close = () => { d.remove(); removeEventListener('mousedown', out, true); };
  const out = e => { if (!d.contains(e.target) && !(keepOnGrid && e.target.closest?.('.cell.pick'))) close(); };
  setTimeout(() => addEventListener('mousedown', out, true));
  d._close = close;
  return d;
}
/* Yes/No 확인창 */
function confirmPop(ev, text, onYes) {
  const d = popAt(ev, `<div>${esc(text)}</div><div class="btns"><button class="primary sm" data-y>Yes</button><button class="sm" data-n>No</button></div>`);
  d.querySelector('[data-y]').onclick = () => { d._close(); onYes(); };
  d.querySelector('[data-n]').onclick = d._close;
}
/* 고르기 창: items = [{ value, label, note, disabled }]. max>1 이면 여러 개 고르고 [다음] */
function choicePop(ev, title, items, onPick, { max = 1 } = {}) {
  const chosen = new Set();
  const d = popAt(ev, `<div class="pop-t">${esc(title)}</div><div class="pop-list">${items.map((it, i) =>
    `<button class="sm" data-i="${i}" ${it.disabled ? 'disabled' : ''}>${esc(it.label)}${it.note ? ` <span class="tag">${esc(it.note)}</span>` : ''}</button>`).join('')}</div>
    <div class="btns">${max > 1 ? `<button class="primary sm" data-next disabled>다음</button>` : ''}<button class="sm" data-n>취소</button></div>`);
  const next = d.querySelector('[data-next]');
  d.querySelectorAll('[data-i]').forEach(b => b.onclick = e => {
    const v = items[+b.dataset.i].value;
    if (max <= 1) { d._close(); return onPick([v], e); }
    if (chosen.has(v)) chosen.delete(v); else if (chosen.size < max) chosen.add(v);
    b.classList.toggle('on', chosen.has(v)); next.disabled = !chosen.size;
  });
  if (next) next.onclick = e => { d._close(); onPick([...chosen], e); };
  d.querySelector('[data-n]').onclick = d._close;
}
/* 안내만 띄우는 창 (격자에서 칸 고르기 등) */
function hintPop(ev, text) {
  const d = popAt(ev, `<div>${esc(text)}</div>`, { keepOnGrid: true });
  return d;
}

/* 전투 결과 창: 승리자 + [확인] + [전투 기록 보기] */
function showResult(e) {
  const win = e.name === '승리', lose = e.name === '패배';
  const w = (e.winners || []);
  const d = document.createElement('div'); d.className = 'result-bg';
  d.innerHTML = `<div class="result ${win ? 'win' : lose ? 'lose' : ''}">
    <div class="r-k">BATTLE RESULT</div>
    <div class="r-t">${win ? '승리' : lose ? '패배' : '전투 종료'}</div>
    <div class="r-sub">${esc(e.who)}${win ? ' 처치!' : lose ? '에게 전원 전투불능' : ''}</div>
    ${w.length ? `<div class="r-sec">승리자</div><div class="r-names">${w.map(n => `<span>${esc(n)}</span>`).join('')}</div>` : ''}
    <pre class="r-text">${esc(String(e.text || '').replace(/^\[[^\]]+\][^\n]*\n?/, '').trim())}</pre>
    <div class="btns" style="justify-content:center;margin-top:12px"><button class="primary" data-ok>확인</button><button data-log>전투 기록 보기</button></div>
    <div class="r-log" hidden></div></div>`;
  document.body.appendChild(d);
  const done = () => { d.remove(); ovl.busy = false; showNextOverlay(); };
  d.querySelector('[data-ok]').onclick = done;
  d.querySelector('[data-log]').onclick = () => {
    const box = d.querySelector('.r-log'), b = (ovl.battles || {})[e.bid] || {};
    box.hidden = !box.hidden;
    box.innerHTML = (b.log || []).map(l => `<article><time>${l.round}R</time>${esc(l.text)}</article>`).join('') || '<div class="empty">기록이 없습니다.</div>';
  };
}
