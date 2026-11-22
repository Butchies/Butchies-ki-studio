# Butchies KI Studio

Lokale Offline-KI fürs Programmieren auf einem Mini-PC im Heimnetz – bedient im Browser,
vollautomatisch per USB-Stick installiert, mit Fernsteuerung, Ruhezustand, Wake-on-LAN,
Taskleisten-Programm für Windows und Erweiterungen (Bilder verstehen, Sprache, Bilder erzeugen).

- **Server:** Python (nur Standardbibliothek) + llama.cpp (`llama-server`)
- **Standardmodell:** Qwen3-Coder 30B-A3B (Q4_K_M), weitere im Modell-Manager oder per Hugging-Face-Link
- **System:** Ubuntu Server 24.04 LTS (autoinstall)

**Einfachster Weg:** `windows\Setup.bat` starten (oder `Butchies-KI-Setup.exe` aus *Actions → Setup.exe bauen*). Der Assistent richtet Windows ein, fragt nach deinem USB-Stick und der gewünschten KI und baut den Stick – immer mit den neuesten Dateien.

**Download (komplettes Paket):** [download/butchies-ki-studio-0.4.0.zip](download/butchies-ki-studio-0.4.0.zip)

Schritt-für-Schritt-Anleitung: **Anleitung.pdf** (mit Bildern) bzw. **[ANLEITUNG.md](ANLEITUNG.md)**.

Version: 0.4.0 – nicht auf echter Hardware getestet.
