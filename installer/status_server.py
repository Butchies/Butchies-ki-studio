#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Statusseite während der Installation – http://butchies-ki-setup.local

Läuft im Live-System des USB-Sticks (nur Python-Standardbibliothek):
  * Port 80: Fortschrittsseite (Prozent in 5-%-Blöcken) + status.json
  * POST /event     : Ereignisse des Ubuntu-Installers (reporting webhook)
  * POST /butchies  : eigene Meldungen von early.sh / late.sh
  * Kleiner mDNS-Responder, damit Windows "butchies-ki-setup.local" findet
"""
import json
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = "butchies-ki-setup.local"
PORT = 80

STATE = {"disk": "", "diskinfo": "", "percent": 0, "text": "Installation wird vorbereitet …", "state": "running",
         "log": [], "started": time.time()}
LOCK = threading.Lock()

# Schritte des Ubuntu-Installers -> ungefährer Fortschritt
STEPS = [
    ("partitioning", 12, "SSD wird eingerichtet (Partitionen)"),
    ("format", 14, "SSD wird formatiert"),
    ("extract", 22, "Ubuntu wird auf die SSD kopiert"),
    ("curthooks", 40, "System wird eingerichtet"),
    ("installing kernel", 48, "Kernel wird installiert"),
    ("configure_apt", 52, "Paketquellen werden eingerichtet"),
    ("install_package", 60, "Zusatzpakete werden installiert"),
    ("postinstall", 62, "Nacharbeiten"),
    ("apply_autoinstall", 64, "Benutzer und Netzwerk werden eingerichtet"),
    ("updates", 70, "Sicherheitsupdates werden installiert"),
    ("downloading and installing security updates", 70, "Sicherheitsupdates werden installiert"),
    ("late", 84, "Butchies KI Studio wird eingerichtet"),
]


def add_log(text):
    with LOCK:
        STATE["log"].append(time.strftime("%H:%M:%S ") + text)
        STATE["log"] = STATE["log"][-200:]


def set_progress(percent=None, text=None, state=None, disk=None, diskinfo=None):
    with LOCK:
        if disk is not None:
            STATE["disk"] = disk
        if diskinfo is not None:
            STATE["diskinfo"] = diskinfo
        if percent is not None and (state in ("fehler", "bestaetigen") or percent >= STATE["percent"]):
            STATE["percent"] = max(0, min(100, int(percent)))
        if text:
            STATE["text"] = text
        if state:
            STATE["state"] = state
    if text:
        add_log(("%3d %%  " % STATE["percent"]) + text)


PAGE = """<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Butchies KI Studio – Installation</title>
<style>
:root{--bg:#f3f3f3;--card:#fbfbfb;--line:#e5e5e5;--text:#1a1a1a;--sub:#5c5c5c;--acc:#0067c0;--track:#d4d4d4;--code:#f0f0f0;--bad:#c42b1c;--ok:#0f7b0f}
@media (prefers-color-scheme: dark){:root{--bg:#202020;--card:#2b2b2b;--line:#3d3d3d;--text:#fff;--sub:#c5c5c5;--acc:#4cc2ff;--track:#4a4a4a;--code:#1a1a1a;--bad:#ff99a4;--ok:#8fd88a}}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 "Segoe UI Variable","Segoe UI",system-ui,sans-serif;display:flex;justify-content:center;padding:40px 18px}
.card{max-width:720px;width:100%;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:28px}
h1{margin:0 0 4px;font-size:24px;font-weight:600}.muted{color:var(--sub)}
.pct{font-size:46px;font-weight:600;color:var(--acc);margin:18px 0 8px}
.blocks{display:grid;grid-template-columns:repeat(20,1fr);gap:4px;height:14px}
.blocks span{background:var(--track);border-radius:2px}.blocks span.on{background:var(--acc)}
.fehler .pct{color:var(--bad)}.fehler .blocks span.on{background:var(--bad)}.bestaetigen .pct{color:var(--bad)}.fertig .pct{color:var(--ok)}.fertig .blocks span.on{background:var(--ok)}
#text{margin:14px 0;font-size:16px}
pre{background:var(--code);border-radius:6px;padding:12px;font:12px/1.5 Consolas,monospace;color:var(--sub);max-height:300px;overflow:auto;white-space:pre-wrap}
</style></head><body><div class="card" id="card">
<h1>Butchies KI Studio wird installiert</h1>
<div class="muted">Du musst nichts tun. Am Ende startet der Mini-PC neu und ist dann unter
<b>http://BKI_HOST.local</b> erreichbar.</div>
<div class="pct" id="pct">0 %</div>
<div class="blocks" id="blocks" role="progressbar" aria-valuemin="0" aria-valuemax="100"></div>
<div id="text"></div><div class="muted" id="time"></div>
<div id="confirm" style="display:none;margin:14px 0;padding:14px;border-radius:8px;background:#fde7e9;border:1px solid #f1bbbc;color:#1a1a1a">
<b>Achtung: Alles auf dieser SSD wird gelöscht.</b>
<pre id="dinfo" style="background:#fff;color:#1a1a1a"></pre>
<label style="display:flex;gap:8px;align-items:center;margin:8px 0"><input type="checkbox" id="cb"> Ja, das ist die SSD im Mini-PC – löschen und installieren</label>
<button id="go" style="height:36px;padding:0 16px;border-radius:4px;border:0;background:#c42b1c;color:#fff;font-weight:600;cursor:pointer">SSD löschen und installieren</button></div>
<details><summary class="muted">Protokoll</summary><pre id="log"></pre></details>
</div><script>
const b=document.getElementById("blocks");for(let i=0;i<20;i++)b.appendChild(document.createElement("span"));
async function tick(){try{const s=await (await fetch("/status.json",{cache:"no-store"})).json();
document.getElementById("pct").textContent=s.percent+" %";
[...b.children].forEach((x,i)=>x.classList.toggle("on",i<Math.floor(s.percent/5)));
b.setAttribute("aria-valuenow",s.percent);
document.getElementById("text").textContent=s.text;
document.getElementById("card").className="card "+s.state;
document.getElementById("time").textContent="Läuft seit "+Math.floor(s.elapsed/60)+" Min.";
document.getElementById("log").textContent=s.log.join("\\n");
const cf=document.getElementById("confirm");cf.style.display=s.state==="bestaetigen"?"block":"none";
if(s.state==="bestaetigen"){document.getElementById("dinfo").textContent=s.diskinfo;window._disk=s.disk;}}catch(e){
document.getElementById("text").textContent="Mini-PC startet neu … gleich unter http://BKI_HOST.local erreichbar.";}}
tick();setInterval(tick,2000);
document.getElementById("go").onclick=async()=>{if(!document.getElementById("cb").checked){alert("Bitte zuerst den Haken setzen.");return;}
const r=await fetch("/confirm",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({disk:window._disk})});
if(!r.ok)alert("Bestätigung nicht angenommen – Seite neu laden.");};
</script></body></html>"""


def host_name():
    try:
        for line in open("/cdrom/butchies/config.env", encoding="utf-8"):
            if line.startswith("BKI_HOSTNAME="):
                return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return "butchies-ki"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/status.json"):
            with LOCK:
                s = dict(STATE)
            s["elapsed"] = int(time.time() - s.pop("started"))
            return self.send(200, "application/json; charset=utf-8", json.dumps(s).encode())
        self.send(200, "text/html; charset=utf-8", PAGE.replace("BKI_HOST", host_name()).encode())

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            data = {}
        if self.path.startswith("/butchies"):
            set_progress(data.get("percent"), data.get("text"), data.get("state"), data.get("disk"), data.get("diskinfo"))
        elif self.path.startswith("/confirm"):
            d = str(data.get("disk", ""))
            with LOCK:
                ok = STATE.get("state") == "bestaetigen" and d and d == STATE.get("disk")
            if ok:
                with open("/tmp/butchies-confirm", "w") as f:
                    f.write(d)
                set_progress(3, "Löschen bestätigt – Installation startet", "running")
            return self.send(200 if ok else 409, "application/json", json.dumps({"ok": bool(ok)}).encode())
        elif self.path.startswith("/event"):
            handle_event(data)
        self.send(200, "application/json", b'{"ok":true}')


def handle_event(ev):
    name = str(ev.get("name", "")).lower()
    desc = str(ev.get("description", ""))
    etype = ev.get("event_type", "")
    if etype == "finish" and ev.get("result") == "FAIL":
        add_log("Warnung: %s (%s)" % (desc or name, ev.get("result")))
    for key, pct, text in STEPS:
        if key in name or key in desc.lower():
            set_progress(pct, text)
            break


# --- Mini-mDNS-Responder ------------------------------------------------------

def my_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


def encode_name(name):
    out = b""
    for part in name.strip(".").split("."):
        out += bytes([len(part)]) + part.encode()
    return out + b"\x00"


def read_name(data, off):
    labels, jumped, end = [], False, off
    for _ in range(50):
        ln = data[off]
        if ln == 0:
            off += 1
            break
        if ln & 0xC0 == 0xC0:
            ptr = ((ln & 0x3F) << 8) | data[off + 1]
            if not jumped:
                end = off + 2
            off, jumped = ptr, True
            continue
        labels.append(data[off + 1:off + 1 + ln].decode("ascii", "replace"))
        off += 1 + ln
    return ".".join(labels).lower(), (end if jumped else off)


def mdns_loop():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", 5353))
    mreq = struct.pack("4s4s", socket.inet_aton("224.0.0.251"), socket.inet_aton("0.0.0.0"))
    joined = False
    while True:
        if not joined:
            try:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
                joined = True
            except OSError:
                time.sleep(5)  # Netzwerk noch nicht bereit
                continue
        try:
            data, addr = sock.recvfrom(9000)
            if len(data) < 12:
                continue
            _id, flags, qd = struct.unpack(">HHH", data[:6])
            if flags & 0x8000:
                continue  # Antwort, keine Frage
            off = 12
            for _ in range(qd):
                qname, off = read_name(data, off)
                qtype, qclass = struct.unpack(">HH", data[off:off + 4])
                off += 4
                if qname == NAME and qtype in (1, 255):
                    ip = my_ip()
                    if not ip:
                        continue
                    ans = encode_name(NAME) + struct.pack(">HHIH", 1, 0x8001, 120, 4) + socket.inet_aton(ip)
                    pkt = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0) + ans
                    sock.sendto(pkt, ("224.0.0.251", 5353))
                    if qclass & 0x8000 or addr[1] != 5353:  # Unicast-Antwort gewünscht
                        sock.sendto(struct.pack(">HHHHHH", _id, 0x8400, 0, 1, 0, 0) + ans, addr)
        except (OSError, IndexError, struct.error):
            time.sleep(0.2)


def main():
    add_log("Statusseite gestartet")
    threading.Thread(target=mdns_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    srv.serve_forever()


if __name__ == "__main__":
    main()
