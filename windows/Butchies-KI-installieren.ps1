# Butchies KI – Taskleisten-Programm installieren (ohne Administratorrechte)
#  * kopiert das Programm nach %APPDATA%\ButchiesKI
#  * startet es automatisch mit Windows
#  * Desktop-Verknüpfung "Butchies KI" (öffnet die Oberfläche als eigenes Fenster und weckt den Mini-PC)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ziel = Join-Path $env:APPDATA "ButchiesKI"
New-Item -ItemType Directory -Force -Path $ziel | Out-Null

# Alte Versionen (Weck-Helfer) beenden und aufräumen
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'Weck-Helfer\.ps1|Butchies-KI\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$startup = [Environment]::GetFolderPath("Startup")
$desktop = [Environment]::GetFolderPath("Desktop")
foreach ($alt in @((Join-Path $startup "Butchies KI Weck-Helfer.lnk"), (Join-Path $desktop "Butchies KI.url"), (Join-Path $ziel "Weck-Helfer.ps1"))) {
  if (Test-Path $alt) { Remove-Item $alt -Force }
}

Copy-Item -Force (Join-Path $PSScriptRoot "Butchies-KI.ps1") (Join-Path $ziel "Butchies-KI.ps1")
$ps1 = Join-Path $ziel "Butchies-KI.ps1"

$name = Read-Host "Name des Mini-PCs [butchies-ki]"
if ([string]::IsNullOrWhiteSpace($name)) { $name = "butchies-ki" }
$name = $name.Trim().ToLower()

$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut((Join-Path $startup "Butchies KI.lnk"))
$lnk.TargetPath = "powershell.exe"
$lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`" -MiniPC $name"
$lnk.WindowStyle = 7
$lnk.Save()

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($edge) {
  $d = $sh.CreateShortcut((Join-Path $desktop "Butchies KI.lnk"))
  $d.TargetPath = $edge
  $d.Arguments = "--app=http://localhost:8765/ --user-data-dir=`"$ziel\edge-profil`" --window-size=1400,900 --unsafely-treat-insecure-origin-as-secure=http://$name"
  $d.IconLocation = "$edge,0"
  $d.Save()
} else {
  Set-Content -Path (Join-Path $desktop "Butchies KI.url") -Value "[InternetShortcut]`r`nURL=http://localhost:8765/" -Encoding ASCII
}

Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`" -MiniPC $name"

Write-Host ""
Write-Host "Butchies KI ist installiert und läuft." -ForegroundColor Green
Write-Host " - Symbol unten rechts in der Taskleiste (ggf. über den Pfeil ^ nach vorne ziehen)"
Write-Host " - Linksklick: Status-Fenster · Rechtsklick: Menü"
Write-Host " - Beim ersten Öffnen einmal das Passwort der Oberfläche eingeben"
Write-Host " - Desktop-Verknüpfung 'Butchies KI' öffnet die Oberfläche als eigenes Fenster"
Write-Host " - Startet ab jetzt automatisch mit Windows"
