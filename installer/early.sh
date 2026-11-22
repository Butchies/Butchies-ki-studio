#!/bin/bash
# Butchies KI Studio – Sicherheitsprüfung VOR der Installation.
# Läuft im Live-System des Sticks. Es wird hier noch NICHTS gelöscht.
#
# Regeln ("Nur leere SSD"):
#   * Genau eine eingebaute Festplatte/SSD (USB-Laufwerke zählen nicht)
#   * Diese ist komplett leer (keine Partitionen, keine Signaturen)
#     -> Installation geht los
#   * Sie ist NICHT leer, enthält aber schon Butchies KI Studio
#     -> Start-Reihenfolge auf die SSD stellen und neu starten (Stick darf stecken bleiben)
#   * Alles andere -> Abbruch, Rechner schaltet sich nach 10 Minuten aus
set -u
B=/cdrom/butchies
LOG=/tmp/butchies-early.log
exec > >(tee -a "$LOG") 2>&1

status() { # status <prozent> <text> [running|fehler|fertig]
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

abort() {
  echo "ABBRUCH: $1"
  status 0 "Abbruch: $1 – es wurde nichts gelöscht. Der Rechner schaltet sich in 10 Minuten aus." fehler
  sleep 600
  poweroff -f
  sleep 30
  exit 1
}

echo "=== Butchies early.sh $(date) ==="
# Statusseite + mDNS-Name butchies-ki-setup.local starten
setsid nohup python3 "$B/installer/status_server.py" >/tmp/butchies-status.log 2>&1 </dev/null &
sleep 3
status 1 "Prüfe Festplatten …"

[ -f "$B/config.env" ] || abort "config.env fehlt auf dem Stick"
# shellcheck disable=SC1091
. "$B/config.env"
[ -n "${BKI_HOSTNAME:-}" ] || abort "Kein Rechnername in config.env"
[ -n "${BKI_USERNAME:-}" ] || abort "Kein Benutzername in config.env"

# --- Boot-Stick ermitteln -------------------------------------------------
SRC=$(findmnt -no SOURCE /cdrom 2>/dev/null | head -1)
STICK=$(lsblk -no PKNAME "$SRC" 2>/dev/null | head -1)
[ -n "$STICK" ] || STICK=$(basename "$SRC")
echo "Stick: $SRC ($STICK)"

# --- Eingebaute Laufwerke ---------------------------------------------------
INTERNAL=()
while read -r NAME TYPE TRAN; do
  [ "$TYPE" = "disk" ] || continue
  [ "$NAME" = "$STICK" ] && continue
  case "$NAME" in loop*|zram*|sr*|ram*|mmcblk*boot*) continue;; esac
  [ "${TRAN:-}" = "usb" ] && continue
  INTERNAL+=("$NAME")
done < <(lsblk -dnro NAME,TYPE,TRAN)
echo "Eingebaute Laufwerke: ${INTERNAL[*]:-keine}"

[ "${#INTERNAL[@]}" -ge 1 ] || abort "Keine eingebaute SSD gefunden (ist die M.2 richtig eingesteckt?)"
[ "${#INTERNAL[@]}" -eq 1 ] || abort "Mehr als ein eingebautes Laufwerk gefunden (${INTERNAL[*]}) – zur Sicherheit wird nicht installiert"

D="/dev/${INTERNAL[0]}"
PARTS=$(lsblk -nro NAME "$D" | tail -n +2 | wc -l)
SIG=$(wipefs -n "$D" 2>/dev/null | tail -n +2 | wc -l)
echo "$D: Partitionen=$PARTS Signaturen=$SIG"

if [ "$PARTS" -gt 0 ] || [ "$SIG" -gt 0 ]; then
  # Nicht leer – ist es schon unsere Installation?
  FOUND=0
  mkdir -p /mnt/bkicheck
  for P in $(lsblk -nro NAME "$D" | tail -n +2); do
    if mount -o ro "/dev/$P" /mnt/bkicheck 2>/dev/null; then
      [ -d /mnt/bkicheck/etc/butchies-ki ] && FOUND=1
      umount /mnt/bkicheck
    fi
    [ $FOUND = 1 ] && break
  done
  if [ $FOUND = 1 ]; then
    status 100 "Butchies KI Studio ist schon installiert – starte von der SSD …" fertig
    ID=$(efibootmgr 2>/dev/null | grep -i ubuntu | head -1 | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
    if [ -n "$ID" ]; then
      REST=$(efibootmgr | sed -nE 's/^BootOrder: //p' | tr ',' '\n' | grep -vi "^$ID$" | paste -sd, -)
      efibootmgr -o "$ID${REST:+,$REST}" || true
      efibootmgr -n "$ID" || true
    fi
    sleep 10
    reboot -f
    sleep 30
  fi
  abort "Die SSD $D ist nicht leer – das ist wohl nicht der Mini-PC"
fi

# --- Leere SSD: Platzhalter in der Installationsdatei ersetzen ------------
[ -n "${BKI_PASSWORD:-}" ] || abort "Kein Passwort auf dem Stick (wurde schon benutzt?) – bitte Stick neu bauen"
status 3 "Leere SSD $D gefunden – Installation startet"

export BKI_PASSWORD BKI_HOSTNAME BKI_USERNAME
for CFG in /autoinstall.yaml; do
  [ -f "$CFG" ] || cp /cdrom/autoinstall.yaml "$CFG"
  BKI_DISK="$D" python3 - "$CFG" <<'PY' || abort "Konnte Installationsdatei nicht vorbereiten"
import os, subprocess, sys, warnings
warnings.filterwarnings("ignore")
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
pw = os.environ["BKI_PASSWORD"]
try:
    import crypt
    h = crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512))
except ImportError:
    h = subprocess.run(["openssl", "passwd", "-6", "-stdin"], input=pw, capture_output=True,
                       text=True, check=True).stdout.strip()
if not h.startswith("$6$"):
    sys.exit("Passwort-Hash fehlgeschlagen")
for k, v in (("__DISK__", os.environ["BKI_DISK"]), ("__PWHASH__", h),
             ("__HOSTNAME__", os.environ["BKI_HOSTNAME"]), ("__USERNAME__", os.environ["BKI_USERNAME"])):
    text = text.replace(k, v)
open(path, "w", encoding="utf-8").write(text)
PY
done
grep -n "path:" /autoinstall.yaml
echo "early.sh fertig"
exit 0
