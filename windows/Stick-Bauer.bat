@echo off
rem Butchies KI Studio - Stick-Bauer starten (mit Administratorrechten)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Stick-Bauer.ps1\"'"
