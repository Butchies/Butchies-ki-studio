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
