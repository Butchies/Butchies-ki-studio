#!/bin/bash
# Butchies KI Studio – Einrichtung NACH der Ubuntu-Installation.
# Läuft im Live-System; das neue System ist unter /target eingehängt.
set -u
B=/cdrom/butchies
T=/target
LOG=/tmp/butchies-late.log
exec > >(tee -a "$LOG") 2>&1

status() {
  python3 - "$1" "$2" "${3:-running}" <<'PY' || true
import json, sys, urllib.request
p, t, s = sys.argv[1:4]
req = urllib.request.Request("http://127.0.0.1/butchies", data=json.dumps(
    {"percent": int(p), "text": t, "state": s}).encode(), headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=3).read()
except Exception:
    pass
PY
}
in_target() { curtin in-target --target="$T" -- "$@"; }

echo "=== Butchies late.sh $(date) ==="
# shellcheck disable=SC1091
. "$B/config.env"
status 86 "Kopiere Butchies KI Studio auf die SSD …"

install -d -m 755 "$T/opt/butchies-ki" "$T/var/lib/butchies-ki"
install -d -m 700 "$T/etc/butchies-ki"
cp -r "$B/server/." "$T/opt/butchies-ki/"
chmod 755 "$T/opt/butchies-ki/server.py" "$T/opt/butchies-ki/wol-enable.sh"
cp "$B/server/systemd/"*.service "$B/server/systemd/"*.timer "$T/etc/systemd/system/"

cat > "$T/etc/butchies-ki/config.json" <<EOF
{
  "username": "$BKI_USERNAME",
  "sleep_enabled": true,
  "sleep_minutes": 5
}
EOF
chmod 600 "$T/etc/butchies-ki/config.json"

# Im Installer gewählte KI-Modelle und Erweiterungen (lädt der Mini-PC bei der Ersteinrichtung)
BKI_MODELS="${BKI_MODELS:-}" BKI_CUSTOM_MODELS="${BKI_CUSTOM_MODELS:-}" BKI_EXTENSIONS="${BKI_EXTENSIONS:-}" python3 - <<'PY' > "$T/etc/butchies-ki/models-wanted.json"
import json, os
s = lambda k, sep: [x for x in os.environ.get(k, "").replace(",", " ").split() if x]
print(json.dumps({"models": s("BKI_MODELS", ","), "custom": s("BKI_CUSTOM_MODELS", " "), "extensions": s("BKI_EXTENSIONS", ",")}))
PY

# Modelle, die schon auf dem Stick liegen (zweiter Bereich "BKIMODELLE"), direkt übernehmen
if [ -e /dev/disk/by-label/BKIMODELLE ]; then
  status 88 "Kopiere KI-Modelle vom Stick auf die SSD …"
  mkdir -p /mnt/bkimodelle "$T/var/lib/butchies-ki/models"
  if mount -o ro /dev/disk/by-label/BKIMODELLE /mnt/bkimodelle; then
    cp -v /mnt/bkimodelle/models/*.gguf /mnt/bkimodelle/models/*.gguf.json "$T/var/lib/butchies-ki/models/" 2>/dev/null || true
    umount /mnt/bkimodelle
  fi
fi

status 90 "Richte Dienste ein (Oberfläche, Wake-on-LAN, Nacht-Updates) …"
in_target systemctl enable butchies-ki.service butchies-wol.service butchies-nightly.timer avahi-daemon.service ssh.service || true

# Sicherheitsupdates automatisch; die Prüfung macht unser Nacht-Timer um 3 Uhr
cat > "$T/etc/apt/apt.conf.d/20auto-upgrades" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Kein Ruhezustand durch systemd-logind selbst (das steuert Butchies KI)
install -d "$T/etc/systemd/logind.conf.d"
cat > "$T/etc/systemd/logind.conf.d/butchies.conf" <<'EOF'
[Login]
HandlePowerKey=poweroff
HandleLidSwitch=ignore
IdleAction=ignore
EOF

# Startreihenfolge: SSD (ubuntu) zuerst, damit der Stick stecken bleiben darf
status 94 "Stelle Startreihenfolge auf die SSD …"
ID=$(efibootmgr 2>/dev/null | grep -i ubuntu | head -1 | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
if [ -n "$ID" ]; then
  REST=$(efibootmgr | sed -nE 's/^BootOrder: //p' | tr ',' '\n' | grep -vi "^$ID$" | paste -sd, -)
  efibootmgr -o "$ID${REST:+,$REST}" || true
  echo "BootOrder gesetzt: $ID zuerst"
else
  echo "Kein ubuntu-Starteintrag gefunden – Stick nach der Installation bitte abziehen"
fi

# Protokoll auf den Stick schreiben und Passwort vom Stick entfernen
status 97 "Schreibe Protokoll auf den Stick …"
if mount -o remount,rw /cdrom 2>/dev/null; then
  mkdir -p /cdrom/butchies-protokoll
  cp /tmp/butchies-*.log /cdrom/butchies-protokoll/ 2>/dev/null || true
  cp /var/log/installer/*.log /cdrom/butchies-protokoll/ 2>/dev/null || true
  sed -i 's/^BKI_PASSWORD=.*/BKI_PASSWORD=/' /cdrom/butchies/config.env || true
  sync
  mount -o remount,ro /cdrom 2>/dev/null || true
  echo "Protokoll und Passwort-Löschung auf dem Stick erledigt"
else
  echo "Stick ist schreibgeschützt eingehängt – Protokoll bleibt nur im Speicher"
fi

status 99 "Fertig! Der Mini-PC startet neu. Danach: http://$BKI_HOSTNAME.local – dort lädt er die KI (ca. 17 GB)." fertig
echo "late.sh fertig"
exit 0
