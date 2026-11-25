#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Butchies KI Studio – Server für den Mini-PC.

Läuft als root-Dienst (butchies-ki.service) und stellt bereit:
  * die Browser-Oberfläche auf Port 80 (http://butchies-ki.local)
  * die Steuerung der KI-Laufzeit (llama.cpp / llama-server auf 127.0.0.1:8081)
  * Ersteinrichtung (KI-Laufzeit + Modell herunterladen, mit Fortschritt in %)
  * Fernsteuerung: Updates, Ruhezustand, Neustart, Herunterfahren, Protokoll

Nur Python-Standardbibliothek, damit nichts nachinstalliert werden muss.

Umgebungsvariablen (vor allem zum Testen):
  BKI_ETC    Konfigurationsordner   (Standard /etc/butchies-ki)
  BKI_DATA   Datenordner            (Standard /var/lib/butchies-ki)
  BKI_PORT   Port der Oberfläche    (Standard 80)
  BKI_DRYRUN=1  keine Systembefehle (suspend, reboot, apt …) wirklich ausführen
  BKI_NOSETUP=1 keine automatische Ersteinrichtung beim Start
"""

import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.4.8"

APP_DIR = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(APP_DIR, "web")
ETC_DIR = os.environ.get("BKI_ETC", "/etc/butchies-ki")
DATA_DIR = os.environ.get("BKI_DATA", "/var/lib/butchies-ki")
MODEL_DIR = os.path.join(DATA_DIR, "models")
LLAMA_DIR = os.path.join(DATA_DIR, "llama")
CONFIG_PATH = os.path.join(ETC_DIR, "config.json")
LOG_PATH = os.path.join(DATA_DIR, "butchies-ki.log")
PORT = int(os.environ.get("BKI_PORT", "80"))
DRYRUN = os.environ.get("BKI_DRYRUN") == "1"
LLAMA_PORT = 8081
USER_AGENT = "ButchiesKIStudio/" + VERSION

# Modell-Katalog. Die Datei wird beim Download über die Hugging-Face-API gesucht
# (passend zu "pattern"), damit kleine Namensänderungen nicht alles kaputt machen.
CATALOG = [
    {
        "id": "qwen3-coder-30b",
        "name": "Qwen3-Coder 30B-A3B",
        "repo": "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
        "pattern": "Q4_K_M.gguf",
        "size_gb": 17.3,
        "desc": "Hauptmodell fürs Programmieren (Standard). MoE – läuft auf dem Prozessor gut.",
        "default": True,
        "temperature": 0.7,
        "top_p": 0.8,
    },
    {
        "id": "gpt-oss-20b",
        "name": "gpt-oss-20b",
        "repo": "unsloth/gpt-oss-20b-GGUF",
        "pattern": "Q4_K_M.gguf",
        "size_gb": 11.6,
        "desc": "Allrounder mit Denk-Modus, etwas kleiner und schneller.",
        "default": False,
        "temperature": 1.0,
        "top_p": 1.0,
    },
    {
        "id": "qwen3-8b",
        "name": "Qwen3 8B",
        "repo": "Qwen/Qwen3-8B-GGUF",
        "pattern": "Q4_K_M.gguf",
        "size_gb": 5.0,
        "desc": "Klein und schnell für kurze Fragen.",
        "default": False,
        "temperature": 0.7,
        "top_p": 0.8,
    },
]

DEFAULT_CONFIG = {
    "username": "butchies",
    "sleep_enabled": True,
    "sleep_minutes": 5,
    "ctx": 16384,
    "gpu_layers": 0,
    "threads": 0,           # 0 = automatisch (physische Kerne)
    "backend": "vulkan",    # "vulkan" oder "cpu"
    "active_model": "",     # Dateiname in MODEL_DIR
    "ui_password": None,    # {"salt": "...", "hash": "..."}
}

SYSTEM_PROMPT = (
    "Du bist Butchies KI, ein hilfsbereiter Assistent fürs Programmieren und Erklären. "
    "Du läufst komplett offline auf einem Mini-PC im Heimnetz. Antworte auf Deutsch, "
    "klar und einfach. Code immer in Markdown-Codeblöcken mit Sprachangabe. "
    "Wenn du etwas nicht sicher weißt, sag das ehrlich."
)

# ---------------------------------------------------------------------------
# Protokoll
# ---------------------------------------------------------------------------

_log_lock = threading.Lock()
_log_buffer = deque(maxlen=500)


def log(msg):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + msg
    with _log_lock:
        _log_buffer.append(line)
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass
    print(line, flush=True)


# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

_cfg_lock = threading.Lock()


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    return cfg


def save_config(cfg):
    with _cfg_lock:
        os.makedirs(ETC_DIR, exist_ok=True)
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG_PATH)


CONFIG = load_config()
_password_lock = threading.Lock()
RECOVERY_PATH = os.path.join(ETC_DIR, "studio-recovery")


def create_recovery_code():
    if os.geteuid() != 0:
        raise SystemExit("Bitte mit sudo ausführen.")
    os.makedirs(ETC_DIR, exist_ok=True)
    code = secrets.token_urlsafe(24)
    tmp = RECOVERY_PATH + "." + secrets.token_hex(8)
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        json.dump({"hash": hashlib.sha256(code.encode()).hexdigest(),
                   "expires": time.time() + 600}, f)
    os.replace(tmp, RECOVERY_PATH)
    print("Einmalcode (10 Minuten gültig): " + code)


def password_error(password):
    if len(password) < 4:
        return "Das Passwort braucht mindestens 4 Zeichen"
    if password == "0000":
        return "0000 ist für die Wiederherstellung reserviert"
    return ""


def set_ui_password(password):
    updated = dict(CONFIG, ui_password=hash_password(password))
    save_config(updated)
    CONFIG["ui_password"] = updated["ui_password"]



def hash_password(password, salt=None):
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), bytes.fromhex(salt), 200_000)
    return {"salt": salt, "hash": h.hex()}


def check_password(password):
    stored = CONFIG.get("ui_password")
    if not stored:
        return False
    test = hash_password(password, stored["salt"])
    return hmac.compare_digest(test["hash"], stored["hash"])


# ---------------------------------------------------------------------------
# Hilfsfunktionen System
# ---------------------------------------------------------------------------

def run(cmd, timeout=60):
    """Befehl ausführen, Ausgabe zurückgeben (nie Exception)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except (OSError, subprocess.SubprocessError) as e:
        return 1, str(e)


def system_action(cmd):
    if DRYRUN:
        log("[Testmodus] würde ausführen: " + " ".join(cmd))
        return 0, ""
    return run(cmd)


def read_file(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return default


def main_interface():
    """Erste kabelgebundene Netzwerkschnittstelle mit Verbindung."""
    try:
        names = sorted(os.listdir("/sys/class/net"))
    except OSError:
        return None
    best = None
    for n in names:
        if n == "lo" or n.startswith(("docker", "veth", "br-", "virbr", "wl")):
            continue
        if read_file("/sys/class/net/%s/type" % n) != "1":
            continue
        if read_file("/sys/class/net/%s/operstate" % n) == "up":
            return n
        best = best or n
    return best


def ip_address():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return ""


_cpu_prev = None


def cpu_percent():
    global _cpu_prev
    line = read_file("/proc/stat").splitlines()
    if not line:
        return 0
    vals = [int(x) for x in line[0].split()[1:]]
    idle, total = vals[3] + vals[4], sum(vals)
    prev, _cpu_prev = _cpu_prev, (idle, total)
    if not prev or total == prev[1]:
        return 0
    return round(100 * (1 - (idle - prev[0]) / (total - prev[1])))


def cpu_temp():
    base = "/sys/class/hwmon"
    try:
        for h in os.listdir(base):
            name = read_file(os.path.join(base, h, "name"))
            if name in ("k10temp", "zenpower", "coretemp"):
                t = read_file(os.path.join(base, h, "temp1_input"))
                if t:
                    return round(int(t) / 1000)
    except OSError:
        pass
    return None


def meminfo():
    info = {}
    for line in read_file("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        info[k] = int(v.split()[0]) * 1024 if v.strip() else 0
    return info.get("MemTotal", 0), info.get("MemAvailable", 0)


def cpu_name():
    for line in read_file("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            return line.split(":", 1)[1].strip()
    return ""


def ssh_sessions():
    code, out = run(["ss", "-tnH", "state", "established", "( sport = :22 )"], timeout=5)
    return len([l for l in out.splitlines() if l.strip()]) if code == 0 else 0


def package_activity():
    code, out = run(["pgrep", "-l", "^(apt|apt-get|dpkg|unattended-upgr)$"], timeout=5)
    return code == 0 and bool(out.strip())


# ---------------------------------------------------------------------------
# Aktivität / Ruhezustand
# ---------------------------------------------------------------------------

class Activity:
    def __init__(self):
        self.last = time.time()
        self.busy = 0
        self.lock = threading.Lock()

    def touch(self):
        self.last = time.time()

    def __enter__(self):
        with self.lock:
            self.busy += 1
        self.touch()

    def __exit__(self, *a):
        with self.lock:
            self.busy -= 1
        self.touch()


ACTIVITY = Activity()


def sleep_blockers():
    reasons = []
    if ACTIVITY.busy > 0:
        reasons.append("KI antwortet")
    if JOB.running:
        reasons.append(JOB.name)
    if ssh_sessions() > 0:
        reasons.append("SSH-Verbindung offen")
    if package_activity():
        reasons.append("Paketverwaltung arbeitet")
    if not llama_binary() or not installed_models():
        reasons.append("KI noch nicht eingerichtet")
    return reasons


def sleep_thread():
    last_loop = time.time()
    while True:
        time.sleep(20)
        now = time.time()
        if now - last_loop > 90:
            # Großer Zeitsprung = wir haben geschlafen und sind wieder wach.
            log("Aufgewacht (nach ca. %d s Pause)" % (now - last_loop))
            ACTIVITY.touch()
            LLAMA.ensure_running()
            if ext_installed("vision"):
                VISION.ensure_running()
        last_loop = now
        if not CONFIG.get("sleep_enabled"):
            continue
        idle = now - ACTIVITY.last
        if idle < max(1, int(CONFIG.get("sleep_minutes", 5))) * 60:
            continue
        blockers = sleep_blockers()
        if blockers:
            ACTIVITY.touch()  # später erneut versuchen
            continue
        go_to_sleep("%d Minuten ohne Nutzung" % (idle // 60))
        last_loop = time.time()


def go_to_sleep(reason):
    log("Lege Mini-PC schlafen: " + reason)
    enable_wol()
    code, out = system_action(["systemctl", "suspend"])
    if code != 0:
        log("Ruhezustand fehlgeschlagen: " + out.strip()[:300])
    ACTIVITY.touch()


def enable_wol():
    iface = main_interface()
    if iface:
        system_action(["ethtool", "-s", iface, "wol", "g"])


# ---------------------------------------------------------------------------
# Hintergrund-Aufgaben (Downloads, Updates) mit Fortschritt in Prozent
# ---------------------------------------------------------------------------

class Job:
    def __init__(self):
        self.lock = threading.Lock()
        self.running = False
        self.name = ""
        self.percent = 0
        self.text = ""
        self.error = ""
        self.done_at = 0
        self._last_logged = -5

    def snapshot(self):
        return {
            "running": self.running, "name": self.name, "percent": self.percent,
            "text": self.text, "error": self.error, "done_at": self.done_at,
        }

    def progress(self, percent, text=None):
        self.percent = max(0, min(100, int(percent)))
        if text is not None:
            self.text = text
        # Ins Protokoll alle 5 %
        step = self.percent // 5 * 5
        if step >= self._last_logged + 5:
            self._last_logged = step
            bar = "#" * (step // 5) + "-" * (20 - step // 5)
            log("[%s] %3d %%  %s  %s" % (bar, step, self.name, self.text))

    def start(self, name, fn, *args):
        with self.lock:
            if self.running:
                return False
            self.running, self.name, self.percent = True, name, 0
            self.text, self.error, self._last_logged = "Startet …", "", -5
        threading.Thread(target=self._run, args=(fn, args), daemon=True).start()
        return True

    def _run(self, fn, args):
        try:
            fn(*args)
            self.progress(100, "Fertig")
        except Exception as e:  # noqa: BLE001 – alles anzeigen
            self.error = str(e)
            log("FEHLER bei %s: %s" % (self.name, e))
        finally:
            self.running = False
            self.done_at = time.time()
            ACTIVITY.touch()


JOB = Job()


def http_json(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def download(url, dest, on_progress):
    """Download mit Fortsetzen (.part) und Fortschritt 0..1."""
    part = dest + ".part"
    have = os.path.getsize(part) if os.path.exists(part) else 0
    headers = {"User-Agent": USER_AGENT}
    if have:
        headers["Range"] = "bytes=%d-" % have
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as r:
        if have and r.status != 206:
            have = 0  # Server kann nicht fortsetzen
        length = int(r.headers.get("Content-Length") or 0)
        total = have + length if length else 0
        mode = "ab" if have else "wb"
        done = have
        last = 0
        with open(part, mode) as f:
            while True:
                chunk = r.read(1024 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                ACTIVITY.touch()
                if total and time.time() - last > 0.5:
                    last = time.time()
                    on_progress(done / total, done, total)
    if total and os.path.getsize(part) < total:
        raise RuntimeError("Download unvollständig – bitte erneut starten (wird fortgesetzt)")
    os.replace(part, dest)
    on_progress(1.0, done, total or done)


def gb(n):
    return "%.1f GB" % (n / 1e9)


# --- KI-Laufzeit (llama.cpp) ---------------------------------------------

def llama_binary():
    cur = os.path.join(LLAMA_DIR, "current")
    for root, _dirs, files in os.walk(cur):
        if "llama-server" in files:
            return os.path.join(root, "llama-server")
    return None


def llama_version():
    return read_file(os.path.join(LLAMA_DIR, "current", ".version"), "")


def install_llama(p_from=0, p_to=100):
    backend = CONFIG.get("backend", "vulkan")
    want = "bin-ubuntu-vulkan-x64" if backend == "vulkan" else "bin-ubuntu-x64"
    JOB.progress(p_from, "Suche neueste KI-Laufzeit (llama.cpp, %s) …" % backend)
    rel = http_json("https://api.github.com/repos/ggml-org/llama.cpp/releases/latest")
    tag = rel.get("tag_name", "unbekannt")
    asset = None
    for a in rel.get("assets", []):
        n = a.get("name", "")
        if want in n and (n.endswith(".tar.gz") or n.endswith(".zip")):
            asset = a
            break
    if not asset:
        raise RuntimeError("Keine passende llama.cpp-Datei (%s) im Release %s gefunden" % (want, tag))
    os.makedirs(LLAMA_DIR, exist_ok=True)
    archive = os.path.join(LLAMA_DIR, asset["name"])
    span = p_to - p_from

    def prog(frac, done, total):
        JOB.progress(p_from + span * 0.9 * frac, "llama.cpp %s: %s / %s" % (tag, gb(done), gb(total)))

    download(asset["browser_download_url"], archive, prog)
    JOB.progress(p_from + span * 0.92, "Entpacke llama.cpp …")
    target = os.path.join(LLAMA_DIR, tag)
    if os.path.isdir(target):
        shutil.rmtree(target)
    os.makedirs(target)
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(target)
    else:
        with tarfile.open(archive) as t:
            try:
                t.extractall(target, filter="data")
            except TypeError:
                t.extractall(target)
    os.remove(archive)
    for root, _d, files in os.walk(target):
        for fn in files:
            if fn.startswith("llama-") or fn.endswith(".so") or ".so." in fn:
                fp = os.path.join(root, fn)
                os.chmod(fp, os.stat(fp).st_mode | 0o755)
    with open(os.path.join(target, ".version"), "w") as f:
        f.write(tag)
    cur = os.path.join(LLAMA_DIR, "current")
    tmp = cur + ".new"
    if os.path.lexists(tmp):
        os.remove(tmp)
    os.symlink(target, tmp)
    os.replace(tmp, cur)
    # alte Versionen aufräumen
    for d in os.listdir(LLAMA_DIR):
        p = os.path.join(LLAMA_DIR, d)
        if d not in (tag, "current") and os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p, ignore_errors=True)
    if not llama_binary():
        raise RuntimeError("llama-server wurde im Paket nicht gefunden")
    log("KI-Laufzeit installiert: llama.cpp %s (%s)" % (tag, backend))
    JOB.progress(p_to, "llama.cpp %s bereit" % tag)


# --- Modelle -----------------------------------------------------------------

def catalog_entry(mid):
    for m in CATALOG:
        if m["id"] == mid:
            return m
    return None


def find_hf_file(repo, pattern):
    info = http_json("https://huggingface.co/api/models/" + repo)
    names = [s.get("rfilename", "") for s in info.get("siblings", [])]
    cands = [n for n in names if n.lower().endswith(pattern.lower()) and "/" not in n]
    # "UD-"-Varianten (andere Quantisierung) nur, wenn nichts anderes passt
    plain = [n for n in cands if "UD-" not in n]
    pick = (plain or cands)
    if not pick:
        raise RuntimeError("Im Repo %s keine Datei *%s gefunden" % (repo, pattern))
    return sorted(pick, key=len)[0]


def download_model(mid, p_from=0, p_to=100, activate=False):
    m = catalog_entry(mid)
    if not m:
        raise RuntimeError("Unbekanntes Modell: " + mid)
    JOB.progress(p_from, "Suche %s auf Hugging Face …" % m["name"])
    fname = find_hf_file(m["repo"], m["pattern"])
    os.makedirs(MODEL_DIR, exist_ok=True)
    free = shutil.disk_usage(MODEL_DIR).free
    if free < m["size_gb"] * 1e9 * 1.05:
        raise RuntimeError("Zu wenig Platz auf der SSD (%s frei, %s nötig)" % (gb(free), "%.1f GB" % m["size_gb"]))
    url = "https://huggingface.co/%s/resolve/main/%s" % (m["repo"], fname)
    dest = os.path.join(MODEL_DIR, fname)
    span = p_to - p_from

    def prog(frac, done, total):
        JOB.progress(p_from + span * frac, "%s: %s / %s" % (m["name"], gb(done), gb(total)))

    if not os.path.exists(dest):
        download(url, dest, prog)
    with open(dest + ".json", "w", encoding="utf-8") as f:
        json.dump({"id": m["id"], "name": m["name"], "repo": m["repo"]}, f)
    log("Modell bereit: %s (%s)" % (m["name"], fname))
    if activate or not CONFIG.get("active_model"):
        CONFIG["active_model"] = fname
        save_config(CONFIG)
        LLAMA.restart()


def installed_models():
    out = []
    try:
        files = sorted(os.listdir(MODEL_DIR))
    except OSError:
        return out
    for fn in files:
        if not fn.endswith(".gguf"):
            continue
        meta = {}
        try:
            with open(os.path.join(MODEL_DIR, fn + ".json"), encoding="utf-8") as f:
                meta = json.load(f)
        except (OSError, ValueError):
            pass
        out.append({
            "file": fn,
            "id": meta.get("id", ""),
            "name": meta.get("name", fn),
            "size": os.path.getsize(os.path.join(MODEL_DIR, fn)),
            "active": fn == CONFIG.get("active_model"),
        })
    return out


def model_meta(fn):
    """Katalog-Eintrag zu einer installierten Modelldatei (oder {})."""
    try:
        with open(os.path.join(MODEL_DIR, fn + ".json"), encoding="utf-8") as f:
            return catalog_entry(json.load(f).get("id", "")) or {}
    except (OSError, ValueError):
        return {}


def wanted_setup():
    """Was im Installer ausgewählt wurde (models-wanted.json), sonst das Standardmodell."""
    try:
        with open(os.path.join(ETC_DIR, "models-wanted.json"), encoding="utf-8") as f:
            w = json.load(f)
    except (OSError, ValueError):
        w = {}
    models = [m for m in w.get("models", []) if catalog_entry(m)]
    if not models and not w.get("custom"):
        models = [next(m for m in CATALOG if m.get("default"))["id"]]
    return models, [u for u in w.get("custom", []) if parse_hf_url(u)], [e for e in w.get("extensions", []) if e in INSTALLERS]


def first_setup():
    """Ersteinrichtung: Laufzeit, gewählte Modelle (fehlende laden) und Erweiterungen."""
    if not llama_binary():
        install_llama(0, 8)
    models, custom, exts = wanted_setup()
    have = {m["id"] for m in installed_models()} | {m["file"] for m in installed_models()}
    todo = [m for m in models if m not in have] + [u for u in custom if os.path.basename(parse_hf_url(u)[2]) not in have]
    n = max(1, len(todo))
    for i, item in enumerate(todo):
        a, b = 8 + 80 * i / n, 8 + 80 * (i + 1) / n
        if item.startswith("https://"):
            download_custom(item)
        else:
            download_model(item, a, b, activate=(i == 0 and not CONFIG.get("active_model")))
    if not CONFIG.get("active_model") and installed_models():
        CONFIG["active_model"] = installed_models()[0]["file"]
        save_config(CONFIG)
    for e in exts:
        if not ext_installed(e):
            JOB.progress(90, "Erweiterung: " + e)
            try:
                INSTALLERS[e]()
            except Exception as ex:  # noqa: BLE001
                log("Erweiterung %s fehlgeschlagen: %s" % (e, ex))
    try:
        os.rename(os.path.join(ETC_DIR, "models-wanted.json"), os.path.join(ETC_DIR, "models-wanted.done.json"))
    except OSError:
        pass
    LLAMA.restart()


# ---------------------------------------------------------------------------
# llama-server steuern
# ---------------------------------------------------------------------------

class Llama:
    def __init__(self, port=LLAMA_PORT, kind="main"):
        self.port = port
        self.kind = kind
        self.proc = None
        self.lock = threading.Lock()
        self.model = ""
        self.crashes = 0
        self.last_tps = None
        self.state = "aus"

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def healthy(self):
        try:
            c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
            c.request("GET", "/health")
            r = c.getresponse()
            ok = r.status == 200
            c.close()
            return ok
        except OSError:
            return False

    def stop(self):
        with self.lock:
            if self.running():
                self.proc.terminate()
                try:
                    self.proc.wait(15)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            self.proc = None
            self.state = "aus"

    def start(self):
        with self.lock:
            if self.running():
                return
            binary = llama_binary()
            threads = int(CONFIG.get("threads") or 0) or max(1, (os.cpu_count() or 2) // 2)
            if self.kind == "vision":
                files = vision_files()
                if not binary or not files:
                    self.state = "nicht eingerichtet"
                    return
                model, path = os.path.basename(files[0]), files[0]
                extra = ["--mmproj", files[1], "-c", "8192"]
            else:
                model = CONFIG.get("active_model")
                path = os.path.join(MODEL_DIR, model) if model else ""
                if not binary or not model or not os.path.exists(path):
                    self.state = "nicht eingerichtet"
                    return
                extra = ["-c", str(int(CONFIG.get("ctx", 16384)))]
            cmd = [
                binary, "-m", path,
                "--host", "127.0.0.1", "--port", str(self.port),
                "-t", str(threads),
                "-ngl", str(int(CONFIG.get("gpu_layers", 0))),
                "--jinja",
            ] + extra
            env = dict(os.environ)
            env["LD_LIBRARY_PATH"] = os.path.dirname(binary) + ":" + env.get("LD_LIBRARY_PATH", "")
            logf = open(os.path.join(DATA_DIR, "llama-%s.log" % ("server" if self.kind == "main" else self.kind)), "ab")
            log("Starte %s mit %s (%d Threads, GPU-Schichten %s)" % (
                "KI-Laufzeit" if self.kind == "main" else "Bild-KI", model, threads, CONFIG.get("gpu_layers", 0)))
            self.proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, env=env)
            self.model = model
            self.state = "lädt"
            self.started = time.time()

    def restart(self):
        self.stop()
        self.crashes = 0
        self.start()

    def ensure_running(self):
        if not self.running():
            self.start()

    def watch(self):
        while True:
            time.sleep(3)
            if self.proc is None:
                continue
            if self.proc.poll() is not None:
                code = self.proc.returncode
                self.proc = None
                self.crashes += 1
                self.state = "abgestürzt"
                log("KI-Laufzeit beendet (Code %s). Letzte Zeilen in llama-server.log" % code)
                if self.crashes >= 3:
                    log("KI-Laufzeit stürzt wiederholt ab – Tipp: unter Einstellungen 'Prozessor (CPU)' als Laufzeit wählen.")
                    continue
                time.sleep(5)
                self.start()
            elif self.state == "lädt" and self.healthy():
                self.state = "bereit"
                log("KI-Laufzeit bereit: " + self.model)


LLAMA = Llama()
VISION = Llama(port=8082, kind="vision")


# ---------------------------------------------------------------------------
# Updates
# ---------------------------------------------------------------------------

def apt_upgradable():
    code, out = run(["apt", "list", "--upgradable"], timeout=60)
    if code != 0:
        return None
    return len([l for l in out.splitlines() if "/" in l and "upgradable" in l])


def run_streaming(cmd, on_line):
    if DRYRUN:
        log("[Testmodus] würde ausführen: " + " ".join(cmd))
        for i in range(5):
            on_line("Test-Ausgabe %d" % i)
            time.sleep(0.2)
        return 0
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    for line in p.stdout:
        on_line(line.rstrip())
    return p.wait()


def update_all(include_llama):
    JOB.progress(2, "Paketlisten laden (apt update) …")
    run_streaming(["apt-get", "update"], lambda l: None)
    JOB.progress(15, "Updates einspielen …")
    total = max(1, apt_upgradable() or 1)
    seen = [0]

    def on_line(line):
        if line.startswith(("Setting up", "Entpacken", "Unpacking", "Einrichten")):
            seen[0] += 1
            JOB.progress(15 + 60 * min(1, seen[0] / (total * 2)), line[:80])

    code = run_streaming(["apt-get", "-y", "-o", "Dpkg::Options::=--force-confdef",
                          "-o", "Dpkg::Options::=--force-confold", "full-upgrade"], on_line)
    if code != 0:
        raise RuntimeError("apt full-upgrade meldet Fehlercode %d (siehe Protokoll)" % code)
    run_streaming(["apt-get", "-y", "autoremove"], lambda l: None)
    if include_llama:
        LLAMA.stop()
        try:
            install_llama(78, 98)
        finally:
            LLAMA.restart()
    if os.path.exists("/var/run/reboot-required"):
        log("Hinweis: Für einige Updates ist ein Neustart nötig.")



# ---------------------------------------------------------------------------
# Erweiterungen (zusätzliche KIs)
# ---------------------------------------------------------------------------

EXT_DIR = os.path.join(DATA_DIR, "ext")
IMAGE_DIR = os.path.join(DATA_DIR, "images")

EXTENSIONS = [
    {"id": "vision", "name": "Bilder verstehen",
     "desc": "Screenshots, Fehlermeldungen und Fotos erklären lassen (Qwen2.5-VL 7B). Im Chat erscheint dann „Bild anhängen“.",
     "size_gb": 6.1, "speed": "gut"},
    {"id": "stt", "name": "Sprache → Text",
     "desc": "Diktieren statt tippen (Whisper, Deutsch). Wird auf dem Mini-PC gebaut. Mikrofon im Butchies-KI-Fenster der Taskleiste.",
     "size_gb": 0.6, "speed": "gut"},
    {"id": "tts", "name": "Text → Sprache",
     "desc": "Antworten vorlesen lassen (Piper, deutsche Stimme „Thorsten“).",
     "size_gb": 0.1, "speed": "gut"},
    {"id": "images", "name": "Bilder erzeugen",
     "desc": "Bilder aus Text erzeugen (Stable Diffusion Turbo, 512×512). Auf dem Mini-PC langsam – grob eine halbe bis mehrere Minuten pro Bild.",
     "size_gb": 5.3, "speed": "langsam"},
    {"id": "video", "name": "Videos erzeugen",
     "desc": "Kommt später. Ohne starke Grafikkarte würde ein kurzer Clip Stunden dauern.",
     "size_gb": 0, "speed": "coming_soon"},
]


def ext_path(eid, *parts):
    return os.path.join(EXT_DIR, eid, *parts)


def ext_installed(eid):
    return os.path.exists(ext_path(eid, "installed.json"))


def ext_mark(eid, info):
    with open(ext_path(eid, "installed.json"), "w", encoding="utf-8") as f:
        json.dump(dict(info, at=time.strftime("%Y-%m-%d %H:%M")), f)


def vision_files():
    try:
        with open(ext_path("vision", "installed.json"), encoding="utf-8") as f:
            info = json.load(f)
        m, p = ext_path("vision", info["model"]), ext_path("vision", info["mmproj"])
        return (m, p) if os.path.exists(m) and os.path.exists(p) else None
    except (OSError, ValueError, KeyError):
        return None


def hf_files(repo):
    info = http_json("https://huggingface.co/api/models/" + repo)
    return [s.get("rfilename", "") for s in info.get("siblings", [])]


def hf_download(repo, fname, dest_dir, p_from, p_to, label):
    dest = os.path.join(dest_dir, os.path.basename(fname))
    if os.path.exists(dest):
        return dest
    url = "https://huggingface.co/%s/resolve/main/%s" % (repo, fname)

    def prog(frac, done, total):
        JOB.progress(p_from + (p_to - p_from) * frac, "%s: %s / %s" % (label, gb(done), gb(total)))

    download(url, dest, prog)
    return dest


def github_asset(repo, want):
    """Neuestes Release-Asset, dessen Name alle Teile aus want enthält (want: Liste von Listen = Alternativen)."""
    rel = http_json("https://api.github.com/repos/%s/releases/latest" % repo)
    names = [(a.get("name", ""), a.get("browser_download_url")) for a in rel.get("assets", [])]
    for parts in want:
        for n, u in names:
            if all(p(n) if callable(p) else p in n for p in parts):
                return rel.get("tag_name", ""), n, u
    return rel.get("tag_name", ""), None, None


def extract(archive, target):
    os.makedirs(target, exist_ok=True)
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(target)
    else:
        with tarfile.open(archive) as t:
            try:
                t.extractall(target, filter="data")
            except TypeError:
                t.extractall(target)
    os.remove(archive)
    for root, _d, files in os.walk(target):
        for fn in files:
            fp = os.path.join(root, fn)
            if "." not in fn or fn.endswith(".so") or ".so." in fn or fn.startswith(("sd", "piper", "whisper", "espeak")):
                try:
                    os.chmod(fp, os.stat(fp).st_mode | 0o755)
                except OSError:
                    pass


def find_file(base, names):
    for root, _d, files in os.walk(base):
        for n in names:
            if n in files:
                return os.path.join(root, n)
    return None


def apt_install(pkgs, p_from, p_to):
    JOB.progress(p_from, "Installiere Werkzeuge: " + ", ".join(pkgs))
    run_streaming(["apt-get", "update"], lambda l: None)
    code = run_streaming(["apt-get", "install", "-y"] + pkgs, lambda l: None)
    if code != 0:
        raise RuntimeError("apt-get install meldet Fehlercode %d" % code)
    JOB.progress(p_to)


def install_vision():
    d = ext_path("vision")
    os.makedirs(d, exist_ok=True)
    repo = "ggml-org/Qwen2.5-VL-7B-Instruct-GGUF"
    JOB.progress(1, "Suche Bild-KI auf Hugging Face …")
    files = [f for f in hf_files(repo) if "/" not in f and f.endswith(".gguf")]
    model = next((f for f in files if f.endswith("Q4_K_M.gguf") and not f.startswith("mmproj")), None)
    projs = [f for f in files if f.startswith("mmproj")]
    proj = next((f for f in projs if "f16" in f.lower()), projs[0] if projs else None)
    if not model or not proj:
        raise RuntimeError("Bild-KI-Dateien im Repo %s nicht gefunden" % repo)
    hf_download(repo, model, d, 2, 80, "Bild-KI")
    hf_download(repo, proj, d, 80, 98, "Bild-Encoder")
    ext_mark("vision", {"model": model, "mmproj": proj})
    VISION.restart()


def install_stt():
    d = ext_path("stt")
    os.makedirs(d, exist_ok=True)
    apt_install(["build-essential", "cmake", "git", "ffmpeg"], 1, 15)
    src = ext_path("stt", "whisper.cpp")
    if os.path.isdir(src):
        shutil.rmtree(src)
    JOB.progress(16, "Lade whisper.cpp-Quelltext …")
    if run_streaming(["git", "clone", "--depth", "1", "https://github.com/ggml-org/whisper.cpp", src], lambda l: None) != 0:
        raise RuntimeError("git clone whisper.cpp fehlgeschlagen")
    JOB.progress(20, "Baue whisper.cpp (dauert einige Minuten) …")
    if run_streaming(["cmake", "-S", src, "-B", os.path.join(src, "build"), "-DCMAKE_BUILD_TYPE=Release"], lambda l: None) != 0:
        raise RuntimeError("cmake (whisper.cpp) fehlgeschlagen")

    def on_line(line):
        m = re.search(r"\[\s*(\d+)%\]", line)
        if m:
            JOB.progress(20 + 55 * int(m.group(1)) / 100, "Baue whisper.cpp … %s %%" % m.group(1))

    if run_streaming(["cmake", "--build", os.path.join(src, "build"), "-j", str(os.cpu_count() or 4),
                      "--config", "Release", "--target", "whisper-cli"], on_line) != 0:
        raise RuntimeError("Bauen von whisper.cpp fehlgeschlagen")
    if not find_file(os.path.join(src, "build"), ["whisper-cli"]):
        raise RuntimeError("whisper-cli wurde nicht gebaut")
    hf_download("ggerganov/whisper.cpp", "ggml-small.bin", d, 76, 99, "Whisper-Modell")
    ext_mark("stt", {"model": "ggml-small.bin"})


def install_tts():
    d = ext_path("tts")
    os.makedirs(d, exist_ok=True)
    JOB.progress(2, "Lade Piper (Sprachausgabe) …")
    url = "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz"
    arch = os.path.join(d, "piper.tar.gz")
    download(url, arch, lambda f, a, b: JOB.progress(2 + 40 * f, "Piper: %s / %s" % (gb(a), gb(b))))
    extract(arch, d)
    if not find_file(d, ["piper"]):
        raise RuntimeError("Piper-Programm nicht gefunden")
    repo, base = "rhasspy/piper-voices", "de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx"
    hf_download(repo, base, d, 45, 95, "Stimme Thorsten")
    hf_download(repo, base + ".json", d, 95, 99, "Stimme Thorsten (Einstellungen)")
    ext_mark("tts", {"voice": "de_DE-thorsten-medium.onnx"})


def install_images():
    d = ext_path("images")
    os.makedirs(d, exist_ok=True)
    JOB.progress(1, "Suche stable-diffusion.cpp …")
    notv = lambda n: "vulkan" not in n and "rocm" not in n and "cuda" not in n  # noqa: E731
    tag, name, url = github_asset("leejet/stable-diffusion.cpp", [
        ["Linux", "x86_64", ".zip", notv], ["Linux", "x86_64", notv], ["Linux", "x86_64"]])
    if not url:
        raise RuntimeError("Kein Linux-Programm im neuesten stable-diffusion.cpp-Release (%s)" % tag)
    arch = os.path.join(d, name)
    download(url, arch, lambda f, a, b: JOB.progress(1 + 9 * f, "stable-diffusion.cpp: %s / %s" % (gb(a), gb(b))))
    extract(arch, os.path.join(d, "bin"))
    if not find_file(os.path.join(d, "bin"), ["sd-cli", "sd"]):
        raise RuntimeError("sd-Programm im Paket nicht gefunden")
    JOB.progress(11, "Suche Bildmodell (SD Turbo) …")
    files = [f for f in hf_files("stabilityai/sd-turbo") if f.endswith(".safetensors") and "/" not in f]
    pick = next((f for f in files if "fp16" in f), None) or next((f for f in files if "sd_turbo" in f), None)
    if not pick:
        raise RuntimeError("SD-Turbo-Modell nicht gefunden")
    hf_download("stabilityai/sd-turbo", pick, d, 12, 99, "Bildmodell")
    ext_mark("images", {"model": pick, "sd": tag})


INSTALLERS = {"vision": install_vision, "stt": install_stt, "tts": install_tts, "images": install_images}


def uninstall_ext(eid):
    if eid == "vision":
        VISION.stop()
    shutil.rmtree(ext_path(eid), ignore_errors=True)
    log("Erweiterung entfernt: " + eid)


def ext_list():
    out = []
    for e in EXTENSIONS:
        x = dict(e)
        x["installed"] = ext_installed(e["id"])
        if e["id"] == "vision":
            x["state"] = VISION.state
        out.append(x)
    return out


def speech_to_text(audio_bytes):
    d = ext_path("stt")
    cli = find_file(ext_path("stt", "whisper.cpp", "build"), ["whisper-cli"])
    if not cli:
        raise RuntimeError("Sprache → Text ist nicht installiert")
    tmp = os.path.join(d, "in-%d" % time.time())
    wav = tmp + ".wav"
    with open(tmp, "wb") as f:
        f.write(audio_bytes)
    try:
        code, out = run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-ar", "16000", "-ac", "1", wav], timeout=120)
        if code != 0:
            raise RuntimeError("Audio konnte nicht umgewandelt werden: " + out[:200])
        threads = str(max(1, (os.cpu_count() or 2) // 2))
        p = subprocess.run([cli, "-m", os.path.join(d, "ggml-small.bin"), "-f", wav, "-l", "de", "-nt", "-np", "-t", threads],
                           capture_output=True, text=True, timeout=600)
        if p.returncode != 0:
            raise RuntimeError("Whisper-Fehler: " + (p.stderr or "")[-300:])
        return " ".join(l.strip() for l in p.stdout.splitlines() if l.strip()).strip()
    finally:
        for p in (tmp, wav):
            if os.path.exists(p):
                os.remove(p)


def text_to_speech(text):
    d = ext_path("tts")
    piper = find_file(d, ["piper"])
    voice = find_file(d, ["de_DE-thorsten-medium.onnx"])
    if not piper or not voice:
        raise RuntimeError("Text → Sprache ist nicht installiert")
    out = os.path.join(d, "out-%d.wav" % time.time())
    clean = re.sub(r"```.*?```", " (Code siehe Bildschirm) ", text, flags=re.S)
    clean = re.sub(r"[*#`_>|]", " ", clean)[:4000]
    env = dict(os.environ, LD_LIBRARY_PATH=os.path.dirname(piper))
    p = subprocess.run([piper, "--model", voice, "--output_file", out], input=clean, text=True,
                       capture_output=True, timeout=300, env=env)
    if p.returncode != 0 or not os.path.exists(out):
        raise RuntimeError("Piper-Fehler: " + (p.stderr or "")[-300:])
    with open(out, "rb") as f:
        data = f.read()
    os.remove(out)
    return data


def generate_image(prompt, steps):
    d = ext_path("images")
    sd = find_file(os.path.join(d, "bin"), ["sd-cli", "sd"])
    try:
        with open(ext_path("images", "installed.json"), encoding="utf-8") as f:
            model = os.path.join(d, json.load(f)["model"])
    except (OSError, ValueError, KeyError):
        model = ""
    if not sd or not os.path.exists(model):
        raise RuntimeError("Bilder erzeugen ist nicht installiert")
    os.makedirs(IMAGE_DIR, exist_ok=True)
    name = time.strftime("bild-%Y%m%d-%H%M%S.png")
    out = os.path.join(IMAGE_DIR, name)
    threads = str(max(1, (os.cpu_count() or 2) // 2))
    JOB.progress(3, "Lade Bildmodell …")
    stage = {"p": 3}

    def on_line(line):
        low = line.lower()
        m = re.search(r"(\d+)/(\d+)", line)
        if "sampling" in low or (m and "it" in low):
            if m and int(m.group(2)) > 0:
                stage["p"] = max(stage["p"], 30 + 55 * int(m.group(1)) / int(m.group(2)))
            else:
                stage["p"] = max(stage["p"], 30)
            JOB.progress(stage["p"], "Bild wird gemalt …")
        elif "decod" in low:
            JOB.progress(max(stage["p"], 88), "Bild wird fertiggestellt …")
        elif "load" in low:
            JOB.progress(max(stage["p"], 10), "Lade Bildmodell …")

    env = dict(os.environ, LD_LIBRARY_PATH=os.path.dirname(sd))
    p = subprocess.Popen([sd, "-m", model, "-p", prompt, "-W", "512", "-H", "512", "--steps", str(steps),
                          "--cfg-scale", "1.0", "-t", threads, "-o", out],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    buf = ""
    while True:
        ch = p.stdout.read(1)
        if not ch:
            break
        if ch in "\r\n":
            if buf:
                on_line(buf)
            buf = ""
        else:
            buf += ch
        ACTIVITY.touch()
    if p.wait() != 0 or not os.path.exists(out):
        raise RuntimeError("Bild konnte nicht erzeugt werden (Protokoll prüfen)")
    with open(out + ".json", "w", encoding="utf-8") as f:
        json.dump({"prompt": prompt, "steps": steps}, f, ensure_ascii=False)
    log("Bild erzeugt: " + name)


def image_list():
    try:
        files = sorted((f for f in os.listdir(IMAGE_DIR) if f.endswith(".png")), reverse=True)
    except OSError:
        return []
    out = []
    for f in files[:200]:
        meta = {}
        try:
            with open(os.path.join(IMAGE_DIR, f + ".json"), encoding="utf-8") as h:
                meta = json.load(h)
        except (OSError, ValueError):
            pass
        out.append({"file": f, "prompt": meta.get("prompt", "")})
    return out


# ---------------------------------------------------------------------------
# Eigene Modelle (Hugging-Face-Link)
# ---------------------------------------------------------------------------

def parse_hf_url(url):
    m = re.match(r"^https://huggingface\.co/([\w.\-]+/[\w.\-]+)/(?:resolve|blob)/([\w.\-]+)/(.+\.gguf)(?:\?.*)?$", url.strip())
    if not m:
        return None
    return m.group(1), m.group(2), m.group(3)


def download_custom(url):
    repo, rev, path = parse_hf_url(url)
    fname = os.path.basename(path)
    dest = os.path.join(MODEL_DIR, fname)
    real = "https://huggingface.co/%s/resolve/%s/%s" % (repo, rev, path)
    JOB.progress(1, "Lade " + fname)
    download(real, dest, lambda f, a, b: JOB.progress(1 + 98 * f, "%s: %s / %s" % (fname, gb(a), gb(b))))
    with open(dest + ".json", "w", encoding="utf-8") as f:
        json.dump({"id": "custom", "name": fname.replace(".gguf", ""), "repo": repo}, f)
    log("Eigenes Modell geladen: " + fname)


# ---------------------------------------------------------------------------
# Update-Prüfung und Selbst-Update über GitHub
# ---------------------------------------------------------------------------

UPDATE_INFO = {"checked": 0, "llama_latest": "", "app_latest": "", "error": ""}


def github_headers(raw=False):
    h = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json"}
    tok = CONFIG.get("github_token")
    if tok:
        h["Authorization"] = "Bearer " + tok
    return h


CATALOG_CACHE = os.path.join(DATA_DIR, "modelle.json")


def apply_catalog(data):
    models = [m for m in data.get("models", []) if m.get("id") and m.get("repo") and m.get("pattern")]
    if models:
        CATALOG[:] = models
    exts = {e["id"]: e for e in data.get("extensions", []) if e.get("id")}
    for e in EXTENSIONS:
        if e["id"] in exts:
            e.update({k: v for k, v in exts[e["id"]].items() if k in ("size_gb", "desc")})


def load_catalog_cache():
    try:
        with open(CATALOG_CACHE, encoding="utf-8") as f:
            apply_catalog(json.load(f))
    except (OSError, ValueError):
        pass


def refresh_catalog():
    repo = CONFIG.get("update_repo") or "Butchies/Butchies-ki-studio"
    req = urllib.request.Request("https://api.github.com/repos/%s/contents/modelle.json" % repo, headers=github_headers(True))
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.loads(r.read().decode("utf-8"))
    apply_catalog(data)
    with open(CATALOG_CACHE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    log("Modell-Katalog aktualisiert (%d Modelle)" % len(CATALOG))


def check_updates():
    err = []
    try:
        refresh_catalog()
    except Exception as e:  # noqa: BLE001
        err.append("Modell-Katalog: %s" % e)
    try:
        UPDATE_INFO["llama_latest"] = http_json("https://api.github.com/repos/ggml-org/llama.cpp/releases/latest").get("tag_name", "")
    except Exception as e:  # noqa: BLE001
        err.append("llama.cpp: %s" % e)
    repo = CONFIG.get("update_repo") or "Butchies/Butchies-ki-studio"
    try:
        req = urllib.request.Request("https://api.github.com/repos/%s/contents/VERSION" % repo, headers=github_headers(True))
        with urllib.request.urlopen(req, timeout=20) as r:
            UPDATE_INFO["app_latest"] = r.read().decode().strip()
    except Exception as e:  # noqa: BLE001
        err.append("Butchies KI Studio (%s): %s" % (repo, e))
    UPDATE_INFO["checked"] = time.time()
    UPDATE_INFO["error"] = "; ".join(err)
    log("Update-Prüfung: llama.cpp %s (installiert %s), Butchies %s (installiert %s)%s" % (
        UPDATE_INFO["llama_latest"] or "?", llama_version() or "-", UPDATE_INFO["app_latest"] or "?", VERSION,
        (" – " + UPDATE_INFO["error"]) if err else ""))


def version_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or "0"))


def updates_available():
    out = []
    if UPDATE_INFO["llama_latest"] and llama_version() and UPDATE_INFO["llama_latest"] != llama_version():
        out.append("KI-Laufzeit")
    if UPDATE_INFO["app_latest"] and version_tuple(UPDATE_INFO["app_latest"]) > version_tuple(VERSION):
        out.append("Butchies KI Studio " + UPDATE_INFO["app_latest"])
    return out


def update_check_thread():
    time.sleep(20)
    while True:
        try:
            check_updates()
        except Exception as e:  # noqa: BLE001
            log("Update-Prüfung fehlgeschlagen: %s" % e)
        time.sleep(24 * 3600)


def update_app():
    repo = CONFIG.get("update_repo") or "Butchies/Butchies-ki-studio"
    JOB.progress(2, "Lade Butchies KI Studio von GitHub (%s) …" % repo)
    tmp = os.path.join(DATA_DIR, "app-update")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    arch = os.path.join(tmp, "app.zip")
    req = urllib.request.Request("https://api.github.com/repos/%s/zipball/main" % repo, headers=github_headers())
    with urllib.request.urlopen(req, timeout=120) as r, open(arch, "wb") as f:
        shutil.copyfileobj(r, f)
    JOB.progress(40, "Entpacke …")
    with zipfile.ZipFile(arch) as z:
        z.extractall(tmp)
    srv = None
    for root, dirs, files in os.walk(tmp):
        if os.path.basename(root) == "server" and "server.py" in files:
            srv = root
            break
    if not srv:
        raise RuntimeError("Im GitHub-Paket fehlt der Ordner server/")
    code, out = run(["python3", "-m", "py_compile", os.path.join(srv, "server.py")])
    if code != 0:
        raise RuntimeError("Neue Version ist fehlerhaft, Update abgebrochen: " + out[:300])
    JOB.progress(70, "Sichere aktuelle Version …")
    bak = APP_DIR.rstrip("/") + ".bak"
    new = APP_DIR.rstrip("/") + ".new"
    shutil.rmtree(new, ignore_errors=True)
    shutil.copytree(srv, new)
    if DRYRUN:
        log("[Testmodus] würde %s durch neue Version ersetzen" % APP_DIR)
        shutil.rmtree(new, ignore_errors=True)
        return
    shutil.rmtree(bak, ignore_errors=True)
    shutil.copytree(APP_DIR, bak)
    for unit in os.listdir(os.path.join(new, "systemd")) if os.path.isdir(os.path.join(new, "systemd")) else []:
        shutil.copy(os.path.join(new, "systemd", unit), "/etc/systemd/system/" + unit)
    shutil.rmtree(APP_DIR)
    os.rename(new, APP_DIR)
    shutil.rmtree(tmp, ignore_errors=True)
    JOB.progress(95, "Starte neu …")
    log("Butchies KI Studio aktualisiert – Neustart des Dienstes")
    threading.Thread(target=lambda: (time.sleep(3), run(["systemctl", "daemon-reload"]),
                                     run(["systemctl", "restart", "butchies-ki"])), daemon=True).start()


def rollback_app():
    bak = APP_DIR.rstrip("/") + ".bak"
    if not os.path.isdir(bak):
        raise RuntimeError("Keine Sicherung vorhanden")
    if DRYRUN:
        log("[Testmodus] würde auf Sicherung zurückgehen")
        return
    old = APP_DIR.rstrip("/") + ".old"
    shutil.rmtree(old, ignore_errors=True)
    os.rename(APP_DIR, old)
    os.rename(bak, APP_DIR)
    shutil.rmtree(old, ignore_errors=True)
    log("Auf vorherige Version zurückgesetzt – Neustart des Dienstes")
    threading.Thread(target=lambda: (time.sleep(3), run(["systemctl", "restart", "butchies-ki"])), daemon=True).start()


# ---------------------------------------------------------------------------
# HTTP-Server
# ---------------------------------------------------------------------------

SESSIONS = {}
SESSION_TTL = 30 * 24 * 3600

STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
}


class Handler(BaseHTTPRequestHandler):
    server_version = "ButchiesKI/" + VERSION

    def log_message(self, fmt, *args):  # Zugriffslog nicht ins Protokoll
        pass

    # --- Antworten ---------------------------------------------------------
    def send_json(self, obj, status=200, extra_headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def error(self, msg, status=400):
        self.send_json({"ok": False, "error": msg}, status)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > 30_000_000:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except ValueError:
            return {}

    # --- Anmeldung -------------------------------------------------------
    def session(self):
        cookie = self.headers.get("Cookie", "")
        m = re.search(r"(?:^|;\s*)bki=([A-Za-z0-9_\-]+)", cookie)
        if not m:
            return None
        tok = m.group(1)
        exp = SESSIONS.get(tok)
        if exp and exp > time.time():
            return tok
        SESSIONS.pop(tok, None)
        return None

    def new_session_header(self):
        tok = secrets.token_urlsafe(32)
        SESSIONS[tok] = time.time() + SESSION_TTL
        return {"Set-Cookie": "bki=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Strict" % (tok, SESSION_TTL)}

    # --- GET ---------------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in STATIC:
            fn, ctype = STATIC[path]
            try:
                with open(os.path.join(WEB_DIR, fn), "rb") as f:
                    data = f.read()
            except OSError:
                return self.error("Datei fehlt", 404)
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(data)
            return

        if path == "/api/ping":
            return self.send_json({"ok": True, "name": "Butchies KI Studio", "version": VERSION},
                                  extra_headers={"Access-Control-Allow-Origin": "*"})
        if path == "/api/wol":
            iface = main_interface()
            mac = read_file("/sys/class/net/%s/address" % iface) if iface else ""
            return self.send_json({"ok": True, "mac": mac, "ip": ip_address(), "host": socket.gethostname()},
                                  extra_headers={"Access-Control-Allow-Origin": "*"})
        if path == "/api/state":
            return self.send_json({
                "ok": True, "version": VERSION,
                "needs_password": not CONFIG.get("ui_password"),
                "logged_in": bool(self.session()),
                "job": JOB.snapshot(),
            })

        if not self.session():
            return self.error("Bitte anmelden", 401)

        if path == "/api/status":
            total, avail = meminfo()
            du = shutil.disk_usage("/")
            iface = main_interface()
            return self.send_json({
                "ok": True,
                "host": socket.gethostname(),
                "cpu_name": cpu_name(),
                "cpu": cpu_percent(),
                "temp": cpu_temp(),
                "mem_total": total, "mem_used": total - avail,
                "disk_total": du.total, "disk_used": du.used,
                "uptime": float(read_file("/proc/uptime", "0").split()[0] or 0),
                "ip": ip_address(),
                "mac": read_file("/sys/class/net/%s/address" % iface) if iface else "",
                "llama": {"state": LLAMA.state, "model": LLAMA.model, "version": llama_version(),
                          "tps": LLAMA.last_tps},
                "job": JOB.snapshot(),
                "idle_seconds": int(time.time() - ACTIVITY.last),
                "sleep_enabled": bool(CONFIG.get("sleep_enabled")),
                "sleep_minutes": int(CONFIG.get("sleep_minutes", 5)),
                "sleep_blockers": sleep_blockers(),
                "reboot_required": os.path.exists("/var/run/reboot-required"),
                "version": VERSION,
                "updates_available": updates_available(),
                "ext": {e["id"]: ext_installed(e["id"]) for e in EXTENSIONS},
                "vision": VISION.state,
            })
        if path == "/api/models":
            return self.send_json({"ok": True, "catalog": CATALOG, "installed": installed_models(),
                                   "free": shutil.disk_usage(DATA_DIR if os.path.isdir(DATA_DIR) else "/").free})
        if path == "/api/settings":
            cfg = {k: v for k, v in CONFIG.items() if k not in ("ui_password", "github_token")}
            cfg["github_token_set"] = bool(CONFIG.get("github_token"))
            return self.send_json({"ok": True, "settings": cfg})
        if path == "/api/updates":
            return self.send_json({"ok": True, "apt": apt_upgradable(), "llama": llama_version(),
                                   "llama_latest": UPDATE_INFO["llama_latest"], "app": VERSION,
                                   "app_latest": UPDATE_INFO["app_latest"], "checked": UPDATE_INFO["checked"],
                                   "check_error": UPDATE_INFO["error"],
                                   "rollback": os.path.isdir(APP_DIR.rstrip("/") + ".bak"),
                                   "repo": CONFIG.get("update_repo") or "Butchies/Butchies-ki-studio",
                                   "reboot_required": os.path.exists("/var/run/reboot-required")})
        if path == "/api/ext":
            return self.send_json({"ok": True, "ext": ext_list()})
        if path == "/api/images":
            return self.send_json({"ok": True, "images": image_list()})
        if path.startswith("/api/images/file/"):
            fn = os.path.basename(path.rsplit("/", 1)[1])
            fp = os.path.join(IMAGE_DIR, fn)
            if not fn.endswith(".png") or not os.path.exists(fp):
                return self.error("Bild nicht gefunden", 404)
            with open(fp, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/api/logs":
            with _log_lock:
                lines = list(_log_buffer)[-300:]
            tail = ""
            try:
                with open(os.path.join(DATA_DIR, "llama-server.log"), "rb") as f:
                    f.seek(0, 2)
                    size = f.tell()
                    f.seek(max(0, size - 6000))
                    tail = f.read().decode("utf-8", "replace")
            except OSError:
                pass
            return self.send_json({"ok": True, "app": lines, "llama": tail})
        return self.error("Nicht gefunden", 404)

    # --- POST --------------------------------------------------------------
    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/stt":
            return self.stt()
        data = self.body()

        if path == "/api/setup":
            pw = str(data.get("password", ""))
            if error := password_error(pw):
                return self.error(error)
            with _password_lock:
                if CONFIG.get("ui_password"):
                    return self.error("Passwort ist schon gesetzt", 403)
                set_ui_password(pw)
            log("Passwort für die Oberfläche festgelegt")
            return self.send_json({"ok": True}, extra_headers=self.new_session_header())
        if path == "/api/login/reset":
            pw = str(data.get("password", ""))
            if error := password_error(pw):
                return self.error(error)
            digest = hashlib.sha256(str(data.get("code", "")).encode()).hexdigest()
            with _password_lock:
                try:
                    with open(RECOVERY_PATH, encoding="utf-8") as f:
                        recovery = json.load(f)
                except (OSError, ValueError):
                    recovery = {}
                if (data.get("pin") != "0000" or time.time() >= recovery.get("expires", 0)
                        or not hmac.compare_digest(digest, recovery.get("hash", ""))):
                    return self.error("Einmalcode oder Rücksetz-PIN ungültig", 403)
                os.unlink(RECOVERY_PATH)
                set_ui_password(pw)
                SESSIONS.clear()
                headers = self.new_session_header()
            return self.send_json({"ok": True}, extra_headers=headers)
        if path == "/api/login":
            time.sleep(0.5)  # bremst Raten
            with _password_lock:
                if not check_password(str(data.get("password", ""))):
                    return self.error("Falsches Passwort", 401)
                headers = self.new_session_header()
            ACTIVITY.touch()
            return self.send_json({"ok": True}, extra_headers=headers)

        tok = self.session()
        if not tok:
            return self.error("Bitte anmelden", 401)
        ACTIVITY.touch()

        if path == "/api/logout":
            SESSIONS.pop(tok, None)
            return self.send_json({"ok": True})
        if path == "/api/activity":
            return self.send_json({"ok": True})
        if path == "/api/chat":
            return self.chat(data)
        if path == "/api/models/download":
            mid = str(data.get("id", ""))
            if not catalog_entry(mid):
                return self.error("Unbekanntes Modell")
            m = catalog_entry(mid)
            ok = JOB.start("Modell laden: " + m["name"], download_model, mid, 0, 100, bool(data.get("activate")))
            return self.send_json({"ok": ok, "error": "" if ok else "Es läuft schon eine Aufgabe"})
        if path == "/api/models/activate":
            fn = os.path.basename(str(data.get("file", "")))
            if not os.path.exists(os.path.join(MODEL_DIR, fn)):
                return self.error("Modell nicht gefunden")
            CONFIG["active_model"] = fn
            save_config(CONFIG)
            threading.Thread(target=LLAMA.restart, daemon=True).start()
            log("Aktives Modell gewechselt: " + fn)
            return self.send_json({"ok": True})
        if path == "/api/models/delete":
            fn = os.path.basename(str(data.get("file", "")))
            if fn == CONFIG.get("active_model"):
                return self.error("Das aktive Modell kann nicht gelöscht werden")
            p = os.path.join(MODEL_DIR, fn)
            if not fn.endswith(".gguf") or not os.path.exists(p):
                return self.error("Modell nicht gefunden")
            os.remove(p)
            if os.path.exists(p + ".json"):
                os.remove(p + ".json")
            log("Modell gelöscht: " + fn)
            return self.send_json({"ok": True})
        if path == "/api/settings":
            changed_llama = False
            for key, typ, lo, hi in (("sleep_minutes", int, 1, 240), ("ctx", int, 2048, 131072),
                                     ("gpu_layers", int, 0, 999), ("threads", int, 0, 64)):
                if key in data:
                    try:
                        v = max(lo, min(hi, typ(data[key])))
                    except (TypeError, ValueError):
                        return self.error("Ungültiger Wert für " + key)
                    if key in ("ctx", "gpu_layers", "threads") and CONFIG.get(key) != v:
                        changed_llama = True
                    CONFIG[key] = v
            if "sleep_enabled" in data:
                CONFIG["sleep_enabled"] = bool(data["sleep_enabled"])
            if "update_repo" in data:
                repo = str(data["update_repo"]).strip()
                if repo and not re.fullmatch(r"[\w.\-]+/[\w.\-]+", repo):
                    return self.error("GitHub-Repo bitte als Besitzer/Name angeben")
                CONFIG["update_repo"] = repo
            if data.get("github_token") is not None and data.get("github_token") != "":
                CONFIG["github_token"] = str(data["github_token"]).strip()
            if data.get("github_token_clear"):
                CONFIG["github_token"] = ""
            if data.get("backend") in ("vulkan", "cpu") and data["backend"] != CONFIG.get("backend"):
                CONFIG["backend"] = data["backend"]
                save_config(CONFIG)
                LLAMA.stop()
                JOB.start("KI-Laufzeit wechseln", lambda: (install_llama(0, 100), LLAMA.restart()))
            save_config(CONFIG)
            if changed_llama:
                threading.Thread(target=LLAMA.restart, daemon=True).start()
            log("Einstellungen gespeichert")
            return self.send_json({"ok": True})
        if path == "/api/password":
            new = str(data.get("new", ""))
            if error := password_error(new):
                return self.error(error)
            if data.get("linux") and (len(new) < 8 or "\n" in new or "\r" in new):
                return self.error("Das Linux-Passwort braucht mindestens 8 Zeichen und darf keinen Zeilenumbruch enthalten")
            with _password_lock:
                if not check_password(str(data.get("old", ""))):
                    return self.error("Altes Passwort stimmt nicht", 403)
                set_ui_password(new)
            if data.get("linux"):
                user = CONFIG.get("username", "butchies")
                if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user):
                    return self.error("Ungültiger Benutzername in der Konfiguration")
                if DRYRUN:
                    log("[Testmodus] würde Linux-Passwort ändern")
                else:
                    p = subprocess.run(["chpasswd"], input="%s:%s\n" % (user, new), text=True, capture_output=True)
                    if p.returncode != 0:
                        return self.error("Linux-Passwort konnte nicht geändert werden: " + p.stderr.strip())
            log("Passwort geändert" + (" (auch Linux/SSH)" if data.get("linux") else ""))
            return self.send_json({"ok": True})
        if path == "/api/setup/run":
            ok = JOB.start("Ersteinrichtung", first_setup)
            return self.send_json({"ok": ok})
        if path == "/api/updates/run":
            ok = JOB.start("Updates", update_all, bool(data.get("llama", True)))
            return self.send_json({"ok": ok, "error": "" if ok else "Es läuft schon eine Aufgabe"})
        if path == "/api/updates/check":
            threading.Thread(target=check_updates, daemon=True).start()
            return self.send_json({"ok": True})
        if path == "/api/app/update":
            ok = JOB.start("Butchies KI Studio aktualisieren", update_app)
            return self.send_json({"ok": ok, "error": "" if ok else "Es läuft schon eine Aufgabe"})
        if path == "/api/app/rollback":
            ok = JOB.start("Vorherige Version wiederherstellen", rollback_app)
            return self.send_json({"ok": ok, "error": "" if ok else "Es läuft schon eine Aufgabe"})
        if path == "/api/models/custom":
            url = str(data.get("url", ""))
            if not parse_hf_url(url):
                return self.error("Bitte einen Hugging-Face-Link zu einer .gguf-Datei einfügen "
                                  "(…huggingface.co/<name>/<repo>/resolve/main/<datei>.gguf)")
            ok = JOB.start("Eigenes Modell laden", download_custom, url)
            return self.send_json({"ok": ok, "error": "" if ok else "Es läuft schon eine Aufgabe"})
        if path == "/api/ext/install":
            eid = str(data.get("id", ""))
            if eid not in INSTALLERS:
                return self.error("Diese Erweiterung gibt es (noch) nicht")
            name = next(e["name"] for e in EXTENSIONS if e["id"] == eid)
            ok = JOB.start("Erweiterung installieren: " + name, INSTALLERS[eid])
            return self.send_json({"ok": ok, "error": "" if ok else "Es läuft schon eine Aufgabe"})
        if path == "/api/ext/remove":
            eid = str(data.get("id", ""))
            if eid not in INSTALLERS:
                return self.error("Unbekannte Erweiterung")
            uninstall_ext(eid)
            return self.send_json({"ok": True})
        if path == "/api/images/generate":
            prompt = str(data.get("prompt", "")).strip()
            if not prompt:
                return self.error("Bitte beschreiben, was auf dem Bild sein soll")
            steps = max(1, min(8, int(data.get("steps") or 1)))
            ok = JOB.start("Bild erzeugen", generate_image, prompt[:1000], steps)
            return self.send_json({"ok": ok, "error": "" if ok else "Es läuft schon eine Aufgabe"})
        if path == "/api/images/delete":
            fn = os.path.basename(str(data.get("file", "")))
            fp = os.path.join(IMAGE_DIR, fn)
            if fn.endswith(".png") and os.path.exists(fp):
                os.remove(fp)
                if os.path.exists(fp + ".json"):
                    os.remove(fp + ".json")
            return self.send_json({"ok": True})
        if path == "/api/tts":
            text = str(data.get("text", ""))
            if not text.strip():
                return self.error("Kein Text")
            with ACTIVITY:
                try:
                    audio = text_to_speech(text)
                except RuntimeError as e:
                    return self.error(str(e), 500)
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(audio)))
            self.end_headers()
            self.wfile.write(audio)
            return
        if path == "/api/job/clear":
            if not JOB.running:
                JOB.error, JOB.name, JOB.done_at = "", "", 0
            return self.send_json({"ok": True})
        if path in ("/api/system/sleep", "/api/system/reboot", "/api/system/shutdown"):
            action = path.rsplit("/", 1)[1]
            self.send_json({"ok": True})
            def later():
                time.sleep(1.5)
                if action == "sleep":
                    go_to_sleep("per Knopf in der Oberfläche")
                elif action == "reboot":
                    log("Neustart per Fernsteuerung")
                    system_action(["systemctl", "reboot"])
                else:
                    log("Herunterfahren per Fernsteuerung")
                    enable_wol()
                    system_action(["systemctl", "poweroff"])
            threading.Thread(target=later, daemon=True).start()
            return
        return self.error("Nicht gefunden", 404)

    # --- Sprache -> Text (Audio als Rohdaten) ---------------------------------
    def stt(self):
        if not self.session():
            return self.error("Bitte anmelden", 401)
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > 50_000_000:
            return self.error("Keine oder zu große Aufnahme")
        audio = self.rfile.read(n)
        with ACTIVITY:
            try:
                return self.send_json({"ok": True, "text": speech_to_text(audio)})
            except RuntimeError as e:
                return self.error(str(e), 500)

    # --- Chat (Streaming an llama-server weiterreichen) --------------------
    def chat(self, data):
        msgs = data.get("messages") or []
        if not isinstance(msgs, list) or not msgs:
            return self.error("Keine Nachricht")
        has_images = any(isinstance(m, dict) and m.get("images") for m in msgs)
        engine = VISION if has_images else LLAMA
        if has_images and not ext_installed("vision"):
            return self.error("Für Bilder bitte zuerst die Erweiterung „Bilder verstehen“ installieren")
        if engine.state != "bereit" and not engine.healthy():
            if has_images:
                VISION.ensure_running()
            return self.error("Die KI ist noch nicht bereit (%s)" % engine.state, 503)
        clean = [{"role": "system", "content": SYSTEM_PROMPT}]
        for m in msgs[-40:]:
            if isinstance(m, dict) and m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str):
                imgs = [i for i in (m.get("images") or []) if isinstance(i, str) and i.startswith("data:image/")]
                if imgs and has_images:
                    parts = [{"type": "text", "text": m["content"] or "Was ist auf dem Bild?"}]
                    parts += [{"type": "image_url", "image_url": {"url": i}} for i in imgs[:4]]
                    clean.append({"role": m["role"], "content": parts})
                else:
                    clean.append({"role": m["role"], "content": m["content"]})
        meta = model_meta(CONFIG.get("active_model", "")) if not has_images else {}
        payload = {
            "messages": clean, "stream": True,
            "temperature": meta.get("temperature", 0.7),
            "top_p": meta.get("top_p", 0.8),
        }
        with ACTIVITY:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", engine.port, timeout=900)
                conn.request("POST", "/v1/chat/completions", body=json.dumps(payload),
                             headers={"Content-Type": "application/json"})
                resp = conn.getresponse()
            except OSError as e:
                return self.error("KI nicht erreichbar: %s" % e, 502)
            if resp.status != 200:
                txt = resp.read().decode("utf-8", "replace")[:500]
                return self.error("KI-Fehler %d: %s" % (resp.status, txt), 502)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            try:
                while True:
                    line = resp.readline()
                    if not line:
                        break
                    if b'"timings"' in line:
                        try:
                            t = json.loads(line.decode("utf-8")[5:]).get("timings", {})
                            if t.get("predicted_per_second"):
                                LLAMA.last_tps = round(t["predicted_per_second"], 1)
                        except ValueError:
                            pass
                    self.wfile.write(line)
                    self.wfile.flush()
                    ACTIVITY.touch()
            except (BrokenPipeError, ConnectionResetError):
                pass  # Browser hat abgebrochen
            finally:
                conn.close()


def setup_with_retry():
    """Ersteinrichtung starten; bei Fehler (z. B. Netz noch nicht da) automatisch wiederholen."""
    for attempt in range(1, 31):
        if llama_binary() and installed_models():
            return
        if not JOB.running:
            JOB.start("Ersteinrichtung", first_setup)
        time.sleep(5)
        while JOB.running:
            time.sleep(5)
        if not JOB.error:
            return
        log("Ersteinrichtung: neuer Versuch in 60 Sekunden (%d/30)" % attempt)
        time.sleep(60)


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(MODEL_DIR, exist_ok=True)
    log("Butchies KI Studio %s startet (Port %d%s)" % (VERSION, PORT, ", Testmodus" if DRYRUN else ""))
    enable_wol()
    threading.Thread(target=LLAMA.watch, daemon=True).start()
    threading.Thread(target=VISION.watch, daemon=True).start()
    load_catalog_cache()
    threading.Thread(target=update_check_thread, daemon=True).start()
    if ext_installed("vision"):
        VISION.start()
    threading.Thread(target=sleep_thread, daemon=True).start()
    if llama_binary() and installed_models():
        if not CONFIG.get("active_model"):
            CONFIG["active_model"] = installed_models()[0]["file"]
            save_config(CONFIG)
        LLAMA.start()
    elif os.environ.get("BKI_NOSETUP") != "1":
        threading.Thread(target=setup_with_retry, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    srv.serve_forever()


if __name__ == "__main__":
    if sys.argv[1:] == ["--recovery-code"]:
        create_recovery_code()
    elif len(sys.argv) == 1:
        main()
    else:
        raise SystemExit("Verwendung: server.py [--recovery-code]")
