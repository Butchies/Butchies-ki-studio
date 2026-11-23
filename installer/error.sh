#!/bin/bash
# Läuft, wenn die Ubuntu-Installation fehlschlägt: Grund anzeigen und Protokolle auf den Stick legen.
GRUND=$(grep -hiE "error|fail|traceback" /var/log/installer/subiquity-server-debug.log /var/log/installer/curtin-install.log 2>/dev/null | tail -3 | cut -c1-300 | tr '\n' ' ')
python3 - "$GRUND" <<'PY' || true
import json, sys, urllib.request
t = "Installation fehlgeschlagen: " + (sys.argv[1] or "unbekannter Fehler") + " – Protokolle liegen auf dem Stick (butchies-protokoll)."
req = urllib.request.Request("http://127.0.0.1/butchies", data=json.dumps({"percent": 0, "text": t, "state": "fehler"}).encode(),
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=3).read()
PY
if mount -o remount,rw /cdrom 2>/dev/null; then
  mkdir -p /cdrom/butchies-protokoll
  cp -r /var/log/installer/. /cdrom/butchies-protokoll/ 2>/dev/null
  cp /tmp/butchies-*.log /cdrom/butchies-protokoll/ 2>/dev/null
  lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,LABEL > /cdrom/butchies-protokoll/laufwerke.txt 2>&1
  sync; mount -o remount,ro /cdrom 2>/dev/null
fi
exit 0
