import Foundation

/// Пульт у браузері — одна сторінка, яку віддає сама програма.
///
/// Власник: «далее сделать веб приложение для полноценного пользования из
/// браузера компьютера или планшета». Сторінка говорить тим самим каналом,
/// що й телефон і планшет (`/api/…`), і має ту саму розкладку, що й планшет:
/// вкладки програми, зал з указкою й наближенням, План та Історія, кнопки
/// залу. Жодних сторонніх бібліотек і звернень в інтернет — у церковній
/// мережі його часто немає.
///
/// Сторінка лежить тут рядком, а не файлом у пакеті: так її не загубить
/// жодна збірка, а оновлюється вона разом із програмою.
enum RemoteWebPage {
    static let html = #"""
<!doctype html>
<html lang="uk">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Слово — пульт у браузері</title>
<style>
:root { --bg:#101418; --panel:#16202c; --head:#1e2a3a; --line:#26303c; --text:#f2f4f7; --dim:#9aa4b2; --accent:#4c8dff; --current:#24344a; --danger:#ff6b6b; }
* { box-sizing:border-box; }
html, body { margin:0; height:100%; background:var(--bg); color:var(--text); font:15px/1.35 -apple-system, "Segoe UI", Roboto, sans-serif; }
body { display:flex; flex-direction:column; }
button { font:inherit; color:var(--text); background:#3a4250; border:0; border-radius:6px; padding:8px 12px; cursor:pointer; }
button:hover { background:#4a5364; }
button.on { color:var(--accent); }
button.big { font-size:18px; padding:14px 8px; flex:1; margin:4px; }
input, select, textarea { font:inherit; color:var(--text); background:#0c1117; border:1px solid var(--line); border-radius:6px; padding:7px 9px; }
textarea { width:100%; resize:vertical; }
header { display:flex; align-items:center; gap:10px; background:var(--head); padding:6px 12px; }
header #status { flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
nav { display:flex; background:var(--panel); }
nav button { flex:1; background:transparent; border-radius:0; padding:10px 4px; }
nav button.chosen { color:var(--accent); }
main { flex:1; display:grid; grid-template-columns:4fr 5fr 3fr; min-height:0; }
section { display:flex; flex-direction:column; min-height:0; padding:8px; }
#center { background:#0b0e12; }
.list { flex:1; overflow:auto; margin:0; padding:0; list-style:none; }
.list li { padding:9px 10px; border-bottom:1px solid var(--line); cursor:pointer; }
.list li:hover { background:#1b2533; }
.list li.current { background:var(--current); }
.list li small { display:block; color:var(--dim); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.row { display:flex; gap:6px; align-items:center; margin-bottom:6px; flex-wrap:wrap; }
.row > .grow { flex:1; min-width:120px; }
.note { color:var(--dim); font-size:13px; margin:4px 0; }
.grid { flex:1; overflow:auto; display:grid; grid-template-columns:repeat(auto-fill, minmax(150px, 1fr)); gap:6px; align-content:start; }
.grid div { cursor:pointer; padding:3px; border-radius:6px; }
.grid div.current { background:var(--current); }
.grid img { width:100%; aspect-ratio:16/9; object-fit:contain; background:#000; display:block; }
.grid span { font-size:12px; display:block; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.chapters { flex:1; overflow:auto; display:grid; grid-template-columns:repeat(auto-fill, minmax(52px, 1fr)); gap:6px; align-content:start; }
.panel { display:none; flex:1; flex-direction:column; min-height:0; }
.panel.shown { display:flex; }
#hallBox { position:relative; flex:1; background:#000; margin-top:4px; min-height:160px; }
#hall { position:absolute; inset:0; width:100%; height:100%; touch-action:none; cursor:crosshair; }
#hallNote { position:absolute; left:0; right:0; top:45%; text-align:center; color:var(--dim); font-size:18px; pointer-events:none; }
#hallCaption { font-weight:bold; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
#liveText { padding-top:6px; max-height:5.5em; overflow:hidden; white-space:pre-line; }
#previewText { color:var(--dim); font-size:13px; max-height:2.8em; overflow:hidden; }
footer { display:flex; padding:4px; }
#black.on { color:var(--danger); }
.verse b { color:var(--accent); margin-right:6px; }
#pinBox { position:fixed; inset:0; background:rgba(0,0,0,.6); display:none; align-items:center; justify-content:center; }
#pinBox.shown { display:flex; }
#pinBox div { background:var(--head); padding:20px; border-radius:10px; display:flex; flex-direction:column; gap:10px; min-width:280px; }
/* «Лише перегляд»: тільки зал — без вкладок, списків і кнопок. */
body.view-only #tabs, body.view-only #left, body.view-only #right, body.view-only footer,
body.view-only #zoomOff { display:none; }
body.view-only main { grid-template-columns:1fr; }
#androidBox { position:fixed; inset:0; background:rgba(0,0,0,.6); display:none; align-items:center; justify-content:center; padding:12px; }
#androidBox.shown { display:flex; }
#androidBox > div { background:var(--head); padding:20px; border-radius:10px; max-width:560px; width:100%; display:flex; flex-direction:column; gap:12px; }
.app { display:flex; gap:12px; align-items:center; }
.app > div { flex:1; }
.app a { color:var(--text); background:#3a4250; border-radius:6px; padding:10px 14px; text-decoration:none; white-space:nowrap; }
.app a.off { opacity:.45; pointer-events:none; }
@media (max-width: 900px) {
  main { grid-template-columns:1fr; grid-auto-rows:minmax(300px, auto); overflow:auto; }
  #center { order:-1; }
  /* Вкладки на вузькому екрані — у два ряди, а не під прокруткою:
     сховане за краєм власник назвав недопустимим. */
  #tabs { flex-wrap:wrap; }
  #tabs button { flex:1 0 25%; padding:10px 6px; }
}
</style>
</head>
<body>
<header>
  <span id="status">Підключаюся…</span>
  <button id="zoomOff" title="Зняти наближення">1:1</button>
  <button id="androidButton">Android</button>
  <button id="pinButton">Пароль</button>
</header>
<nav id="tabs"></nav>
<main>
  <section id="left">
    <!-- Біблія -->
    <div class="panel" id="p-bible">
      <div class="row"><input id="searchText" class="grow" placeholder="Пошук за словами"><button id="searchGo">Знайти</button></div>
      <div id="searchBox" class="panel">
        <div class="row"><span id="searchNote" class="note grow"></span><button id="searchClose">До книг</button></div>
        <ul class="list" id="searchList"></ul>
      </div>
      <div id="bibleBox" class="panel shown">
        <div class="row"><button id="bibleBack">‹</button><b id="biblePath" class="grow"></b><select id="translation"></select></div>
        <div id="bibleNote" class="note"></div>
        <ul class="list" id="bibleList"></ul>
        <div class="chapters" id="chapterGrid" style="display:none"></div>
        <div class="row" id="bibleActions" style="display:none"><button id="bibleShow" class="big">Показати в залі</button><button id="bibleClear">Скинути</button></div>
      </div>
    </div>
    <!-- Пісні -->
    <div class="panel" id="p-songs">
      <div class="row"><select id="songBook" class="grow"></select><input id="songFilter" class="grow" placeholder="Номер або слова назви"></div>
      <ul class="list" id="songList"></ul>
      <div class="note">Частини пісні — клацання виводить у зал</div>
      <div class="row" id="parts"></div>
    </div>
    <!-- Презентація -->
    <div class="panel" id="p-presentation">
      <div class="row"><label><button id="fileButton">Файл з комп'ютера…</button></label><input type="file" id="fileInput" accept=".pdf,.pptx,.ppsx,.potx,.pptm,.ppsm" hidden></div>
      <div class="row" id="decks"></div>
      <div class="note" id="pageNote"></div>
      <div class="grid" id="pageGrid"></div>
    </div>
    <!-- Медіа -->
    <div class="panel" id="p-media">
      <div class="row"><button id="mBegin">⏮</button><button id="mPlay">▶</button><button id="mStop">⏹</button><span id="mTime" class="grow note"></span></div>
      <input type="range" id="mSeek" min="0" max="1000" value="0">
      <div class="row"><span>Гучність</span><input type="range" id="mVolume" min="0" max="100" class="grow"></div>
      <div class="row"><button id="mMute">Без звуку</button><button id="mScreen">На екран</button><button id="mRepeat">Повтор</button></div>
      <ul class="list" id="mediaList"></ul>
    </div>
    <!-- Зображення -->
    <div class="panel" id="p-pictures">
      <div class="row"><button id="photoButton">Фото з комп'ютера…</button><input type="file" id="photoInput" accept="image/*" multiple hidden></div>
      <div class="note" id="picturesNote"></div>
      <div class="grid" id="pictureGrid"></div>
    </div>
    <!-- Екран -->
    <div class="panel" id="p-screen">
      <div class="row"><button id="screenReload">Оновити</button><button id="screenStop">Зупинити показ</button></div>
      <div class="note" id="screenNote"></div>
      <ul class="list" id="screenList"></ul>
    </div>
    <!-- Текст -->
    <div class="panel" id="p-text">
      <input id="textTitle" placeholder="Заголовок (необов'язково)" style="margin-bottom:6px">
      <textarea id="textBody" rows="10" placeholder="Текст оголошення"></textarea>
      <div class="row" style="margin-top:6px"><button id="textPreview">У передпоказ</button><button id="textShow">Показати в залі</button></div>
      <div class="row"><button id="textPrev">◀</button><span id="textPages" class="note"></span><button id="textNext">▶</button></div>
    </div>
  </section>

  <section id="center">
    <div id="hallCaption">Зал</div>
    <div id="hallBox"><canvas id="hall"></canvas><div id="hallNote"></div></div>
    <div id="liveText"></div>
    <div id="previewText"></div>
  </section>

  <section id="right">
    <nav><button id="tabPlan" class="chosen">План</button><button id="tabHistory">Історія</button></nav>
    <div id="sideNote" class="note"></div>
    <ul class="list" id="sideList"></ul>
    <div class="row" style="margin-top:6px">
      <button id="planAdd">+ Поточне</button><button id="planUp">↑</button><button id="planDown">↓</button><button id="sideRemove">✕</button>
    </div>
  </section>
</main>
<footer>
  <button class="big" data-command="prev">◀ Назад</button>
  <button class="big" data-command="next">Далі ▶</button>
  <button class="big" data-command="show">Показати</button>
  <button class="big" data-command="hide">Сховати</button>
  <button class="big" data-command="black" id="black">Чорний екран</button>
  <button class="big" data-command="blank">Порожній</button>
</footer>
<div id="pinBox"><div>
  <b>Програма просить пароль</b>
  <span class="note">Той, що в Параметри → Remote API → «Пульт у браузері».</span>
  <input id="pinInput" inputmode="numeric" autocomplete="off">
  <button id="pinSave">Підключитися</button>
</div></div>

<div id="androidBox"><div>
  <b>Програми «Слова» для Android</b>
  <span class="note" id="androidNote"></span>
  <div id="androidList"></div>
  <button id="androidClose">Закрити</button>
</div></div>

<script>
"use strict";
// Пульт «Слова» у браузері: той самий канал, що в телефона й планшета,
// і та сама раскладка, що в планшета. Сторінку віддає сама програма, тож
// усі запити — на свою ж адресу.

const MODES = [["bible","Біблія"],["songs","Пісні"],["presentation","Презентація"],["media","Медіа"],
               ["pictures","Зображення"],["screen","Екран"],["text","Текст"]];
const $ = id => document.getElementById(id);
let pin = "";
try { pin = localStorage.getItem("slovo-pin") || ""; } catch (e) {}
let state = {}, seq = -1, mode = "bible", followed = "", sideHistory = false, sideSelected = -1;

function withPin(path) {
  return pin ? path + (path.includes("?") ? "&" : "?") + "pin=" + encodeURIComponent(pin) : path;
}

async function api(path, body) {
  const options = { headers: {} };
  if (pin) options.headers["X-Slovo-Pin"] = pin;
  if (body !== undefined) {
    options.method = "POST";
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body || {});
  }
  const url = path.startsWith("/") ? path : "/api/" + path;
  const response = await fetch(url, options);
  if (response.status === 401) { askPin(); throw new Error("PIN"); }
  const text = await response.text();
  let json = {};
  try { json = text ? JSON.parse(text) : {}; } catch (e) {}
  if (!response.ok) throw new Error(json.error || ("HTTP " + response.status));
  return json;
}

function send(command, body) {
  return api(command, body || {}).catch(error => { if (error.message !== "PIN") $("status").textContent = error.message; });
}

function askPin() { $("pinBox").classList.add("shown"); $("pinInput").value = pin; $("pinInput").focus(); }
$("pinButton").onclick = askPin;
$("pinSave").onclick = () => {
  pin = $("pinInput").value.trim();
  try { localStorage.setItem("slovo-pin", pin); } catch (e) {}
  $("pinBox").classList.remove("shown");
  seq = -1;
};

// ---------- Опитування стану ----------

async function poll() {
  let failures = 0;
  for (;;) {
    try {
      const fresh = await api("/api/state?since=" + seq);
      failures = 0;
      if (typeof fresh.seq === "number") seq = fresh.seq;
      apply(fresh);
    } catch (error) {
      failures++;
      if (error.message !== "PIN" && failures >= 2) $("status").textContent = "Немає зв'язку з програмою — пробую знову…";
      await new Promise(r => setTimeout(r, Math.min(5000, 800 * failures)));
    }
  }
}

function modeTitle(key) { const m = MODES.find(m => m[0] === key); return m ? m[1] : ""; }

function apply(fresh) {
  const before = state;
  state = fresh;
  $("status").textContent = (fresh.name || "Слово") + " · на зв'язку" + (fresh.mode ? " · " + modeTitle(fresh.mode) : "");
  $("black").classList.toggle("on", !!fresh.black);
  document.body.classList.toggle("view-only", !!fresh.viewOnly);
  if (fresh.mode && fresh.mode !== followed) {
    followed = fresh.mode;
    if (fresh.mode !== mode) chooseMode(fresh.mode, false);
  }
  markTabs();
  applyHall(fresh);
  const p = fresh.preview || {};
  const preview = p.text ? (p.reference ? p.reference + " — " + p.text : p.text) : (p.reference || "");
  $("previewText").textContent = preview ? "Передпоказ: " + preview.replace(/\n/g, " ") : "";
  if (sideHistory) loadHistory(); else fillPlan();
  if (mode === "songs") { if ((fresh.songBook || "") !== songsBook) loadSongs(); fillParts(); }
  if (mode === "presentation") fillPresentation();
  if (mode === "pictures" && fresh.show && fresh.mode === "pictures" && fresh.show.count !== picturesCount) loadPictures();
  if (mode === "bible" && before.bible && fresh.bible && !bibleLoaded) bibleOpen();
}

// ---------- Вкладки ----------

MODES.forEach(([key, title]) => {
  const button = document.createElement("button");
  button.textContent = title;
  button.dataset.mode = key;
  button.onclick = () => chooseMode(key, true);
  $("tabs").appendChild(button);
});

function markTabs() {
  document.querySelectorAll("#tabs button").forEach(b => {
    b.classList.toggle("chosen", b.dataset.mode === mode);
    const title = modeTitle(b.dataset.mode);
    b.textContent = (b.dataset.mode === state.mode && b.dataset.mode !== mode ? "● " : "") + title;
  });
}

function chooseMode(key, fromClick) {
  mode = key;
  if (fromClick) { followed = key; send("mode", { text: key }); }
  document.querySelectorAll(".panel[id^='p-']").forEach(p => p.classList.toggle("shown", p.id === "p-" + key));
  markTabs();
  if (key === "bible") bibleOpen();
  if (key === "songs") loadSongs();
  if (key === "presentation") fillPresentation(true);
  if (key === "media") loadMedia();
  if (key === "pictures") loadPictures();
  if (key === "screen") loadScreen(0);
  if (key === "text") loadText();
}

document.querySelectorAll("footer button").forEach(b => b.onclick = () => send(b.dataset.command));

function row(list, title, subtitle, current, onClick, onLong) {
  const li = document.createElement("li");
  li.textContent = title;
  if (subtitle) { const s = document.createElement("small"); s.textContent = subtitle; li.appendChild(s); }
  if (current) li.classList.add("current");
  li.onclick = onClick;
  if (onLong) li.ondblclick = onLong;
  list.appendChild(li);
  return li;
}

// ---------- Зал ----------

const hall = $("hall");
let hallImage = null, hallSeq = -1, hallBusy = false, hallPending = false;

function applyHall(fresh) {
  const h = fresh.hall || {};
  const slide = fresh.slide || {};
  let caption = "Зал";
  if (h.kind === "text" && slide.reference) caption += " — " + slide.reference;
  else if ((h.kind === "still" || h.kind === "video") && h.title) caption += " — " + h.title;
  $("hallCaption").textContent = caption;
  $("liveText").textContent = h.kind === "text" ? (slide.text || "") : "";
  if (h.kind === "video" || h.kind === "black") {
    hallImage = null;
    $("hallNote").textContent = h.kind === "video" ? "У залі відео: " + (h.title || "") : "Зал затемнено";
    drawHall();
    return;
  }
  $("hallNote").textContent = h.kind === "empty" ? "У залі нічого не показано" : "";
  if (fresh.seq !== hallSeq) { hallSeq = fresh.seq; loadHall(); } else drawHall();
}

function loadHall() {
  if (hallBusy) { hallPending = true; return; }
  hallBusy = true; hallPending = false;
  const image = new Image();
  const width = Math.max(480, Math.min(1920, Math.round(hall.clientWidth * (window.devicePixelRatio || 1))));
  image.onload = () => { hallBusy = false; const k = (state.hall || {}).kind; if (k !== "video" && k !== "black") { hallImage = image; drawHall(); } if (hallPending) loadHall(); };
  image.onerror = () => { hallBusy = false; if (hallPending) loadHall(); };
  image.src = withPin("/api/hall.jpg?w=" + width + "&s=" + hallSeq);
}

// Вікно наближення в частках цілого кадру — те саме правило, що в програмі.
function zoomWindow() {
  const z = state.zoom || {};
  if (!z.on || !(z.zoom > 1.001)) return { left: 0, top: 0, side: 1 };
  const side = 1 / Math.max(1, Math.min(6, z.zoom));
  return { left: Math.min(1 - side, Math.max(0, z.x - side / 2)), top: Math.min(1 - side, Math.max(0, z.y - side / 2)), side };
}

let shownRect = null, touchingHall = false;

function drawHall() {
  const ratio = window.devicePixelRatio || 1;
  const w = hall.clientWidth, h = hall.clientHeight;
  if (hall.width !== Math.round(w * ratio) || hall.height !== Math.round(h * ratio)) { hall.width = Math.round(w * ratio); hall.height = Math.round(h * ratio); }
  const g = hall.getContext("2d");
  g.setTransform(ratio, 0, 0, ratio, 0, 0);
  g.fillStyle = "#000"; g.fillRect(0, 0, w, h);
  shownRect = null;
  if (!hallImage) return;
  const win = zoomWindow();
  const sx = win.left * hallImage.width, sy = win.top * hallImage.height;
  const sw = win.side * hallImage.width, sh = win.side * hallImage.height;
  const scale = Math.min(w / sw, h / sh);
  const dw = sw * scale, dh = sh * scale, dx = (w - dw) / 2, dy = (h - dh) / 2;
  g.drawImage(hallImage, sx, sy, sw, sh, dx, dy, dw, dh);
  shownRect = { x: dx, y: dy, w: dw, h: dh };
  // Указка, яку веде хтось інший (миша на комп'ютері, телефон), — тут теж.
  const p = state.pointer || {};
  if (p.on && !touchingHall) {
    const radius = Math.max(3, (p.size || 0.14) * dh / 2);
    g.globalAlpha = p.opacity || 0.45;
    g.fillStyle = p.colour || "#ffd60a";
    g.beginPath(); g.arc(dx + p.x * dw, dy + p.y * dh, radius, 0, Math.PI * 2); g.fill();
    g.globalAlpha = 1;
  }
}
window.addEventListener("resize", drawHall);

function shownFraction(event) {
  if (!shownRect) return null;
  const box = hall.getBoundingClientRect();
  const x = (event.clientX - box.left - shownRect.x) / shownRect.w;
  const y = (event.clientY - box.top - shownRect.y) / shownRect.h;
  return { x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)) };
}

// Указка: натиснули й ведете — пляма на стіні; відпустили — згасла.
let pointerBusy = false, pendingPoint = null;
function queuePointer(point) {
  pendingPoint = point;
  if (pointerBusy) return;
  pointerBusy = true;
  (async () => {
    let sent = null;
    while (pendingPoint && pendingPoint !== sent) {
      const p = pendingPoint; sent = p;
      try { await api("pointer", { x: p.x, y: p.y }); } catch (e) { break; }
    }
    pointerBusy = false;
  })();
}

// Щипок двома пальцями (планшет у браузері) і колесо миші — наближення в
// точку під пальцями чи курсором, у частках показаного кадру.
const touches = new Map();
let pinchStart = null, zoomBusy = false, zoomNow = 1;

function queueZoom(zoom, point) {
  zoomNow = Math.max(1, Math.min(6, zoom));
  if (zoomBusy) return;
  zoomBusy = true;
  api("zoom", { zoom: zoomNow, x: point.x, y: point.y }).catch(() => {}).finally(() => { zoomBusy = false; });
}

hall.addEventListener("pointerdown", event => {
  if (state.viewOnly) return;
  touches.set(event.pointerId, event);
  hall.setPointerCapture(event.pointerId);
  if (touches.size === 2) {
    const [a, b] = [...touches.values()];
    pinchStart = { distance: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY), zoom: (state.zoom && state.zoom.on) ? state.zoom.zoom : 1 };
    send("pointer-off"); touchingHall = false; pendingPoint = null;
    return;
  }
  const point = shownFraction(event);
  if (!point || !hallImage) return;
  touchingHall = true;
  queuePointer(point);
});
hall.addEventListener("pointermove", event => {
  if (!touches.has(event.pointerId)) return;
  touches.set(event.pointerId, event);
  if (touches.size === 2 && pinchStart) {
    const [a, b] = [...touches.values()];
    const distance = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
    const middle = shownFraction({ clientX: (a.clientX + b.clientX) / 2, clientY: (a.clientY + b.clientY) / 2 });
    if (middle && pinchStart.distance > 0) queueZoom(pinchStart.zoom * distance / pinchStart.distance, middle);
    return;
  }
  if (touchingHall) { const point = shownFraction(event); if (point) queuePointer(point); }
});
function liftFinger(event) {
  touches.delete(event.pointerId);
  if (touches.size < 2) pinchStart = null;
  if (touchingHall && touches.size === 0) { touchingHall = false; pendingPoint = null; send("pointer-off"); }
}
hall.addEventListener("pointerup", liftFinger);
hall.addEventListener("pointercancel", liftFinger);
hall.addEventListener("wheel", event => {
  event.preventDefault();
  if (state.viewOnly) return;
  const point = shownFraction(event);
  if (!point) return;
  const current = (state.zoom && state.zoom.on) ? state.zoom.zoom : 1;
  queueZoom(current * (event.deltaY < 0 ? 1.15 : 1 / 1.15), point);
}, { passive: false });
hall.addEventListener("dblclick", () => { if (!state.viewOnly) send("zoom", { zoom: 1 }); });
$("zoomOff").onclick = () => send("zoom", { zoom: 1 });

// ---------- Біблія ----------

let books = [], bibleLoaded = false, level = "books", bookPos = -1, chapterNo = 0, verses = [], picked = [];

async function bibleOpen() {
  if (bibleLoaded) return renderBible();
  try {
    const json = await api("/api/bible/books");
    books = json.books || [];
    bibleLoaded = true;
    const select = $("translation");
    select.innerHTML = "";
    (json.translations || []).forEach(t => { const o = document.createElement("option"); o.value = t.id; o.textContent = t.name; select.appendChild(o); });
    if (json.translation) select.value = json.translation.id;
    const current = json.current || {};
    if (current.book >= 0 && current.chapter > 0) { await openChapter(current.book, current.chapter, current.verses || []); return; }
    level = "books"; renderBible();
  } catch (error) { $("bibleNote").textContent = error.message; }
}

$("translation").onchange = async () => {
  await send("bible-translation", { text: $("translation").value });
  bibleLoaded = false; bibleOpen();
};

async function openChapter(position, chapter, chosen) {
  $("bibleNote").textContent = "Завантажую…";
  try {
    const json = await api("/api/bible/chapter?book=" + position + "&chapter=" + chapter);
    bookPos = position; chapterNo = json.chapter || chapter; verses = json.verses || []; picked = (chosen || []).slice();
    level = "verses"; renderBible();
  } catch (error) { $("bibleNote").textContent = error.message; }
}

function renderBible() {
  const list = $("bibleList"), grid = $("chapterGrid");
  list.innerHTML = ""; grid.innerHTML = "";
  const book = books.find(b => b.position === bookPos);
  list.style.display = level === "chapters" ? "none" : "";
  grid.style.display = level === "chapters" ? "" : "none";
  $("bibleActions").style.display = level === "verses" ? "" : "none";
  $("bibleNote").textContent = "";
  if (level === "books") {
    $("biblePath").textContent = "Книги";
    const names = { old: "Старий Заповіт", "new": "Новий Заповіт", other: "Інші книги" };
    ["old", "new", "other"].forEach(t => {
      const part = books.filter(b => b.testament === t);
      if (!part.length) return;
      const head = row(list, names[t], "", false, null); head.style.cursor = "default"; head.style.color = "var(--dim)";
      part.forEach(b => row(list, b.name, b.chapters + " розд.", b.position === bookPos, () => { bookPos = b.position; level = "chapters"; renderBible(); }));
    });
  } else if (level === "chapters") {
    $("biblePath").textContent = book ? book.name : "";
    for (let n = 1; n <= (book ? book.chapters : 0); n++) {
      const b = document.createElement("button"); b.textContent = n;
      if (n === chapterNo) b.classList.add("on");
      b.onclick = () => openChapter(bookPos, n, []);
      grid.appendChild(b);
    }
  } else {
    $("biblePath").textContent = (book ? book.name : "") + " · розділ " + chapterNo;
    verses.forEach(v => {
      const li = row(list, "", "", picked.includes(v.number), event => toggleVerse(v.number, event.shiftKey));
      li.classList.add("verse");
      const n = document.createElement("b"); n.textContent = v.number;
      li.appendChild(n); li.appendChild(document.createTextNode(v.text));
      li.ondblclick = () => { picked = [v.number]; renderBible(); sendBible(true); };
    });
    $("bibleShow").textContent = picked.length ? "Показати в залі (" + picked.length + ")" : "Показати в залі";
  }
}

function toggleVerse(number, range) {
  if (range && picked.length) {
    const from = Math.min(picked[0], number), to = Math.max(picked[0], number);
    picked = []; for (let n = from; n <= to; n++) picked.push(n);
  } else if (picked.includes(number)) picked = picked.filter(n => n !== number);
  else picked.push(number);
  picked.sort((a, b) => a - b);
  renderBible();
  if (picked.length) sendBible(false);
}

function sendBible(live) {
  return send("bible-select", { book: bookPos, chapter: chapterNo, verses: picked, live });
}
$("bibleShow").onclick = () => sendBible(true);
$("bibleClear").onclick = () => { picked = []; renderBible(); };
$("bibleBack").onclick = () => { level = level === "verses" ? "chapters" : "books"; renderBible(); };

// Пошук за словами.
async function runSearch() {
  const query = $("searchText").value.trim();
  if (!query) return;
  $("searchBox").classList.add("shown"); $("bibleBox").classList.remove("shown");
  $("searchList").innerHTML = ""; $("searchNote").textContent = "Шукаю «" + query + "»…";
  await send("bible-search", { text: query });
  for (let attempt = 0; attempt < 50; attempt++) {
    const json = await api("/api/search").catch(() => ({}));
    if (!json.searching) {
      const hits = json.hits || [];
      hits.forEach(h => row($("searchList"), h.reference, h.text, false,
        () => send("search-hit", { index: h.index, live: false }), () => send("search-hit", { index: h.index, live: true })));
      $("searchNote").textContent = hits.length ? "«" + query + "»: " + hits.length + ". Клацання — у передпоказ, подвійне — у зал"
                                                  : "За «" + query + "» нічого не знайдено";
      return;
    }
    await new Promise(r => setTimeout(r, 400));
  }
}
$("searchGo").onclick = runSearch;
$("searchText").onkeydown = event => { if (event.key === "Enter") runSearch(); };
$("searchClose").onclick = () => { $("searchBox").classList.remove("shown"); $("bibleBox").classList.add("shown"); bibleLoaded = false; bibleOpen(); };

// ---------- Пісні ----------

let songs = [], songsBook = "";
async function loadSongs() {
  try {
    const [list, bookList] = await Promise.all([api("/api/songs/list"), api("/api/songs/books")]);
    songs = list.songs || []; songsBook = list.book || "";
    const select = $("songBook"); select.innerHTML = "";
    (bookList.books || []).forEach(b => { const o = document.createElement("option"); o.value = b.id; o.textContent = b.title; select.appendChild(o); });
    select.value = songsBook;
    fillSongs(); fillParts();
  } catch (error) { $("status").textContent = error.message; }
}
$("songBook").onchange = async () => { await send("songs-book", { text: $("songBook").value }); loadSongs(); };
$("songFilter").oninput = fillSongs;

function fillSongs() {
  const list = $("songList"); list.innerHTML = "";
  const needle = $("songFilter").value.trim().toLowerCase();
  const byNumber = /^\d+$/.test(needle);
  const title = (state.song || {}).title || "";
  let shown = 0;
  for (const s of songs) {
    if (needle && (byNumber ? !String(s.number).startsWith(needle) : !s.title.toLowerCase().includes(needle))) continue;
    row(list, s.number + ". " + s.title, s.subtitle, s.title === title, () => send("song", { index: s.index }));
    if (++shown >= 500) break;
  }
}

function fillParts() {
  const box = $("parts"); box.innerHTML = "";
  const song = state.song;
  if (!song) return;
  // Однакові види частин («Куплет», «Куплет») підписуємо номером — інакше
  // кнопки не відрізнити; де номер уже в назві, лишаємо як є.
  const kinds = (song.parts || []).map(p => p.kind || "");
  (song.parts || []).forEach((part, i) => {
    const b = document.createElement("button");
    const same = kinds.filter(k => k === kinds[i]).length;
    b.textContent = !kinds[i] ? String(i + 1) : same > 1 ? kinds[i] + " " + kinds.slice(0, i + 1).filter(k => k === kinds[i]).length : kinds[i];
    if (i === song.partIndex) b.classList.add("on");
    b.title = part.text || "";
    b.onclick = () => send("part", { index: i });
    box.appendChild(b);
  });
}

// ---------- Презентація й зображення ----------

function thumbGrid(grid, items, current, onClick, kind) {
  grid.innerHTML = "";
  items.forEach(item => {
    const cell = document.createElement("div");
    if (item.index === current) cell.classList.add("current");
    const img = document.createElement("img"); img.loading = "lazy";
    img.src = withPin("/api/page?" + (kind ? "kind=" + kind + "&" : "") + "index=" + item.index + "&w=320&t=" + encodeURIComponent(item.title || ""));
    const caption = document.createElement("span"); caption.textContent = item.title || "";
    cell.appendChild(img); cell.appendChild(caption);
    cell.onclick = () => onClick(item.index);
    grid.appendChild(cell);
  });
}

let presentationSignature = "";
function fillPresentation(force) {
  const p = state.presentation || {};
  const decks = $("decks"); decks.innerHTML = "";
  (p.decks || []).forEach(d => {
    const b = document.createElement("button"); b.textContent = d.name + " (" + d.count + ")";
    if (d.index === p.deck) b.classList.add("on");
    b.onclick = () => send("deck", { index: d.index });
    decks.appendChild(b);
  });
  $("pageNote").textContent = (p.index >= 0) ? "Слайд " + (p.local + 1) + " з " + p.count + (p.onWall ? " · у залі" : "") + (p.title ? " — " + p.title : "")
                                             : "Презентацію не відкрито. «Файл з комп'ютера…» відкриє PDF або PowerPoint";
  const signature = JSON.stringify([p.pages, p.index]);
  if (!force && signature === presentationSignature) return;
  presentationSignature = signature;
  thumbGrid($("pageGrid"), p.pages || [], p.index, index => send("page", { index }), "");
}

let picturesCount = -1;
async function loadPictures() {
  try {
    const json = await api("/api/pictures");
    picturesCount = json.count;
    thumbGrid($("pictureGrid"), json.pages || [], json.index, async index => { await send("picture", { index }); loadPictures(); }, "pictures");
    $("picturesNote").textContent = (json.pages || []).length ? "" : "Картинок немає. «Фото з комп'ютера…» додає їх сюди";
  } catch (error) { $("picturesNote").textContent = error.message; }
}

async function upload(file, show) {
  const headers = { "Content-Type": "application/octet-stream" };
  if (pin) headers["X-Slovo-Pin"] = pin;
  const response = await fetch("/api/upload?name=" + encodeURIComponent(file.name) + (show ? "&show=1" : ""), { method: "POST", headers, body: file });
  const json = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(json.error || ("HTTP " + response.status));
  return json;
}

// Фото зменшуємо до 2560 точок, як і телефон: стіні більше не треба, а
// знімок важить мегабайти. Чого браузер не розібрав (HEIC) — шлемо як є.
function shrink(file) {
  return new Promise(resolve => {
    const url = URL.createObjectURL(file);
    const image = new Image();
    image.onload = () => {
      const scale = Math.min(1, 2560 / Math.max(image.width, image.height));
      if (scale >= 1 && file.size < 6e6) { URL.revokeObjectURL(url); resolve(file); return; }
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(image.width * scale); canvas.height = Math.round(image.height * scale);
      canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
      URL.revokeObjectURL(url);
      canvas.toBlob(blob => resolve(blob ? new File([blob], file.name.replace(/\.[^.]*$/, "") + ".jpg", { type: "image/jpeg" }) : file), "image/jpeg", 0.9);
    };
    image.onerror = () => { URL.revokeObjectURL(url); resolve(file); };
    image.src = url;
  });
}

$("fileButton").onclick = () => $("fileInput").click();
$("fileInput").onchange = async () => {
  const file = $("fileInput").files[0]; if (!file) return;
  $("status").textContent = "Надсилаю «" + file.name + "»…";
  try { const json = await upload(file, false); $("status").textContent = "«" + file.name + "» відкрито: сторінок " + (json.pages || 0); }
  catch (error) { $("status").textContent = error.message; }
  $("fileInput").value = "";
};
$("photoButton").onclick = () => $("photoInput").click();
$("photoInput").onchange = async () => {
  const files = [...$("photoInput").files].slice(0, 20); let first = -1;
  for (let i = 0; i < files.length; i++) {
    $("status").textContent = "Надсилаю фото " + (i + 1) + " з " + files.length + "…";
    try { const json = await upload(await shrink(files[i]), false); if (first < 0 && json.page >= 0) first = json.page; }
    catch (error) { $("status").textContent = error.message; }
  }
  if (first >= 0) await send("picture", { index: first });
  $("photoInput").value = "";
  loadPictures();
};

// ---------- Медіа ----------

let mediaDuration = 0, seeking = false, mediaTimer = null, mediaShown = "";
function clock(s) { s = Math.max(0, Math.round(s)); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, r = s % 60; return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(r).padStart(2, "0"); }
async function loadMedia() {
  clearTimeout(mediaTimer);
  if (mode !== "media") return;
  try {
    const json = await api("/api/media");
    const shown = JSON.stringify(json);
    if (shown !== mediaShown) {
      mediaShown = shown;
      mediaDuration = json.duration || 0;
      $("mPlay").textContent = json.playing ? "⏸" : "▶";
      if (!seeking) $("mSeek").value = mediaDuration > 0 ? Math.round(json.position / mediaDuration * 1000) : 0;
      $("mTime").textContent = (json.title || "Нічого не відкрито") + (mediaDuration > 0 ? "   " + clock(json.position) + " / " + clock(mediaDuration) : "");
      if (document.activeElement !== $("mVolume")) $("mVolume").value = Math.round((json.volume || 0) * 100);
      $("mMute").classList.toggle("on", !!json.muted); $("mScreen").classList.toggle("on", !!json.toScreen); $("mRepeat").classList.toggle("on", !!json.repeats);
      const list = $("mediaList"); list.innerHTML = "";
      (json.playlist || []).forEach(item => row(list, item.name, "", item.index === json.index, async () => { await send("media-open", { index: item.index }); loadMedia(); }));
      if (!(json.playlist || []).length) row(list, "Список плеєра порожній — файли додають на комп'ютері", "", false, null);
    }
  } catch (error) {}
  mediaTimer = setTimeout(loadMedia, 1000);
}
$("mPlay").onclick = () => send("media-toggle").then(loadMedia);
$("mStop").onclick = () => send("media-stop").then(loadMedia);
$("mBegin").onclick = () => send("media-seek", { x: 0 }).then(loadMedia);
$("mSeek").oninput = () => { seeking = true; };
$("mSeek").onchange = () => { seeking = false; if (mediaDuration > 0) send("media-seek", { x: $("mSeek").value / 1000 * mediaDuration }); };
$("mVolume").onchange = () => send("media-volume", { x: $("mVolume").value / 100 });
$("mMute").onclick = () => send("media-mute").then(loadMedia);
$("mScreen").onclick = () => send("media-screen").then(loadMedia);
$("mRepeat").onclick = () => send("media-repeat").then(loadMedia);

// ---------- Екран ----------

async function loadScreen(attempt) {
  try {
    const json = await api("/api/screen");
    const list = $("screenList"); list.innerHTML = "";
    let running = "";
    (json.sources || []).forEach(s => {
      const now = json.running && s.id === json.current; if (now) running = s.title;
      row(list, s.title, s.subtitle, now, async () => { await send("screen-start", { index: s.index }); loadScreen(0); });
    });
    if (!(json.sources || []).length) {
      $("screenNote").textContent = "Джерел немає. Можливо, програмі потрібен дозвіл на запис екрана: Системні параметри → Приватність і безпека → Запис екрана";
      if (attempt < 3) setTimeout(() => loadScreen(attempt + 1), 1500);
    } else $("screenNote").textContent = running ? "Показ іде: " + running : (json.note || "");
  } catch (error) { $("screenNote").textContent = error.message; }
}
$("screenReload").onclick = async () => { await send("screen-reload"); setTimeout(() => loadScreen(0), 1200); };
$("screenStop").onclick = async () => { await send("screen-stop"); loadScreen(0); };

// ---------- Текст ----------

let textPage = 0, textPages = 0;
async function loadText() {
  try {
    const json = await api("/api/text");
    if (!$("textBody").value && !$("textTitle").value) { $("textTitle").value = json.title || ""; $("textBody").value = json.body || ""; }
    textPage = json.page || 0; textPages = json.pages || 0;
    $("textPages").textContent = textPages ? "Сторінка " + (textPage + 1) + " з " + textPages : "";
  } catch (error) {}
}
async function sendText(live) {
  await send("text-set", { text: $("textBody").value, title: $("textTitle").value });
  if (live) await send("text-show");
  loadText();
}
$("textPreview").onclick = () => sendText(false);
$("textShow").onclick = () => sendText(true);
$("textPrev").onclick = async () => { if (textPage > 0) { await send("text-page", { index: textPage - 1 }); loadText(); } };
$("textNext").onclick = async () => { if (textPage + 1 < textPages) { await send("text-page", { index: textPage + 1 }); loadText(); } };

// ---------- План та Історія ----------

function chooseSide(history) {
  sideHistory = history; sideSelected = -1;
  $("tabPlan").classList.toggle("chosen", !history); $("tabHistory").classList.toggle("chosen", history);
  ["planAdd", "planUp", "planDown"].forEach(id => $(id).style.display = history ? "none" : "");
  if (history) loadHistory(); else fillPlan();
}
$("tabPlan").onclick = () => chooseSide(false);
$("tabHistory").onclick = () => chooseSide(true);

function fillPlan() {
  if (sideHistory) return;
  const list = $("sideList"); list.innerHTML = "";
  (state.plan || []).forEach((item, i) => row(list, item.title, item.subtitle, item.current || i === sideSelected,
    () => { sideSelected = i; send("plan", { index: i }); fillPlan(); }));
  $("sideNote").textContent = (state.plan || []).length ? "" : "План порожній. «+ Поточне» кладе сюди те, що вибрано";
}

let historyAsked = -1;
async function loadHistory() {
  if (historyAsked === state.seq) return;
  historyAsked = state.seq;
  try {
    const json = await api("/api/history");
    if (!sideHistory) return;
    const list = $("sideList"); list.innerHTML = "";
    (json.records || []).forEach(r => {
      const cut = r.caption.indexOf("- ");
      row(list, cut > 0 ? r.caption.slice(0, cut) : r.caption, cut > 0 ? r.caption.slice(cut + 2) : "", r.current || r.index === sideSelected,
          () => { sideSelected = r.index; send("history", { index: r.index }); });
    });
    $("sideNote").textContent = (json.records || []).length ? "" : "Історія порожня — сюди потрапляє все, що показано в залі";
  } catch (error) {}
}

$("planAdd").onclick = () => send("plan-add");
$("planUp").onclick = () => { if (sideSelected > 0) { send("plan-move", { index: sideSelected, delta: -1 }); sideSelected--; } };
$("planDown").onclick = () => { if (sideSelected >= 0 && sideSelected + 1 < (state.plan || []).length) { send("plan-move", { index: sideSelected, delta: 1 }); sideSelected++; } };
$("sideRemove").onclick = async () => {
  if (sideSelected < 0) return;
  const index = sideSelected; sideSelected = -1;
  await send(sideHistory ? "history-remove" : "plan-remove", { index });
  if (sideHistory) { historyAsked = -1; loadHistory(); }
};

// ---------- Клавіші ----------

document.addEventListener("keydown", event => {
  const tag = (event.target.tagName || "").toLowerCase();
  if (tag === "input" || tag === "textarea" || tag === "select" || state.viewOnly) return;
  const commands = { ArrowRight: "next", PageDown: "next", " ": "next", ArrowLeft: "prev", PageUp: "prev", Enter: "show", Escape: "hide", b: "black", "и": "black" };
  const command = commands[event.key];
  if (command) { event.preventDefault(); send(command); }
});

// ---------- Програми для Android ----------
// Власник: «при веб входе скачать на текущее устройство или установить, если
// устройство совместимо с программой». Версію Android беремо з рядка браузера.

function androidVersion() {
  const m = navigator.userAgent.match(/Android\s+(\d+)(?:\.(\d+))?/);
  return m ? parseFloat(m[1] + "." + (m[2] || "0")) : null;
}
const SDK_TO_ANDROID = { 21: 5, 22: 5.1, 23: 6, 24: 7, 25: 7.1, 26: 8, 27: 8.1, 28: 9, 29: 10, 30: 11, 31: 12 };

async function showAndroid() {
  $("androidBox").classList.add("shown");
  const list = $("androidList"); list.innerHTML = "";
  const version = androidVersion();
  $("androidNote").textContent = version !== null
    ? "Цей пристрій — Android " + version + ". Після завантаження торкніться файлу: Android спитає дозвіл встановлювати з браузера — погодьтеся."
    : "Програми встановлюються на Android. Тут файл можна зберегти й перенести на телефон чи планшет.";
  try {
    const json = await api("/api/apps");
    (json.apps || []).forEach(app => {
      const need = SDK_TO_ANDROID[app.minSdk] || 5;
      const fits = version === null ? null : version >= need;
      const row = document.createElement("div"); row.className = "app";
      const text = document.createElement("div");
      const title = document.createElement("b"); title.textContent = app.title + (app.version ? " " + app.version : "");
      const note = document.createElement("small"); note.className = "note"; note.style.display = "block";
      note.textContent = "Android " + app.minAndroid + " і новіші · " + Math.round((app.size || 0) / 1024) + " КБ"
        + (fits === false ? " — цьому пристрою не підходить, потрібен Android " + app.minAndroid : "");
      text.appendChild(title); text.appendChild(note);
      const link = document.createElement("a");
      link.href = app.url; link.setAttribute("download", "");
      link.textContent = fits ? "Встановити" : "Зберегти файл";
      if (fits === false) link.classList.add("off");
      row.appendChild(text); row.appendChild(link); list.appendChild(row);
    });
    if (!(json.apps || []).length) $("androidNote").textContent = "У цій збірці програм для Android немає.";
  } catch (error) { $("androidNote").textContent = error.message; }
}
$("androidButton").onclick = showAndroid;
$("androidClose").onclick = () => $("androidBox").classList.remove("shown");

chooseMode("bible", false);
chooseSide(false);
poll();
</script>
</body>
</html>
"""#
}
