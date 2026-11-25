/* Butchies KI Studio – Oberfläche (ohne externe Bibliotheken) */
"use strict";

const $ = (id) => document.getElementById(id);
const fmtGB = (b) => (b / 1e9).toFixed(1).replace(".", ",") + " GB";

let state = { view: "chat", status: null, chats: [], current: null, streaming: null, lastActivity: 0 };

// ---------------------------------------------------------------- API
async function api(path, body) {
  const opt = body === undefined ? {} : {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  };
  const r = await fetch(path, opt);
  let data = {};
  try { data = await r.json(); } catch (e) { /* leer */ }
  if (r.status === 401 && !path.startsWith("/api/login") && !path.startsWith("/api/setup")) {
    showGate(false);
  }
  if (!r.ok || data.ok === false) throw new Error(data.error || ("Fehler " + r.status));
  return data;
}

// Aktivität melden (hält den Mini-PC wach, solange du ihn benutzt)
function activity() {
  const now = Date.now();
  if (now - state.lastActivity < 60000) return;
  state.lastActivity = now;
  api("/api/activity", {}).catch(() => {});
}
["keydown", "pointerdown", "wheel"].forEach((ev) => document.addEventListener(ev, activity, { passive: true }));

// ---------------------------------------------------------------- Speicher
function loadChats() {
  try { state.chats = JSON.parse(localStorage.getItem("bki-chats") || "[]"); } catch (e) { state.chats = []; }
}
function saveChats() {
  try { localStorage.setItem("bki-chats", JSON.stringify(state.chats.slice(0, 50))); } catch (e) { /* voll */ }
}

// ---------------------------------------------------------------- Anmeldung
let gateSetup = false;
function showGate(setup) {
  gateSetup = setup;
  $("app").hidden = true;
  $("gate").hidden = false;
  $("gate-title").textContent = setup ? "Willkommen!" : "Anmelden";
  $("gate-text").textContent = setup
    ? "Lege ein Passwort für die Oberfläche fest (mindestens 8 Zeichen). Damit kann niemand sonst im Heimnetz deinen Mini-PC steuern."
    : "Gib dein Passwort für die Oberfläche ein.";
  $("gate-pw2-wrap").hidden = !setup;
  $("gate-pw").autocomplete = setup ? "new-password" : "current-password";
  $("gate-btn").textContent = setup ? "Passwort festlegen" : "Anmelden";
  $("gate-pw").focus();
}

$("gate-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("gate-error").textContent = "";
  const pw = $("gate-pw").value;
  try {
    if (gateSetup) {
      if (pw !== $("gate-pw2").value) throw new Error("Die Passwörter sind nicht gleich.");
      await api("/api/setup", { username: $("gate-user").value.trim(), password: pw });
    } else {
      await api("/api/login", { username: $("gate-user").value.trim(), password: pw });
    }
    $("gate-pw").value = ""; $("gate-pw2").value = "";
    startApp();
  } catch (err) { $("gate-error").textContent = err.message; }
});

$("logout-btn").addEventListener("click", async () => {
  await api("/api/logout", {}).catch(() => {});
  showGate(false);
});

// ---------------------------------------------------------------- Navigation
document.querySelectorAll(".nav").forEach((b) => b.addEventListener("click", () => setView(b.dataset.view)));
function setView(v) {
  state.view = v;
  document.querySelectorAll(".nav").forEach((b) => b.classList.toggle("active", b.dataset.view === v));
  ["chat", "models", "system", "settings", "ext", "images"].forEach((n) => { $("view-" + n).hidden = n !== v; });
  if (v === "models") loadModels();
  if (v === "system") loadStorage();
  if (v === "ext") loadExt();
  if (v === "images") loadImages();
  if (v === "system") { loadUpdates(); loadLogs(); }
  if (v === "settings") loadSettings();
}

// ---------------------------------------------------------------- Status
function blocks(el, percent) {
  if (!el.children.length) for (let i = 0; i < 20; i++) el.appendChild(document.createElement("span"));
  const on = Math.floor(percent / 5);
  [...el.children].forEach((s, i) => s.classList.toggle("on", i < on));
  el.setAttribute("aria-valuenow", String(percent));
}

function renderJob(job) {
  const b = $("job-banner");
  const show = job && (job.running || job.error || (job.done_at && Date.now() / 1000 - job.done_at < 8));
  b.hidden = !show;
  if (!show) return;
  $("job-name").textContent = job.name + (job.error ? " – Fehler" : job.running ? "" : " – fertig");
  $("job-percent").textContent = job.percent + " %";
  $("job-text").textContent = job.error || job.text;
  b.classList.toggle("failed", !!job.error);
  $("job-clear").hidden = !job.error;
  $("job-clear").textContent = job.name === "Ersteinrichtung" ? "Jetzt erneut versuchen" : "Schließen";
  blocks($("job-blocks"), job.percent);
}
$("job-clear").addEventListener("click", () => {
  const retry = $("job-name").textContent.startsWith("Ersteinrichtung");
  api(retry ? "/api/setup/run" : "/api/job/clear", {}).then(pollStatus).catch(() => {});
});

function setBar(id, frac) { $(id).style.width = Math.round(Math.max(0, Math.min(1, frac)) * 100) + "%"; }

function renderStatus(s) {
  state.status = s;
  renderJob(s.job);
  const pill = $("llama-pill");
  const ls = s.llama.state;
  pill.textContent = "KI: " + ls;
  pill.className = "pill " + (ls === "bereit" ? "ok" : ls === "lädt" || ls === "nicht eingerichtet" ? "warn" : "bad");
  $("send-btn").disabled = ls !== "bereit" || !!state.streaming;
  const ext = s.ext || {};
  state.ext = ext;
  $("nav-images").hidden = !ext.images;
  $("img-btn").hidden = !ext.vision;
  $("mic-btn").hidden = !ext.stt;
  let up = $("update-pill");
  if (!up) { up = document.createElement("button"); up.id = "update-pill"; up.type = "button"; up.className = "pill warn"; up.style.border = "0"; up.style.cursor = "pointer"; up.addEventListener("click", () => setView("system")); pill.before(up); }
  up.hidden = !(s.updates_available && s.updates_available.length);
  up.textContent = "Update verfügbar";
  if (state.lastJob && state.lastJob.running && !s.job.running) {
    if (state.view === "images") loadImages();
    if (state.view === "ext") loadExt();
    if (state.view === "models") loadModels();
  }
  state.lastJob = s.job;

  const ram = fmtGB(s.mem_used) + " / " + fmtGB(s.mem_total);
  $("p-ram").textContent = ram; setBar("pb-ram", s.mem_used / s.mem_total);
  $("p-cpu").textContent = s.cpu + " %"; setBar("pb-cpu", s.cpu / 100);
  $("p-disk").textContent = s.disk_total ? Math.round(100*s.disk_used/s.disk_total)+" %" : "–"; setBar("pb-disk", s.disk_total ? s.disk_used/s.disk_total : 0);
  $("p-temp").textContent = s.temp == null ? "–" : s.temp+" °C";
  $("p-tps").textContent = s.llama.tps ? String(s.llama.tps).replace(".", ",") + " T/s" : "–";
  $("p-model").textContent = s.llama.model ? s.llama.model.replace(/\.gguf$/, "") : "–";
  $("p-sleep").textContent = s.sleep_blockers.length
    ? "Bleibt wach: " + s.sleep_blockers.join(", ")
    : "Ohne Nutzung seit " + Math.floor(s.idle_seconds / 60) + " Min.";

  if (state.view === "system") {
    $("sys-sub").textContent = s.host + " · " + (s.cpu_name || "") + " · " + fmtGB(s.mem_total);
    $("m-ram").textContent = ram; setBar("b-ram", s.mem_used / s.mem_total);
    $("m-cpu").textContent = s.cpu + " %"; setBar("b-cpu", s.cpu / 100);
    $("m-disk").textContent = fmtGB(s.disk_used) + " / " + fmtGB(s.disk_total); setBar("b-disk", s.disk_used / s.disk_total);
    $("m-temp").textContent = s.temp == null ? "–" : s.temp + " °C";
    const h = Math.floor(s.uptime / 3600), m = Math.floor((s.uptime % 3600) / 60);
    $("m-up").textContent = h + " Std. " + m + " Min.";
    $("wol-box").textContent = "MAC  " + (s.mac || "–") + "\nIP   " + (s.ip || "–") + "\nName " + s.host + ".local";
    $("idle-info").textContent = s.sleep_blockers.length
      ? "Schläft gerade nicht, weil: " + s.sleep_blockers.join(", ") + "."
      : "Ohne Nutzung seit " + Math.floor(s.idle_seconds / 60) + " Minuten.";
    $("u-reboot").hidden = !s.reboot_required;
  }
}

async function pollStatus() {
  try { renderStatus(await api("/api/status")); } catch (e) { /* offline / schläft */ }
  const host = document.querySelector(".statuspanel");
  if (!host) return;
  let panel = $("team-live-status");
  if (!panel) {
    panel = document.createElement("section");
    panel.id = "team-live-status";
    panel.className = "tile";
    panel.setAttribute("aria-live", "polite");
    host.append(panel);
  }
  try {
    const {status: t} = await api("/api/team/status");
    const roles = {programming:"Programmier-KI", review:"Prüf-KI", analysis:"Analyse-KI"};
    const phases = {idle:"Bereit", planning:"Haupt-KI plant", specialist:(roles[t.role] || t.role) + " arbeitet", synthesis:"Haupt-KI führt Ergebnisse zusammen"};
    const heading = document.createElement("strong");
    heading.textContent = "KI-Team";
    const line = document.createElement("p");
    line.textContent = phases[t.phase] || "Unbekannter Status";
    const model = document.createElement("span");
    model.className = "muted small";
    model.textContent = t.phase === "specialist" ? t.model : "";
    const settings = document.createElement("button");
    settings.type = "button"; settings.className = "btn small";
    settings.textContent = "KI-Team verwalten";
    settings.onclick = () => openTeamSettings().catch(showErr);
    const knowledge = document.createElement("button");
    knowledge.type="button"; knowledge.className="btn small"; knowledge.textContent="Wissensbibliothek";
    knowledge.onclick=()=>openKnowledge().catch(showErr);
    panel.replaceChildren(heading,line,model,settings,knowledge);
  } catch(e) {
    panel.textContent = "KI-Team: Status nicht verfügbar";
  }
}

// ---------------------------------------------------------------- Markdown (klein)
function esc(t) { return t.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function inline(t) {
  return esc(t)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
}
function renderMarkdown(src, el) {
  el.innerHTML = "";
  const parts = src.split(/```/);
  parts.forEach((part, i) => {
    if (i % 2 === 1) {
      const nl = part.indexOf("\n");
      const lang = nl >= 0 ? part.slice(0, nl).trim() : "";
      const code = nl >= 0 ? part.slice(nl + 1) : part;
      const box = document.createElement("div"); box.className = "codebox";
      const head = document.createElement("div"); head.className = "codebox-head";
      const l = document.createElement("span"); l.textContent = lang || "Code";
      const btn = document.createElement("button"); btn.type = "button"; btn.className = "btn ghost small"; btn.textContent = "Kopieren";
      btn.addEventListener("click", () => copyText(code.replace(/\n$/, ""), btn));
      head.append(l, btn);
      const pre = document.createElement("pre"); const c = document.createElement("code"); c.textContent = code.replace(/\n$/, "");
      pre.appendChild(c); box.append(head, pre); el.appendChild(box);
      return;
    }
    const blocks = part.split(/\n{2,}/);
    blocks.forEach((b) => {
      if (!b.trim()) return;
      const lines = b.split("\n");
      if (lines.every((x) => /^\s*([-*]|\d+\.)\s+/.test(x) || !x.trim())) {
        const ordered = /^\s*\d+\./.test(lines[0]);
        const list = document.createElement(ordered ? "ol" : "ul");
        lines.filter((x) => x.trim()).forEach((x) => {
          const li = document.createElement("li"); li.innerHTML = inline(x.replace(/^\s*([-*]|\d+\.)\s+/, "")); list.appendChild(li);
        });
        el.appendChild(list);
      } else if (/^#{1,4}\s/.test(b)) {
        const h = document.createElement("p"); h.innerHTML = "<strong>" + inline(b.replace(/^#{1,4}\s/, "")) + "</strong>"; el.appendChild(h);
      } else {
        const p = document.createElement("p"); p.innerHTML = inline(b).replace(/\n/g, "<br>"); el.appendChild(p);
      }
    });
  });
}
function copyText(text, btn) {
  const done = () => { btn.textContent = "Kopiert ✓"; setTimeout(() => (btn.textContent = "Kopieren"), 1500); };
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(done).catch(() => fallbackCopy(text, done));
  } else fallbackCopy(text, done);
}
function fallbackCopy(text, done) {
  // http:// im Heimnetz ist kein "sicherer Kontext" – dann über ein unsichtbares Textfeld
  const ta = document.createElement("textarea"); ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
  document.body.appendChild(ta); ta.select();
  try { document.execCommand("copy"); done(); } catch (e) { /* nichts */ }
  ta.remove();
}

// ---------------------------------------------------------------- Chat
function currentChat() { return state.chats.find((c) => c.id === state.current); }

function newChat() {
  state.current = null;
  renderMessages(); renderHistory();
  $("input").focus();
}
$("new-chat").addEventListener("click", newChat);

function renderHistory() {
  const box = $("history"); box.innerHTML = "";
  state.chats.forEach((c) => {
    const row = document.createElement("div"); row.className = "hist" + (c.id === state.current ? " active" : "");
    const open = document.createElement("button"); open.type = "button"; open.className = "open"; open.textContent = c.title;
    open.addEventListener("click", () => { state.current = c.id; setView("chat"); renderMessages(); renderHistory(); });
    const del = document.createElement("button"); del.type = "button"; del.className = "del"; del.textContent = "×";
    del.setAttribute("aria-label", "Chat löschen: " + c.title);
    del.addEventListener("click", () => {
      state.chats = state.chats.filter((x) => x.id !== c.id);
      if (state.current === c.id) state.current = null;
      saveChats(); renderHistory(); renderMessages();
    });
    row.append(open, del); box.appendChild(row);
  });
}

function messageEl(m) {
  const d = document.createElement("div");
  d.className = "msg " + (m.role === "user" ? "user" : "bot");
  if (m.role === "user") {
    if (m.images && m.images.length) {
      const wrap = document.createElement("div"); wrap.className = "msg-images";
      m.images.forEach((src) => { const im = document.createElement("img"); im.src = src; im.alt = "angehängtes Bild"; wrap.appendChild(im); });
      d.appendChild(wrap);
    }
    d.appendChild(document.createTextNode(m.content));
  } else {
    if (m.think) { const t = document.createElement("details"); const s = document.createElement("summary"); s.textContent = "Gedanken der KI"; const p = document.createElement("div"); p.className = "think"; p.textContent = m.think; t.append(s, p); d.appendChild(t); }
    const body = document.createElement("div"); body.className = "msg bot"; renderMarkdown(m.content || "", body); d.appendChild(body);
    if (state.ext && state.ext.tts && m.content && !state.streaming) {
      const tools = document.createElement("div"); tools.className = "bot-tools";
      const b = document.createElement("button"); b.type = "button"; b.className = "btn small"; b.textContent = "Vorlesen";
      b.addEventListener("click", () => speak(m.content, b));
      tools.appendChild(b); d.appendChild(tools);
    }
  }
  return d;
}

function renderMessages() {
  const box = $("messages"); box.innerHTML = "";
  const c = currentChat();
  if (!c || !c.messages.length) {
    box.innerHTML = '<div class="empty"><h1>Willkommen im<br>Butchies KI Studio 5.0</h1><p>Dein persönlicher KI-Assistent auf dem eigenen Server.</p><div class="welcome-actions"><button class="btn" data-quick="chat">Chatten</button><button class="btn" data-quick="models">Modelle</button><button class="btn" data-quick="system">Server</button><button class="btn" data-quick="settings">Einstellungen</button></div></div>';
    return;
  }
  c.messages.forEach((m) => box.appendChild(messageEl(m)));
  box.scrollTop = box.scrollHeight;
}

$("input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("composer").requestSubmit(); }
});

$("attach-btn").addEventListener("click", () => $("attach").click());
$("attach").addEventListener("change", async () => {
  const f = $("attach").files[0]; if (!f) return;
  if (f.size > 400000) { alert("Die Datei ist zu groß (max. ca. 400 KB)."); return; }
  const text = await f.text();
  $("input").value += (($("input").value ? "\n\n" : "") + "Datei " + f.name + ":\n```\n" + text + "\n```\n");
  $("attach").value = "";
  $("input").focus();
});

$("stop-btn").addEventListener("click", () => { if (state.streaming) state.streaming.abort(); });

$("composer").addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = $("input").value.trim();
  const imgs = state.pendingImages || [];
  if ((!text && !imgs.length) || state.streaming) return;
  let c = currentChat();
  if (!c) {
    c = { id: Date.now().toString(36), title: (text || "Bild").slice(0, 40).replace(/\s+/g, " "), messages: [] };
    state.chats.unshift(c); state.current = c.id;
  }
  c.messages.push(imgs.length ? { role: "user", content: text, images: imgs } : { role: "user", content: text });
  state.pendingImages = []; renderAttach();
  const bot = { role: "assistant", content: "", think: "" };
  c.messages.push(bot);
  $("input").value = "";
  saveChats(); renderHistory(); renderMessages();

  const box = $("messages");
  const live = box.lastChild;
  live.classList.add("cursor");
  const ctrl = new AbortController(); state.streaming = ctrl;
  $("send-btn").disabled = true; $("stop-btn").hidden = false;
  try {
    const r = await fetch("/api/chat", {
      method: "POST", headers: { "Content-Type": "application/json" }, signal: ctrl.signal,
      body: JSON.stringify({ messages: c.messages.slice(0, -1).map((m) => (m.images ? { role: m.role, content: m.content, images: m.images } : { role: m.role, content: m.content })) }),
    });
    if (!r.ok) { let d = {}; try { d = await r.json(); } catch (x) { /* */ } throw new Error(d.error || "Fehler " + r.status); }
    const reader = r.body.getReader(); const dec = new TextDecoder(); let buf = ""; let last = 0;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, idx).trim(); buf = buf.slice(idx + 1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload === "[DONE]") continue;
        try {
          const j = JSON.parse(payload);
          const d = (j.choices && j.choices[0] && j.choices[0].delta) || {};
          if (d.reasoning_content) bot.think += d.reasoning_content;
          if (d.content) bot.content += d.content;
        } catch (x) { /* unvollständig */ }
      }
      if (Date.now() - last > 80) {
        last = Date.now();
        const fresh = messageEl(bot); fresh.classList.add("cursor");
        if (!bot.content && bot.think) fresh.querySelector("details") && (fresh.querySelector("details").open = true);
        box.replaceChild(fresh, box.lastChild); box.scrollTop = box.scrollHeight;
      }
    }
  } catch (err) {
    if (err.name !== "AbortError") bot.content += (bot.content ? "\n\n" : "") + "⚠ " + err.message;
  } finally {
    state.streaming = null; $("stop-btn").hidden = true;
    saveChats(); renderMessages(); pollStatus();
  }
});

// ---------------------------------------------------------------- Modelle
async function loadModels() {
  try {
    const d = await api("/api/models");
    populateChatModels(d.installed);
    $("models-free").textContent = "Freier Platz auf der SSD: " + fmtGB(d.free);
    const inst = $("models-installed"); inst.innerHTML = "";
    if (!d.installed.length) inst.innerHTML = '<p class="muted">Noch kein Modell installiert.</p>';
    d.installed.forEach((m) => {
      const it = document.createElement("div"); it.className = "item" + (m.active ? " active" : "");
      const info = document.createElement("div");
      info.innerHTML = '<div class="title"></div><div class="muted small"></div>';
      info.firstChild.textContent = m.name; if (m.active) info.firstChild.insertAdjacentHTML("beforeend", '<span class="badge">aktiv</span>');
      info.lastChild.textContent = m.file + " · " + fmtGB(m.size);
      const act = document.createElement("div"); act.className = "actions";
      if (!m.active) {
        const use = button("Benutzen", "primary", () => api("/api/models/activate", { file: m.file }).then(loadModels).then(pollStatus).catch(showErr));
        const del = button("Löschen", "danger", () => { if (confirm(m.name + " wirklich löschen?")) api("/api/models/delete", { file: m.file }).then(loadModels).catch(showErr); });
        act.append(use, del);
      }
      it.append(info, act); inst.appendChild(it);
    });
    const cat = $("models-catalog"); cat.innerHTML = "";
    d.catalog.forEach((m) => {
      const have = d.installed.some((x) => x.id === m.id);
      const it = document.createElement("div"); it.className = "item";
      const info = document.createElement("div");
      info.innerHTML = '<div class="title"></div><div class="muted small"></div>';
      info.firstChild.textContent = m.name; if (m.default) info.firstChild.insertAdjacentHTML("beforeend", '<span class="badge">Empfehlung</span>');
      info.lastChild.textContent = m.desc + " · ca. " + String(m.size_gb).replace(".", ",") + " GB";
      const act = document.createElement("div"); act.className = "actions";
      if (have) { const s = document.createElement("span"); s.className = "ok-text"; s.textContent = "installiert"; act.appendChild(s); }
      else act.appendChild(button("Herunterladen", "", () => api("/api/models/download", { id: m.id, activate: false }).then(pollStatus).catch(showErr)));
      it.append(info, act); cat.appendChild(it);
    });
  } catch (e) { showErr(e); }
}
function button(label, cls, fn) {
  const b = document.createElement("button"); b.type = "button"; b.className = "btn small " + cls; b.textContent = label;
  b.addEventListener("click", fn); return b;
}
function showErr(e) { alert(e.message || String(e)); }

// ---------------------------------------------------------------- System
document.querySelectorAll("[data-sys]").forEach((b) => b.addEventListener("click", async () => {
  const a = b.dataset.sys;
  const text = { sleep: "Mini-PC jetzt schlafen legen? Aufwecken geht dann nur per Weck-Helfer oder Wake-on-LAN.", reboot: "Mini-PC neu starten?", shutdown: "Mini-PC herunterfahren? Einschalten geht dann nur per Wake-on-LAN oder am Gerät." }[a];
  if (!confirm(text)) return;
  try { await api("/api/system/" + a, {}); alert("Befehl gesendet."); } catch (e) { showErr(e); }
}));

async function loadUpdates() {
  $("u-apt").textContent = "prüfe …";
  try {
    const d = await api("/api/updates");
    $("u-apt").textContent = d.apt == null ? "unbekannt" : d.apt === 0 ? "aktuell" : d.apt + " verfügbar";
    $("u-llama").textContent = (d.llama || "–") + (d.llama_latest && d.llama && d.llama_latest !== d.llama ? " → " + d.llama_latest + " verfügbar" : "");
    const newer = d.app_latest && verNum(d.app_latest) > verNum(d.app);
    $("u-app").textContent = d.app + (newer ? " → " + d.app_latest + " verfügbar" : d.app_latest ? " (aktuell)" : "");
    $("u-app-run").disabled = !newer;
    $("u-rollback").hidden = !d.rollback;
    $("u-checked").textContent = (d.checked ? "Zuletzt geprüft: " + new Date(d.checked * 1000).toLocaleString("de-DE") : "Noch nicht geprüft") + (d.check_error ? " – " + d.check_error : "");
    $("u-reboot").hidden = !d.reboot_required;
  } catch (e) { $("u-apt").textContent = "Fehler"; }
}
$("u-run").addEventListener("click", async () => {
  try { await api("/api/updates/run", { llama: $("u-with-llama").checked }); pollStatus(); } catch (e) { showErr(e); }
});
async function loadLogs() {
  try {
    const d = await api("/api/logs");
    $("logs").textContent = d.app.join("\n") || "(leer)";
    $("logs").scrollTop = $("logs").scrollHeight;
    $("logs-llama").textContent = d.llama || "(leer)";
  } catch (e) { /* */ }
}
$("logs-reload").addEventListener("click", loadLogs);

// ---------------------------------------------------------------- Einstellungen
async function loadSettings() {
  try {
    const s = (await api("/api/settings")).settings;
    $("s-sleep").checked = !!s.sleep_enabled; $("s-min").value = s.sleep_minutes;
    $("s-backend").value = s.backend; $("s-gpu").value = s.gpu_layers; $("s-ctx").value = s.ctx; $("s-threads").value = s.threads;
    $("s-repo").value = s.update_repo || ""; $("s-token").value = "";
    $("s-token").placeholder = s.github_token_set ? "gesetzt – leer lassen = unverändert" : "nicht gesetzt";
  } catch (e) { showErr(e); }
}
$("settings-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  try {
    await api("/api/settings", {
      sleep_enabled: $("s-sleep").checked, sleep_minutes: +$("s-min").value, backend: $("s-backend").value,
      gpu_layers: +$("s-gpu").value, ctx: +$("s-ctx").value, threads: +$("s-threads").value,
      update_repo: $("s-repo").value.trim(), github_token: $("s-token").value.trim(),
    });
    $("settings-msg").textContent = "Gespeichert ✓";
    setTimeout(() => ($("settings-msg").textContent = ""), 2500);
    pollStatus();
  } catch (err) { $("settings-msg").textContent = err.message; }
});
$("pw-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  try {
    await api("/api/password", { old: $("pw-old").value, new: $("pw-new").value, linux: $("pw-linux").checked });
    $("pw-msg").textContent = "Passwort geändert ✓"; $("pw-old").value = ""; $("pw-new").value = "";
  } catch (err) { $("pw-msg").textContent = err.message; }
});

// ---------------------------------------------------------------- Updates (Butchies)
function verNum(v) { return (v || "0").split(".").map((x) => parseInt(x, 10) || 0).reduce((a, x) => a * 1000 + x, 0); }
$("u-check").addEventListener("click", async () => {
  try { await api("/api/updates/check", {}); $("u-checked").textContent = "Prüfe …"; setTimeout(loadUpdates, 6000); } catch (e) { showErr(e); }
});
$("u-app-run").addEventListener("click", async () => {
  if (!confirm("Butchies KI Studio jetzt aktualisieren? Die aktuelle Version wird vorher gesichert.")) return;
  try { await api("/api/app/update", {}); pollStatus(); } catch (e) { showErr(e); }
});
$("u-rollback").addEventListener("click", async () => {
  if (!confirm("Zur vorherigen Version zurückgehen?")) return;
  try { await api("/api/app/rollback", {}); pollStatus(); } catch (e) { showErr(e); }
});

// ---------------------------------------------------------------- Eigene Modelle
$("custom-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("custom-msg").textContent = "";
  try { await api("/api/models/custom", { url: $("custom-url").value.trim() }); $("custom-url").value = ""; pollStatus(); }
  catch (err) { $("custom-msg").textContent = err.message; }
});

// ---------------------------------------------------------------- Erweiterungen
async function loadExt() {
  try {
    const d = await api("/api/ext");
    const box = $("ext-list"); box.innerHTML = "";
    d.ext.forEach((x) => {
      const it = document.createElement("div"); it.className = "item";
      const info = document.createElement("div");
      info.innerHTML = '<div class="title"></div><div class="muted small"></div>';
      info.firstChild.textContent = x.name;
      const sp = document.createElement("span"); sp.className = "speed " + x.speed;
      sp.textContent = { gut: "läuft gut", langsam: "langsam", coming_soon: "kommt später" }[x.speed] || x.speed;
      info.firstChild.appendChild(sp);
      if (x.installed) info.firstChild.insertAdjacentHTML("beforeend", '<span class="badge">installiert</span>');
      info.lastChild.textContent = x.desc + (x.size_gb ? " · ca. " + String(x.size_gb).replace(".", ",") + " GB" : "") + (x.state && x.installed ? " · Status: " + x.state : "");
      const act = document.createElement("div"); act.className = "actions";
      if (x.speed === "coming_soon") { const s = document.createElement("span"); s.className = "muted small"; s.textContent = "Coming soon"; act.appendChild(s); }
      else if (x.installed) act.appendChild(button("Entfernen", "danger", () => { if (confirm(x.name + " entfernen?")) api("/api/ext/remove", { id: x.id }).then(loadExt).then(pollStatus).catch(showErr); }));
      else act.appendChild(button("Installieren", "primary", () => api("/api/ext/install", { id: x.id }).then(pollStatus).catch(showErr)));
      it.append(info, act); box.appendChild(it);
    });
  } catch (e) { showErr(e); }
}

// ---------------------------------------------------------------- Bilder anhängen (Bilder verstehen)
state.pendingImages = [];
function renderAttach() {
  const box = $("attach-preview"); box.innerHTML = "";
  state.pendingImages.forEach((src, i) => {
    const im = document.createElement("img"); im.src = src; im.alt = "Bild " + (i + 1); im.title = "Klicken zum Entfernen";
    im.addEventListener("click", () => { state.pendingImages.splice(i, 1); renderAttach(); });
    box.appendChild(im);
  });
}
function addImageFile(file) {
  if (!file || !file.type.startsWith("image/")) return;
  const reader = new FileReader();
  reader.onload = () => {
    const img = new Image();
    img.onload = () => {
      const max = 1280, k = Math.min(1, max / Math.max(img.width, img.height));
      const cv = document.createElement("canvas"); cv.width = Math.round(img.width * k); cv.height = Math.round(img.height * k);
      cv.getContext("2d").drawImage(img, 0, 0, cv.width, cv.height);
      state.pendingImages.push(cv.toDataURL("image/jpeg", 0.88)); renderAttach();
    };
    img.src = reader.result;
  };
  reader.readAsDataURL(file);
}
$("img-btn").addEventListener("click", () => $("img-file").click());
$("img-file").addEventListener("change", () => { [...$("img-file").files].forEach(addImageFile); $("img-file").value = ""; });
$("input").addEventListener("paste", (e) => {
  if (!state.ext || !state.ext.vision) return;
  [...(e.clipboardData && e.clipboardData.items || [])].forEach((it) => { if (it.type.startsWith("image/")) addImageFile(it.getAsFile()); });
});

// ---------------------------------------------------------------- Diktieren (Sprache -> Text)
let recorder = null;
async function sendAudio(blob) {
  $("mic-btn").textContent = "Wird erkannt …"; $("mic-btn").disabled = true;
  try {
    const r = await fetch("/api/stt", { method: "POST", headers: { "Content-Type": blob.type || "application/octet-stream" }, body: blob });
    const d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.error || "Fehler");
    $("input").value += ($("input").value ? " " : "") + d.text; $("input").focus();
  } catch (e) { showErr(e); }
  finally { $("mic-btn").textContent = "Diktieren"; $("mic-btn").disabled = false; }
}
$("mic-btn").addEventListener("click", async () => {
  if (recorder) { recorder.stop(); return; }
  if (!(navigator.mediaDevices && window.isSecureContext && window.MediaRecorder)) {
    alert("Das Mikrofon geht nur im Butchies-KI-Fenster aus der Taskleiste (oder per https). Du kannst stattdessen eine Audiodatei auswählen.");
    $("audio-file").click(); return;
  }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const chunks = [];
    recorder = new MediaRecorder(stream);
    recorder.ondataavailable = (e) => chunks.push(e.data);
    recorder.onstop = () => {
      stream.getTracks().forEach((t) => t.stop());
      $("mic-btn").classList.remove("rec");
      const blob = new Blob(chunks, { type: recorder.mimeType || "audio/webm" }); recorder = null; sendAudio(blob);
    };
    recorder.start(); $("mic-btn").textContent = "Stopp (Aufnahme läuft)"; $("mic-btn").classList.add("rec");
  } catch (e) { recorder = null; showErr(e); }
});
$("audio-file").addEventListener("change", () => { const f = $("audio-file").files[0]; if (f) sendAudio(f); $("audio-file").value = ""; });

// ---------------------------------------------------------------- Vorlesen (Text -> Sprache)
let audioEl = null;
async function speak(text, btn) {
  if (audioEl) { audioEl.pause(); audioEl = null; btn.textContent = "Vorlesen"; return; }
  btn.textContent = "Wird erzeugt …";
  try {
    const r = await fetch("/api/tts", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
    if (!r.ok) { const d = await r.json().catch(() => ({})); throw new Error(d.error || "Fehler " + r.status); }
    audioEl = new Audio(URL.createObjectURL(await r.blob()));
    audioEl.onended = () => { audioEl = null; btn.textContent = "Vorlesen"; };
    btn.textContent = "Stopp"; audioEl.play();
  } catch (e) { btn.textContent = "Vorlesen"; showErr(e); }
}

// ---------------------------------------------------------------- Bilder erzeugen
async function loadImages() {
  try {
    const d = await api("/api/images");
    const g = $("gallery"); g.innerHTML = "";
    if (!d.images.length) g.innerHTML = '<p class="muted">Noch keine Bilder.</p>';
    d.images.forEach((im) => {
      const f = document.createElement("figure");
      const a = document.createElement("a"); a.href = "/api/images/file/" + encodeURIComponent(im.file); a.target = "_blank"; a.rel = "noopener";
      const img = document.createElement("img"); img.src = a.href; img.alt = im.prompt || im.file; img.loading = "lazy"; a.appendChild(img);
      const cap = document.createElement("figcaption"); const t = document.createElement("span"); t.textContent = im.prompt || im.file;
      cap.append(t, button("Löschen", "danger", () => { if (confirm("Bild löschen?")) api("/api/images/delete", { file: im.file }).then(loadImages).catch(showErr); }));
      f.append(a, cap); g.appendChild(f);
    });
  } catch (e) { showErr(e); }
}
$("img-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  try { await api("/api/images/generate", { prompt: $("img-prompt").value, steps: +$("img-steps").value }); pollStatus(); } catch (err) { showErr(err); }
});

// ---------------------------------------------------------------- Akzentfarbe aus Windows (vom Taskleisten-Programm übergeben)
(function accentFromWindows() {
  let acc = null;
  try {
    const q = new URLSearchParams(location.search).get("accent");
    if (q && /^[0-9a-fA-F]{6}$/.test(q)) { acc = q; localStorage.setItem("bki-accent", q); history.replaceState(null, "", location.pathname); }
    else acc = localStorage.getItem("bki-accent");
  } catch (e) { /* kein Speicher */ }
  if (!acc) return;
  const r = parseInt(acc.slice(0, 2), 16), g = parseInt(acc.slice(2, 4), 16), b = parseInt(acc.slice(4, 6), 16);
  const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  document.documentElement.style.setProperty("--accent", "#" + acc);
  document.documentElement.style.setProperty("--on-accent", lum > 0.55 ? "#000000" : "#ffffff");
})();

// ---------------------------------------------------------------- Start
let pollTimer = null;
function startApp() {
  refreshChatModels();
  $("gate").hidden = true; $("app").hidden = false;
  loadChats(); renderHistory(); renderMessages(); setView(state.view);
  pollStatus();
  clearInterval(pollTimer); pollTimer = setInterval(pollStatus, 4000);
}

(async function init() {
  try {
    const s = await api("/api/state");
    if (s.needs_password) showGate(true);
    else if (!s.logged_in) showGate(false);
    else startApp();
  } catch (e) {
    document.body.textContent = "Butchies KI Studio ist gerade nicht erreichbar: " + e.message;
  }
})();

$("gate-recover").addEventListener("click", async () => {
  const code = prompt("Wiederherstellungscode");
  if (code === null) return;
  const pw = prompt("Neues Passwort (mindestens 4 Zeichen)");
  if (pw === null) return;
  if (pw.length < 4 || pw !== prompt("Neues Passwort wiederholen")) { $("gate-error").textContent = "Passwörter prüfen."; return; }
  try { await api("/api/recover", {code, password: pw}); showGate(false); $("gate-error").textContent = "Passwort geändert. Bitte anmelden."; } catch(e) { $("gate-error").textContent = e.message; }
});

$("sidebar-toggle").addEventListener("click", () => document.querySelector(".layout").classList.toggle("sidebar-collapsed"));
$("messages").addEventListener("click", e => { const b=e.target.closest("[data-quick]"); if(b) document.querySelector(`.nav[data-view="${b.dataset.quick}"]`)?.click(); });

function populateChatModels(models) {
  const select = $("chat-model");
  select.replaceChildren();
  if (!models.length) { select.add(new Option("Kein Modell installiert", "")); select.disabled=true; return; }
  select.disabled=false;
  models.slice().sort((a,b)=>a.name.localeCompare(b.name,"de")).forEach(m=>select.add(new Option(m.name,m.file,false,!!m.active)));
}
async function refreshChatModels() {
  try { const d=await api("/api/models"); populateChatModels(d.installed); } catch(e) { $("chat-model").disabled=true; }
}
$("chat-model").addEventListener("change", async () => {
  const select=$("chat-model"); if(!select.value)return;
  select.disabled=true; $("send-btn").disabled=true;
  try { await api("/api/models/activate",{file:select.value}); await pollStatus(); }
  catch(e){showErr(e);}
  finally { await refreshChatModels(); $("send-btn").disabled=false; }
});

async function loadStorage() {
  const list = $("storage-list");
  list.textContent = "Datenträger werden gesucht …";
  try {
    const d = await api("/api/storage");
    list.replaceChildren();
    try {
      const result = await api("/api/storage/migration-status");
      const m = result.migration;
      if (m && m.state !== "idle") {
        const panel = document.createElement("section");
        const heading = document.createElement("h3");
        heading.textContent = "Letzte Speicherverlagerung";
        const status = document.createElement("p");
        status.textContent = ({running:"Verlagerung begonnen; Abschluss noch nicht bestätigt", completed:"Verlagerung abgeschlossen", failed:"Verlagerung fehlgeschlagen"})[m.state] || m.state;
        panel.append(heading,status);
        if (Number.isFinite(m.percent)) {
          const bar = document.createElement("progress");
          bar.max=100; bar.value=m.percent; bar.style.width="100%";
          bar.setAttribute("aria-label","Zuletzt gespeicherter Verlagerungsfortschritt");
          panel.append(bar,document.createTextNode(m.percent+" %"));
        }
        for (const value of [m.target, m.error, m.timestamp ? new Date(m.timestamp*1000).toLocaleString("de-DE") : ""]) {
          if (!value) continue;
          const line=document.createElement("p"); line.textContent=value; panel.append(line);
        }
        list.append(panel);
      }
    } catch(e) {
      const note=document.createElement("p"); note.textContent="Verlagerungsprotokoll nicht verfügbar: "+e.message; list.append(note);
    }
    for (const disk of d.devices) {
      const row = document.createElement("div"); row.className = "item";
      const info = document.createElement("div");
      const title = document.createElement("strong"); title.textContent = disk.path || disk.name;
      const details = document.createElement("p"); details.className = "muted";
      details.textContent = [disk.fstype || disk.type, disk.mountpoint || "Nicht eingebunden", disk.ro ? "Schreibgeschützt" : "", ((Number(disk.size)||0)/1e9).toFixed(1)+" GB"].filter(Boolean).join(" · ");
      info.append(title,details);
      if (disk.total > 0) {
        const percent = Math.round(disk.used / disk.total * 100);
        const bar = document.createElement("progress"); bar.max=100; bar.value=percent; bar.style.width="100%"; bar.setAttribute("aria-label","Speicherbelegung");
        const usage = document.createElement("p"); usage.textContent = percent+" % belegt · "+(disk.available/1e9).toFixed(1)+" GB"+" bis zur 90-%-Grenze verfügbar";
        if(percent>=85) usage.style.color="#A65B00";
        info.append(bar,usage);
      }
      row.append(info);
      const approved = disk.uuid && Object.prototype.hasOwnProperty.call(d.approved || {}, disk.uuid);
      if (approved) {
        const note = document.createElement("p");
        note.textContent = "Freigegeben (noch keine Datenverlagerung)";
        info.append(note);
        if (disk.mountpoint && !disk.ro && disk.available > 0) {
          row.append(button("Daten verlagern", "", async () => {
            try {
              const result = await api("/api/storage/plan", {uuid:disk.uuid});
              const p = result.plan;
              if (!p.fits) throw new Error("Nicht genug Speicher bis zur 90-%-Grenze.");
              if (!confirm("Datenverlagerung bestätigen?\nQuelle: "+p.source+"\nZiel: "+p.target+"\nDateien: "+p.files+"\nGröße: "+(p.bytes/1e9).toFixed(2)+" GB\nDer Server ist währenddessen nicht erreichbar. Originaldateien bleiben erhalten.")) return;
              await api("/api/storage/migrate", {uuid:disk.uuid, confirmed:true});
              alert("Verlagerung beauftragt. Der Server wird nach Abschluss erneut gestartet.");
            } catch(e) { showErr(e); }
          }));
        }
        row.append(button("Freigabe widerrufen", "", async () => {
          if (!confirm("Freigabe widerrufen? Dateien bleiben unverändert.")) return;
          try { await api("/api/storage/revoke", {uuid:disk.uuid, confirmed:true}); await loadStorage(); }
          catch(e) { showErr(e); }
        }));
      } else if (disk.uuid && disk.mountpoint && disk.mountpoint !== "/" && !disk.ro && disk.available > 0) {
        row.append(button("Speicher freigeben", "", async () => {
          if (!confirm("Datenträger " + disk.path + " (" + disk.mountpoint + ") dauerhaft freigeben? Es werden keine Dateien verschoben.")) return;
          try { await api("/api/storage/approve", {uuid:disk.uuid, confirmed:true}); await loadStorage(); }
          catch(e) { showErr(e); }
        }));
      }
      list.append(row);
    }
    for (const [uuid, saved] of Object.entries(d.approved || {})) {
      if (d.devices.some(disk => disk.uuid === uuid && disk.mountpoint)) continue;
      const row = document.createElement("div"); row.className = "item";
      const note = document.createElement("p"); note.textContent = "Freigegebener Speicher nicht verfügbar: " + saved.mountpoint + " (" + uuid + ")";
      row.append(note, button("Freigabe widerrufen", "", async () => {
        if (!confirm("Freigabe widerrufen?")) return;
        try { await api("/api/storage/revoke", {uuid, confirmed:true}); await loadStorage(); }
        catch(e) { showErr(e); }
      }));
      list.append(row);
    }
    if (!list.children.length) list.textContent="Keine Datenträger gefunden.";
  } catch(e) { list.textContent=e.message || String(e); }
}
$("storage-refresh").addEventListener("click",loadStorage);

async function openTeamSettings() {
  if ($("team-settings-dialog")) return;
  const data = await api("/api/team");
  if ($("team-settings-dialog")) return;
  const dialog = document.createElement("dialog");
  dialog.id = "team-settings-dialog";
  dialog.style.cssText = "max-width:560px;width:90%;padding:24px;border:1px solid #91b5d8;border-radius:12px;background:#edf5fc;color:#102650";
  const title = document.createElement("h2"); title.textContent = "KI-Team verwalten";
  const enabled = document.createElement("input"); enabled.type="checkbox"; enabled.checked=!!data.team.enabled;
  const toggle = document.createElement("label"); toggle.append(enabled,document.createTextNode(" KI-Team aktivieren"));
  dialog.append(title,toggle);
  const fields = {};
  for (const [role,name] of Object.entries({programming:"Programmier-KI",review:"Prüf-KI",analysis:"Analyse-KI"})) {
    const label=document.createElement("label"); label.style.display="block"; label.style.marginTop="12px"; label.textContent=name;
    const select=document.createElement("select"); select.style.width="100%";
    select.add(new Option("Nicht zugewiesen",""));
    for (const m of data.models) select.add(new Option(m.name,m.file));
    select.value=data.team.roles[role] || "";
    fields[role]=select; label.append(select); dialog.append(label);
  }
  const note=document.createElement("p"); note.textContent="Bild- und Sprachspezialisten folgen separat.";
  const save=document.createElement("button"); save.type="button"; save.className="btn primary"; save.textContent="Speichern";
  const cancel=document.createElement("button"); cancel.type="button"; cancel.className="btn"; cancel.textContent="Abbrechen";
  cancel.onclick=()=>dialog.close();
  save.onclick=async()=>{
    save.disabled=true;
    try {
      const roles={...data.team.roles};
      for (const [role,field] of Object.entries(fields)) {
        if(field.value) roles[role]=field.value; else delete roles[role];
      }
      await api("/api/team/config",{enabled:enabled.checked,roles});
      dialog.close();
    } catch(e) { showErr(e); save.disabled=false; }
  };
  dialog.append(note,save,cancel);
  dialog.addEventListener("close",()=>dialog.remove(),{once:true});
  document.body.append(dialog); dialog.showModal();
}

async function openKnowledge() {
  if ($("knowledge-dialog")) return;
  const d=document.createElement("dialog"); d.id="knowledge-dialog";
  d.style.cssText="width:90%;max-width:850px;max-height:85vh;overflow:auto;background:#edf5fc;color:#102650;border:1px solid #91b5d8;border-radius:12px;padding:24px";
  const make=(tag,text)=>{const e=document.createElement(tag);if(text)e.textContent=text;return e;};
  const button=(text,fn)=>{const b=make("button",text);b.type="button";b.className="btn small";b.onclick=()=>Promise.resolve().then(fn).catch(showErr);return b;};
  const query=make("input");query.placeholder="Wissen durchsuchen";
  const category=make("input");category.placeholder="Kategorie";category.value="Allgemein";
  const content=make("textarea");content.placeholder="Wissenseintrag";content.style.width="100%";
  const list=make("div");let editing=null;const selected=new Set();
  const usageInfo=make("p"); const categoryInfo=make("div");
  let categoryFilter=null, cursor=null, nextCursor=null, history=[], activeQuery="", activeCategory=null, requestId=0;
  const pageInfo=make("span");
  const prev=button("Zurück",()=>{if(history.length)return load(history.pop(),false);});
  const next=button("Weiter",()=>{if(nextCursor!==null){history.push(cursor);return load(nextCursor,false);}});
  async function load(before=null,reset=true){
    if(reset){history=[];activeQuery=query.value;activeCategory=categoryFilter;}
    const id=++requestId;
    prev.disabled=true;next.disabled=true;
    const result=await api("/api/knowledge/search",{query:activeQuery,category:activeCategory,before});
    if(id!==requestId)return;
    cursor=before;nextCursor=result.next_before??null;
    pageInfo.textContent=" Seite "+(history.length+1)+" ";
    prev.disabled=!history.length;next.disabled=nextCursor===null;
    selected.clear();list.replaceChildren();
    try {
      const usage=await api("/api/knowledge/usage",{});
      const mib=n=>(n/1048576).toFixed(2)+" MiB";
      usageInfo.textContent=usage.entries+" Einträge · Datenbank: "+mib(usage.database_bytes)+" · Sicherungen: "+mib(usage.backup_bytes);
      categoryInfo.replaceChildren(button("Alle Kategorien",()=>{categoryFilter=null;return load();}));
      for(const [name,count] of Object.entries(usage.categories)){
        categoryInfo.append(button(name+" ("+count+")",()=>{query.value="";categoryFilter=name;category.value=name;return load();}));
      }
    } catch(e){usageInfo.textContent="Speicherstatistik nicht verfügbar";}
    if(id!==requestId)return;
    for(const entry of result.entries){
      const row=make("section");row.className="tile";
      const check=make("input");check.type="checkbox";check.onchange=()=>check.checked?selected.add(entry.id):selected.delete(entry.id);
      const body=make("p",entry.content);body.style.whiteSpace="pre-wrap";
      row.append(check,make("strong",entry.category),body,button("Bearbeiten",()=>{editing=entry.id;category.value=entry.category;content.value=entry.content;content.focus();}));
      list.append(row);
    }
  }
  async function remove(payload){
    if(!confirm("Ausgewählte Wissenseinträge endgültig löschen?"))return;
    await api("/api/knowledge/delete",{...payload,confirmed:true});editing=null;await load();
  }
  async function exportKnowledge(markdown=false){
    const archive=await api("/api/knowledge/export",{});
    const body=markdown?archive.entries.map(e=> "## "+e.category+"\n\n"+e.content).join("\n\n---\n\n"):JSON.stringify(archive,null,2);
    const url=URL.createObjectURL(new Blob([body],{type:markdown?"text/markdown;charset=utf-8":"application/json"}));
    const link=make("a");link.href=url;link.download="Butchies-Wissen-"+new Date().toISOString().slice(0,10)+(markdown?".md":".json");
    document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }
  const file=make("input");file.type="file";file.accept=".json,application/json";file.hidden=true;
  file.onchange=async()=>{
    try{
      const f=file.files[0];if(!f)return;
      if(f.size>20*1024*1024)throw new Error("Archiv größer als 20 MiB");
      const archive=JSON.parse(await f.text());
      if(!confirm("Wissensarchiv ergänzend importieren?"))return;
      const result=await api("/api/knowledge/import",archive);
      alert(result.imported+" Wissenseinträge importiert.");await load();
    }catch(e){showErr(e);}finally{file.value="";}
  };
  const backupSelect=make("select");
  const backupInfo=make("p");
  async function refreshBackups(){
    const result=await api("/api/knowledge/backups",{});
    backupSelect.replaceChildren(new Option("Sicherung auswählen",""));
    for(const name of result.backups)backupSelect.add(new Option(name,name));
    backupInfo.textContent="Sicherungsort: "+result.folder;
  }
  d.append(make("h3","Datensicherung"),backupInfo,backupSelect,
    button("Sicherungen anzeigen",refreshBackups),
    button("Jetzt sichern",async()=>{await api("/api/knowledge/backup-now",{});await refreshBackups();await load();}),
    button("Wiederherstellen",async()=>{
      if(!backupSelect.value)throw new Error("Bitte eine Sicherung auswählen.");
      if(!confirm("Wissen aus dieser Sicherung ergänzen? Bestehende Einträge bleiben erhalten."))return;
      const result=await api("/api/knowledge/restore",{name:backupSelect.value,confirmed:true});
      alert(result.restored+" Wissenseinträge wiederhergestellt.");await load();
    }));
  d.append(file,button("JSON exportieren",()=>exportKnowledge()),button("Markdown exportieren",()=>exportKnowledge(true)),button("JSON importieren",()=>file.click()));
  d.append(make("h2","Wissensbibliothek"),usageInfo,categoryInfo,query,button("Suchen",load),category,content,
    button("Speichern",async()=>{await api(editing===null?"/api/knowledge/add":"/api/knowledge/edit",{id:editing,category:category.value,content:content.value});editing=null;content.value="";await load();}),
    button("Neuer Eintrag",()=>{editing=null;content.value="";}),
    button("Auswahl löschen",()=>remove({ids:[...selected]})),
    button("Kategorie löschen",()=>remove({category:category.value})),
    button("Alles löschen",()=>remove({all:true})),button("Schließen",()=>d.close()),prev,pageInfo,next,list);
  d.addEventListener("close",()=>d.remove(),{once:true});document.body.append(d);d.showModal();await load();
}
