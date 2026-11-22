@echo off
rem Butchies KI Studio - Setup-Assistent starten (fragt nach Administratorrechten)
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Setup.ps1"
