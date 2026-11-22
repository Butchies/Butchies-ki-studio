# Butchies KI Studio – Anleitung

Offline-KI fürs Programmieren auf deinem Mini-PC, bedient komplett aus der Ferne über den Browser.

> **Stand 0.3.1 – noch nicht auf echter Hardware getestet.**
> Server, Oberfläche, Statusseite und Passwort-Vorbereitung wurden in einer Testumgebung geprüft.
> USB-Stick, Ubuntu-Installation, Ruhezustand und Wake-on-LAN laufen zum ersten Mal auf deinem Mini-PC.

---

## Was du brauchst

| | |
|---|---|
| Mini-PC | Ryzen 9 5900HX, 64 GB RAM, **eingebaute, leere** M.2-SSD (NVMe, empfohlen 1 TB) |
| USB-Stick | mind. 4 GB – **wird komplett gelöscht** |
| Netzwerk | LAN-Kabel zum Router (für die Installation braucht er einmal Internet) |
| Windows-PC | zum Bauen des Sticks (Administratorrechte) |

## Ordner im Paket

```
installer/   automatische Ubuntu-Installation (autoinstall.yaml, early.sh, late.sh, Statusseite)
server/      Butchies KI Studio (Server + Browser-Oberfläche + Systemdienste)
windows/     Stick-Bauer und Taskleisten-Programm für deinen Windows-PC
```

---

## 1. Stick bauen (am Windows-PC)

1. Paket **komplett** entpacken (alle drei Ordner müssen nebeneinander liegen).
2. USB-Stick einstecken.
3. `windows\Stick-Bauer.bat` doppelklicken → Administratorrechte bestätigen.
4. Fragen beantworten:
   - Name des Mini-PCs (Standard `butchies-ki`)
   - Benutzername für Linux/SSH (Standard `butchies`)
   - Passwort (mind. 8 Zeichen)
5. Der Stick-Bauer lädt Ubuntu Server 24.04 (ca. 3 GB, Prüfsumme wird geprüft), löscht den Stick
   (du musst **JA** eintippen) und kopiert alles drauf – mit Fortschritt in 5-%-Schritten.

Hast du die Ubuntu-ISO schon? Dann in PowerShell (als Admin):
`.\Stick-Bauer.ps1 -IsoPfad "D:\ubuntu-24.04.x-live-server-amd64.iso"`

## 2. Mini-PC installieren (einmal hingehen)

1. SSD einbauen, Stick + LAN-Kabel + Strom einstecken.
2. Einschalten. Da die SSD leer ist, startet er vom Stick.
3. Am Windows-PC im Browser: **http://butchies-ki-setup.local**
   → Fortschritt in Prozent (dauert je nach Internet ca. 15–30 Minuten).
4. Am Ende startet der Mini-PC neu. Der Stick **darf stecken bleiben** – die Startreihenfolge
   wird automatisch auf die SSD gestellt.

**Sicherheit („nur leere SSD“):** Der Stick installiert nur, wenn **genau ein** eingebautes Laufwerk
da ist und dieses **komplett leer** ist. Steckt er aus Versehen in deinem Haupt-PC, bricht er ab,
löscht nichts und schaltet den Rechner nach 10 Minuten aus.
Nach der Installation wird dein Passwort automatisch vom Stick gelöscht; das Protokoll liegt dann
im Ordner `butchies-protokoll` auf dem Stick.

Startet er nicht vom Stick? Dann einmal mit Monitor ins Boot-Menü (meist **F7**, **F11** oder **F12**
beim Einschalten) und den Stick wählen.

## 3. Erste Anmeldung

1. Browser: **http://butchies-ki.local** (oder dein gewählter Name)
2. Passwort für die Oberfläche festlegen (mind. 8 Zeichen).
3. Oben erscheint ein Ladebalken: die KI-Laufzeit (llama.cpp) und das Modell
   **Qwen3-Coder 30B-A3B** (ca. 17 GB) werden heruntergeladen. Danach steht oben „KI: bereit“.

Ab dann läuft alles offline. Internet braucht er nur noch für Updates und neue Modelle.

## 4. Taskleisten-Programm (am Windows-PC)

1. `windows\Butchies-KI-installieren.bat` doppelklicken (keine Adminrechte nötig).
2. Unten rechts erscheint das **Butchies-KI-Symbol** (falls versteckt: über den Pfeil **^** in die Taskleiste ziehen):
   - **grün + Zahl** = wach, Zahl = Prozessor-Auslastung in %
   - **Akzentfarbe + Zahl** = KI arbeitet
   - **grau „Zz“** = schläft oder aus · **rot „!“** = Problem · **„?“** = einmal anmelden
3. **Linksklick** öffnet das Status-Fenster (im Windows-Design, hell/dunkel und Akzentfarbe wie Windows):
   Auslastung, Temperatur, Tempo, laufende Updates mit Prozent, Knöpfe *Oberfläche öffnen*,
   *Schlafen legen / Aufwecken*, *Neu starten*, *Herunterfahren*. Beim ersten Mal das Passwort der Oberfläche eingeben
   (wird verschlüsselt nur auf diesem PC gespeichert).
4. **Oberfläche öffnen** (oder Desktop-Verknüpfung **Butchies KI**) öffnet die Oberfläche als eigenes Fenster und weckt
   den Mini-PC vorher, falls er schläft. Hier funktioniert auch das Mikrofon zum Diktieren.

Das Abfragen des Status hält den Mini-PC **nicht** wach.
Am Handy: Wake-on-LAN-App nehmen, die MAC-Adresse steht in der Oberfläche unter **System**.

## 5. Ruhezustand

- Nach **5 Minuten** ohne Nutzung schläft er (unter *Einstellungen* änderbar).
- Er schläft **nicht**, solange die KI antwortet, ein Download/Update läuft oder SSH offen ist.
- Um **3 Uhr** wacht er selbst auf, spielt Sicherheitsupdates ein und schläft wieder.

## 6. Fernzugriff

| Was | Wo |
|---|---|
| Oberfläche | http://butchies-ki.local |
| Updates, Neustart, Herunterfahren, Protokoll | Oberfläche → **System** |
| Modelle laden/wechseln/löschen | Oberfläche → **Modelle** |
| Kommandozeile (Notfall) | `ssh butchies@butchies-ki.local` (in Windows-Terminal/PowerShell) |
| Dienst neu starten | `sudo systemctl restart butchies-ki` |
| Protokoll ansehen | `journalctl -u butchies-ki -f` |

Zugriff gibt es nur aus deinem Heimnetz. Für unterwegs später z. B. Tailscale (ohne Ports am Router zu öffnen).

## 7. Updates

| Was | Wie |
|---|---|
| Sicherheitsupdates | automatisch jede Nacht um 3 Uhr |
| Ubuntu + KI-Laufzeit | *System → Ubuntu + KI-Laufzeit aktualisieren* |
| Butchies KI Studio | *System → Butchies KI aktualisieren* (aus GitHub, vorher automatische Sicherung, *Vorherige Version* stellt zurück) |
| Prüfung | einmal täglich; neue Versionen erscheinen als **„Update verfügbar“** in Oberfläche und Taskleisten-Fenster |

Das GitHub-Repo (Standard `Butchies/Butchies-ki-studio`) und bei privatem Repo ein Lesetoken stellst du unter
*Einstellungen → Updates* ein.

## 8. Modelle und Erweiterungen

- **Modelle:** drei fertige zur Auswahl, oder unter *Modelle → Eigenes Modell* einen Hugging-Face-Link zu einer `.gguf`-Datei einfügen.
- **Erweiterungen** (per Knopfdruck installieren/entfernen):

| Erweiterung | Was | Tempo |
|---|---|---|
| Bilder verstehen | Screenshots/Fotos im Chat anhängen oder einfügen (Strg+V) | läuft gut |
| Sprache → Text | „Diktieren“-Knopf im Chat (Mikrofon nur im Butchies-KI-Fenster) | läuft gut |
| Text → Sprache | „Vorlesen“-Knopf unter jeder Antwort | läuft gut |
| Bilder erzeugen | eigener Bereich „Bilder“, 512×512 | langsam (½ bis mehrere Minuten) |
| Videos erzeugen | – | kommt später |

## 9. BIOS – einmal mit Monitor (empfohlen, ca. 2 Minuten)

Diese zwei Einstellungen kann kein Stick automatisch setzen:

1. **Nach Stromausfall wieder an** – heißt je nach BIOS
   *Restore on AC Power Loss*, *AC Power Recovery* oder *State After G3* → **Power On** / **Last State**.
   Ohne das bleibt er nach einem Stromausfall aus.
2. **Wake-on-LAN** – *Wake on LAN*, *Power On By PCI-E* oder *PME Event Wake Up* → **Enabled**.
   Aus dem Ruhezustand klappt es oft auch ohne diese Einstellung (Linux schaltet WoL am Netzwerkchip selbst an).
   Teste es im Taskleisten-Fenster mit **Schlafen legen** und danach **Aufwecken**.

BIOS öffnen: beim Einschalten **Entf** oder **F2** drücken.

## 10. Wenn etwas nicht klappt

| Problem | Lösung |
|---|---|
| `butchies-ki-setup.local` geht nicht | IP des Mini-PCs im Router nachsehen (Gerät „ubuntu-server“) und direkt öffnen |
| `butchies-ki.local` geht nicht | IP im Router nachsehen (Gerät „butchies-ki“) und `http://IP` öffnen |
| Installation bricht ab | Statusseite zeigt den Grund. Protokoll im Ordner `butchies-protokoll` auf dem Stick |
| Stick „wurde schon benutzt“ | Passwort wurde nach der Installation gelöscht → Stick neu bauen |
| KI stürzt ab | *Einstellungen → KI-Laufzeit: Nur Prozessor (CPU)* |
| KI zu langsam | *Modelle* → kleineres Modell (gpt-oss-20b oder Qwen3 8B) |
| Er wacht nicht auf | BIOS-Punkt 2 einstellen; oder *Einstellungen → Ruhezustand* ausschalten |
| Taskleisten-Symbol zeigt „?“ | Symbol anklicken und Passwort der Oberfläche eingeben |
| Mikrofon geht nicht | Oberfläche über das Taskleisten-Programm oder die Desktop-Verknüpfung öffnen |
| Erweiterung schlägt fehl | Fehlertext im Ladebalken bzw. *System → Protokoll*; Installation einfach erneut starten |
