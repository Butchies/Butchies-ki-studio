<#
  Butchies KI Studio – Setup-Assistent (Windows 10/11)
  1 Willkommen · 2 Systemprüfung · 3 Windows-Teil · 4 USB-Stick · 5 KI-Auswahl
  6 Stick/Zugangsdaten · 7 Online-Prüfung · 8 Stick erstellen · 9 Fertig (+ Mini-PC live verfolgen)

  * holt immer die neuesten Butchies-Dateien und den Modell-Katalog von GitHub
  * merkt sich Downloads (Offline-Modus für weitere Sticks)
  * KI-Autopilot: macht alles, was keine Entscheidung braucht, selbst – jederzeit abschaltbar
  * löscht einen Stick NUR nach ausdrücklicher Bestätigung
#>
param([switch]$Elevated)

$ErrorActionPreference = "Stop"
$Repo = "Butchies/Butchies-ki-studio"
$SetupVersion = "0.4.3"
# Komplettes Paket (installer, server, Taskleiste) – wird beim Bauen der EXE eingefügt
$EmbeddedPayload = "__PAYLOAD__"

# --- Administratorrechte (für das Formatieren des Sticks) ---------------------------
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  $self = if ($PSCommandPath) { $PSCommandPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
  if ($self -like "*.exe") { Start-Process $self -Verb RunAs -ArgumentList "-Elevated" }
  else { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Elevated" }
  exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Home2 = Join-Path $env:APPDATA "ButchiesKI"
$Cache = Join-Path $Home2 "cache"
New-Item -ItemType Directory -Force -Path $Home2, $Cache | Out-Null
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }

# --- Gemeinsamer Zustand mit dem Hintergrund-Thread --------------------------------
$sync = [hashtable]::Synchronized(@{
  Ver = 0; Rows = (New-Object Collections.ArrayList); Percent = -1; PercentText = ""; Busy = $false; Done = ""; Error = ""
  Autopilot = $true; Log = (New-Object Collections.ArrayList)
  Repo = $Repo; Cache = $Cache; Home = $Home2; ScriptDir = $ScriptDir; SetupVersion = $SetupVersion
  Latest = ""; Catalog = $null; Embedded = $EmbeddedPayload; Disks = @(); Choice = @{}; Follow = $null; ExtractDir = ""
})

# =====================================================================================
# Hintergrund-Arbeiten (laufen in eigenem Thread, melden über $sync)
# =====================================================================================
$workerCode = {
param($sync, $task)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromHours(6)
$http.DefaultRequestHeaders.UserAgent.ParseAdd("ButchiesKISetup/$($sync.SetupVersion)")

function Ping { $sync.Ver++ }
function Log($t) { [void]$sync.Log.Add((Get-Date -Format "HH:mm:ss ") + $t); Ping }
function Row($key, $state, $title, $sub = "", $right = "") {
  $r = $null
  foreach ($x in $sync.Rows) { if ($x.Key -eq $key) { $r = $x } }
  if (-not $r) { $r = @{ Key = $key }; [void]$sync.Rows.Add($r) }
  $r.State = $state; $r.Title = $title; $r.Sub = $sub; $r.Right = $right; Ping
}
function Pct($p, $t) { $sync.Percent = [int][Math]::Max(0, [Math]::Min(100, $p)); if ($t) { $sync.PercentText = $t }; Ping }
function Versuch($name, [scriptblock]$sb) {
  $max = if ($sync.Autopilot) { 3 } else { 1 }
  for ($i = 1; $i -le $max; $i++) {
    try { return (& $sb) } catch {
      Log "$name – Versuch $i fehlgeschlagen: $($_.Exception.Message)"
      if ($i -eq $max) { throw }
      Start-Sleep -Seconds (3 * $i)
    }
  }
}
function GetText($url) { Versuch $url { $http.GetStringAsync($url).Result } }
function Download($url, $dest, $label, $pFrom, $pTo) {
  if (Test-Path $dest) { return }
  Versuch $label {
    $part = "$dest.part"
    $have = if (Test-Path $part) { (Get-Item $part).Length } else { 0 }
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
    if ($have -gt 0) { $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($have, $null) }
    $resp = $http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode)" }
    if ($have -gt 0 -and [int]$resp.StatusCode -ne 206) { $have = 0 }
    $len = $resp.Content.Headers.ContentLength
    $total = if ($len) { [double]$len + $have } else { 0 }
    $in = $resp.Content.ReadAsStreamAsync().Result
    $out = if ($have -gt 0) { [IO.File]::Open($part, "Append") } else { [IO.File]::Create($part) }
    $buf = New-Object byte[] (4MB); $done = $have; $sw = [Diagnostics.Stopwatch]::StartNew(); $last = 0
    try {
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n); $done += $n
        if ($total -gt 0 -and $sw.ElapsedMilliseconds - $last -gt 400) {
          $last = $sw.ElapsedMilliseconds
          $speed = ($done - $have) / [Math]::Max(1, $sw.Elapsed.TotalSeconds)
          $rest = ($total - $done) / [Math]::Max(1, $speed)
          Row $label "spin" $label ("{0:N1} / {1:N1} GB" -f ($done / 1GB), ($total / 1GB)) ("{0:N0} MB/s · noch ca. {1}" -f ($speed / 1MB), $(if ($rest -gt 90) { "{0:N0} Min." -f ($rest / 60) } else { "{0:N0} s" -f $rest }))
          Pct ($pFrom + ($pTo - $pFrom) * $done / $total) $label
        }
      }
    } finally { $out.Close(); $in.Close() }
    Move-Item -Force $part $dest
  }
}

# ---------------------------------------------------------------- Aufgaben
switch ($task) {

"start" {
  try { $sync.Latest = (GetText "https://raw.githubusercontent.com/$($sync.Repo)/main/VERSION").Trim() } catch { $sync.Latest = "" }
  try {
    $cat = GetText "https://raw.githubusercontent.com/$($sync.Repo)/main/modelle.json"
    Set-Content -Path (Join-Path $sync.Cache "modelle.json") -Value $cat -Encoding UTF8
  } catch {}
  $f = Join-Path $sync.Cache "modelle.json"
  if (Test-Path $f) { $sync.Catalog = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json }
  $sync.Done = "start"; Ping
}

"system" {
  $sync.Rows.Clear(); $ok = $true
  # [Environment]::OSVersion meldet in der EXE fälschlich Windows 8 (6.2) – deshalb aus der Registry lesen
  $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
  $major = [int]$cv.CurrentMajorVersionNumber; $bnum = [int]$cv.CurrentBuildNumber
  $build = $cv.DisplayVersion
  $name = if ($bnum -ge 22000) { "Windows 11" } else { "Windows 10" }
  if ($major -ge 10 -and $bnum -ge 17763 -and [Environment]::Is64BitOperatingSystem) { Row os ok "Windows 10 oder 11 (64 Bit)" "ab Windows 10 Version 1809" "$name $build" }
  else { Row os bad "Windows 10 oder 11 (64 Bit)" "Dieses Windows ist zu alt" "$name $build"; $ok = $false }
  Start-Sleep -Milliseconds 300
  Row admin ok "Administratorrechte" "nötig für das Formatieren des Sticks"
  Start-Sleep -Milliseconds 300
  $net = 0; try { $net = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full").Release } catch {}
  if ($PSVersionTable.PSVersion.Major -ge 5 -and $net -ge 461808) { Row ps ok "PowerShell 5.1 und .NET Framework 4.7.2+" "in Windows enthalten" }
  else { Row ps bad "PowerShell 5.1 und .NET Framework 4.7.2+" "Bitte Windows Update ausführen"; $ok = $false }
  Start-Sleep -Milliseconds 300
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($edge) { Row edge ok "Microsoft Edge" "für das Butchies-KI-Fenster und das Mikrofon" }
  else { Row edge info "Microsoft Edge" "nicht gefunden – die Oberfläche öffnet dann im Standard-Browser" "optional" }
  Start-Sleep -Milliseconds 300
  Row net spin "Internetverbindung" "GitHub, Ubuntu und Hugging Face"
  $reach = 0
  foreach ($u in "https://api.github.com", "https://releases.ubuntu.com/24.04/", "https://huggingface.co") {
    try { $r = $http.GetAsync($u).Result; if ($r.IsSuccessStatusCode -or [int]$r.StatusCode -lt 500) { $reach++ } } catch {}
  }
  if ($reach -eq 3) { Row net ok "Internetverbindung" "GitHub, Ubuntu und Hugging Face erreichbar" }
  elseif ((Get-ChildItem $sync.Cache -Filter *.iso -ErrorAction SilentlyContinue)) { Row net info "Internetverbindung" "nicht alles erreichbar – Offline-Modus mit gespeicherten Dateien" "offline" }
  else { Row net bad "Internetverbindung" "Ohne Internet und ohne gespeicherte Dateien geht es nicht weiter"; $ok = $false }
  $drive = (Get-Item $sync.Home).PSDrive.Name
  $free = (Get-PSDrive $drive).Free
  if ($free -ge 5GB) { Row disk ok "Freier Speicherplatz" "mind. 5 GB für Downloads" ("{0:N0} GB frei" -f ($free / 1GB)) }
  else { Row disk bad "Freier Speicherplatz" "mind. 5 GB nötig auf $($drive):" ("{0:N1} GB frei" -f ($free / 1GB)); $ok = $false }
  $amd = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "AMD|Radeon" } | Select-Object -First 1
  if ($amd) { Row gpu info "AMD-Grafiktreiber" "optional – nur für den späteren Turbo-Modus" "$($amd.Name) · $($amd.DriverVersion)" }
  else { Row gpu info "AMD-Grafiktreiber" "optional – nur für den späteren Turbo-Modus" "nicht nötig" }
  $sync.Done = if ($ok) { "system-ok" } else { "system-fail" }; Ping
}

"windows" {
  $sync.Rows.Clear(); Pct 0 "Windows-Teil"
  $src = $sync.ExtractDir
  Row dir spin "Programmordner anlegen" $sync.Home
  New-Item -ItemType Directory -Force -Path $sync.Home | Out-Null
  Row dir ok "Programmordner anlegen" $sync.Home; Pct 15
  Row tray spin "Taskleisten-Programm »Butchies KI«" "Status-Symbol mit Auslastung"
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Weck-Helfer\.ps1|Butchies-KI\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Copy-Item -Force (Join-Path $src "windows\Butchies-KI.ps1") (Join-Path $sync.Home "Butchies-KI.ps1")
  $host2 = $sync.Choice.Host; if (-not $host2) { $host2 = "butchies-ki" }
  $tcfg = Join-Path $sync.Home "taskleiste.json"
  if (-not (Test-Path $tcfg)) { @{ host = $host2; mac = ""; ip = "" } | ConvertTo-Json | Set-Content $tcfg -Encoding UTF8 }
  Row tray ok "Taskleisten-Programm »Butchies KI«" "Status-Symbol mit Auslastung"; Pct 35
  $ps1 = Join-Path $sync.Home "Butchies-KI.ps1"
  $sh = New-Object -ComObject WScript.Shell
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  Row edge spin "Edge-App-Profil mit Mikrofon-Freigabe" "für Diktieren im Butchies-KI-Fenster"
  New-Item -ItemType Directory -Force -Path (Join-Path $sync.Home "edge-profil") | Out-Null
  Row edge ok "Edge-App-Profil mit Mikrofon-Freigabe" "für Diktieren im Butchies-KI-Fenster"; Pct 50
  Row lnk spin "Desktop-Verknüpfung und Startmenü"
  $startMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "Butchies KI"
  New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
  foreach ($dir in @([Environment]::GetFolderPath("Desktop"), $startMenu)) {
    $l = $sh.CreateShortcut((Join-Path $dir "Butchies KI.lnk"))
    if ($edge) { $l.TargetPath = $edge; $l.Arguments = "--app=http://localhost:8765/ --user-data-dir=`"$($sync.Home)\edge-profil`" --window-size=1400,900 --unsafely-treat-insecure-origin-as-secure=http://$host2.local"; $l.IconLocation = "$edge,0" }
    else { $l.TargetPath = "http://localhost:8765/" }
    $l.Save()
  }
  Row lnk ok "Desktop-Verknüpfung und Startmenü"; Pct 65
  Row auto spin "Mit Windows starten" "Autostart"
  $startup = [Environment]::GetFolderPath("Startup")
  foreach ($old in "Butchies KI Weck-Helfer.lnk") { $p = Join-Path $startup $old; if (Test-Path $p) { Remove-Item $p -Force } }
  $l = $sh.CreateShortcut((Join-Path $startup "Butchies KI.lnk"))
  $l.TargetPath = "powershell.exe"; $l.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`""; $l.WindowStyle = 7; $l.Save()
  Row auto ok "Mit Windows starten" "Autostart"; Pct 80
  Row unin spin "Eintrag in »Apps & Features«" "zum sauberen Deinstallieren"
  $un = Join-Path $sync.Home "Deinstallieren.ps1"
  @'
$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName PresentationFramework
if ([Windows.MessageBox]::Show("Butchies KI (Taskleisten-Programm) von diesem PC entfernen?`nDer Mini-PC bleibt unverändert.", "Butchies KI deinstallieren", "YesNo", "Question") -ne "Yes") { exit }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'Butchies-KI\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Remove-Item (Join-Path ([Environment]::GetFolderPath("Startup")) "Butchies KI.lnk") -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath("Desktop")) "Butchies KI.lnk") -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath("Programs")) "Butchies KI") -Recurse -Force
Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ButchiesKI" -Recurse -Force
Start-Sleep -Seconds 1
Remove-Item (Join-Path $env:APPDATA "ButchiesKI") -Recurse -Force
[Windows.MessageBox]::Show("Butchies KI wurde entfernt.", "Butchies KI") | Out-Null
'@ | Set-Content -Path $un -Encoding UTF8
  $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ButchiesKI"
  New-Item -Path $k -Force | Out-Null
  Set-ItemProperty $k -Name DisplayName -Value "Butchies KI Studio (Taskleiste)"
  Set-ItemProperty $k -Name DisplayVersion -Value $sync.SetupVersion
  Set-ItemProperty $k -Name Publisher -Value "Butchies"
  Set-ItemProperty $k -Name UninstallString -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$un`""
  Set-ItemProperty $k -Name NoModify -Value 1 -Type DWord
  Set-ItemProperty $k -Name NoRepair -Value 1 -Type DWord
  Row unin ok "Eintrag in »Apps & Features«" "zum sauberen Deinstallieren"; Pct 92
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`" -MiniPC $host2"
  Pct 100 "Windows-Teil fertig"
  $sync.Done = "windows"; Ping
}

"payload" {
  # Neueste Butchies-Dateien von GitHub (Offline: letzter Stand im Cache, sonst neben dem Setup)
  $zip = Join-Path $sync.Cache "butchies-main.zip"; $dir = Join-Path $sync.Cache "butchies-main"
  try {
    $bytes = $http.GetByteArrayAsync("https://codeload.github.com/$($sync.Repo)/zip/refs/heads/main").Result
    [IO.File]::WriteAllBytes($zip, $bytes)
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dir -Force
  } catch { Log "GitHub nicht erreichbar – nehme gespeicherten Stand" }
  if (-not (Test-Path $dir) -and $sync.Embedded -and $sync.Embedded -ne ("__PAY" + "LOAD__")) {
    Log "Nehme das in der Setup.exe enthaltene Paket"
    [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($sync.Embedded))
    Expand-Archive -Path $zip -DestinationPath $dir -Force
  }
  $root = Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName "server\server.py") } | Select-Object -First 1
  if ($root) { $sync.ExtractDir = $root.FullName }
  elseif (Test-Path (Join-Path (Split-Path $sync.ScriptDir -Parent) "server\server.py")) { $sync.ExtractDir = Split-Path $sync.ScriptDir -Parent }
  else { $sync.Error = "Butchies-Dateien nicht gefunden (kein Internet und kein gespeicherter Stand)." }
  $sync.Done = "payload"; Ping
}

"scan" {
  $list = @()
  foreach ($d in (Get-Disk | Where-Object { $_.BusType -eq "USB" -and $_.Size -ge 4GB -and -not $_.IsBoot -and -not $_.IsSystem })) {
    $info = @{ Number = $d.Number; Name = $d.FriendlyName; Size = $d.Size; Letter = ""; Butchies = $false; Version = ""; Ubuntu = ""; Models = $false }
    foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {
      $v = $p | Get-Volume -ErrorAction SilentlyContinue
      if ($v.FileSystemLabel -eq "BUTCHIESKI" -and $p.DriveLetter) {
        $info.Letter = "$($p.DriveLetter):\"; $info.Butchies = $true
        $vf = Join-Path $info.Letter "butchies\VERSION"; if (Test-Path $vf) { $info.Version = (Get-Content $vf -Raw).Trim() } else { $info.Version = "älter als 0.4" }
        $di = Join-Path $info.Letter ".disk\info"; if (Test-Path $di) { $info.Ubuntu = (Get-Content $di -Raw).Trim() }
      }
      if ($v.FileSystemLabel -eq "BKIMODELLE") { $info.Models = $true }
      if (-not $info.Letter -and $p.DriveLetter) { $info.Letter = "$($p.DriveLetter):\" }
    }
    $list += $info
  }
  $sync.Disks = $list; $sync.Done = "scan"; Ping
}

"catalogsizes" {
  # Größe und Verfügbarkeit jedes Modells live bei Hugging Face prüfen
  if (-not $sync.Catalog) { $sync.Done = "catalogsizes"; Ping; return }
  foreach ($m in $sync.Catalog.models) {
    try {
      $j = (GetText "https://huggingface.co/api/models/$($m.repo)?blobs=true") | ConvertFrom-Json
      $f = $j.siblings | Where-Object { $_.rfilename -like "*$($m.pattern)" -and $_.rfilename -notmatch "/" -and $_.rfilename -notmatch "UD-" } | Sort-Object { $_.rfilename.Length } | Select-Object -First 1
      if ($f) { $m | Add-Member -Force NoteProperty live_gb ([Math]::Round($f.size / 1e9, 1)); $m | Add-Member -Force NoteProperty file $f.rfilename; $m | Add-Member -Force NoteProperty ok $true }
      else { $m | Add-Member -Force NoteProperty ok $false }
    } catch { $m | Add-Member -Force NoteProperty ok $null }
    Ping
  }
  $sync.Done = "catalogsizes"; Ping
}

"online" {
  $sync.Rows.Clear(); Pct 0 "Online-Prüfung"
  $c = $sync.Choice
  Row app spin "Butchies KI Studio" "GitHub: $($sync.Repo)"
  if (-not $sync.ExtractDir) { throw "Butchies-Dateien fehlen" }
  $ver = (Get-Content (Join-Path $sync.ExtractDir "VERSION") -Raw).Trim()
  Row app ok "Butchies KI Studio" "GitHub: $($sync.Repo)" "$ver ✓"; Pct 5
  Row iso spin "Ubuntu Server 24.04 – neueste Version suchen" "releases.ubuntu.com"
  $sumsFile = Join-Path $sync.Cache "SHA256SUMS"
  try { Set-Content $sumsFile (GetText "https://releases.ubuntu.com/24.04/SHA256SUMS") -Encoding ASCII } catch { Log "Ubuntu-Server nicht erreichbar – nehme gespeicherte Liste" }
  if (-not (Test-Path $sumsFile)) { throw "Ubuntu-Versionsliste nicht verfügbar (kein Internet?)" }
  $best = $null
  foreach ($line in (Get-Content $sumsFile)) {
    if ($line -match '^([0-9a-f]{64}) \*?(ubuntu-24\.04(\.(\d+))?-live-server-amd64\.iso)\s*$') {
      $n = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
      if (-not $best -or $n -gt $best.N) { $best = @{ Hash = $Matches[1]; Name = $Matches[2]; N = $n } }
    }
  }
  if (-not $best) { throw "Keine passende Ubuntu-ISO gefunden" }
  $iso = Join-Path $sync.Cache $best.Name
  $c.Iso = $iso; $c.IsoName = $best.Name
  Row iso ok "Ubuntu Server – neueste Version" "releases.ubuntu.com" $best.Name; Pct 8
  if (Test-Path $iso) { Row dl ok "Ubuntu-ISO" "schon gespeichert (Offline-Modus)" }
  else { Download "https://releases.ubuntu.com/24.04/$($best.Name)" $iso "Ubuntu-ISO herunterladen" 8 60 }
  Row sum spin "Prüfsumme (SHA-256)" "Schutz vor beschädigten Downloads"
  $h = (Get-FileHash $iso -Algorithm SHA256).Hash.ToLower()
  if ($h -ne $best.Hash) { Remove-Item $iso -Force; Row sum bad "Prüfsumme (SHA-256)" "Download beschädigt – wird beim nächsten Versuch neu geladen"; throw "Prüfsumme der Ubuntu-ISO falsch" }
  Row sum ok "Prüfsumme (SHA-256)" "stimmt"; Pct 62
  if ($c.ModelsOnStick -and $c.Models.Count -gt 0) {
    $i = 0
    foreach ($m in $c.Models) {
      $i++
      $file = if ($m.file) { $m.file } else { $null }
      if (-not $file) {
        $j = (GetText "https://huggingface.co/api/models/$($m.repo)") | ConvertFrom-Json
        $file = ($j.siblings | Where-Object { $_.rfilename -like "*$($m.pattern)" -and $_.rfilename -notmatch "/" -and $_.rfilename -notmatch "UD-" } | Sort-Object { $_.rfilename.Length } | Select-Object -First 1).rfilename
      }
      $dest = Join-Path $sync.Cache $file
      Download "https://huggingface.co/$($m.repo)/resolve/main/$file" $dest "KI-Modell $($m.name)" (62 + 37 * ($i - 1) / $c.Models.Count) (62 + 37 * $i / $c.Models.Count)
      @{ id = $m.id; name = $m.name; repo = $m.repo } | ConvertTo-Json | Set-Content "$dest.json" -Encoding UTF8
      Row "m$i" ok "KI-Modell $($m.name)" "gespeichert – kommt mit auf den Stick"
      $m | Add-Member -Force NoteProperty localfile $dest
    }
  } else { Row mod info "KI-Modelle" "lädt der Mini-PC nach der Installation selbst" "später" }
  Pct 100 "Alles aktuell"
  $sync.Done = "online"; Ping
}

"create" {
  $sync.Rows.Clear(); Pct 0 "Stick erstellen"
  $c = $sync.Choice; $src = $sync.ExtractDir
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  function SchreibeLF($pfad, $text) { [IO.File]::WriteAllText($pfad, ($text -replace "`r`n", "`n"), $utf8) }
  $disk = Get-Disk -Number $c.Disk
  $usb = $null
  if ($c.Mode -eq "neu") {
    # --- Stick-Test (Lesen/Schreiben) vor dem Löschen ist nicht möglich – deshalb nach dem Formatieren
    Row fmt spin "Schnellformatierung" "Stick wird gelöscht und neu eingeteilt"
    $disk | Set-Disk -IsReadOnly $false -ErrorAction SilentlyContinue
    if ($disk.PartitionStyle -ne "RAW") { $disk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false }
    $disk = Get-Disk -Number $c.Disk
    if ($disk.PartitionStyle -eq "RAW") { $disk | Initialize-Disk -PartitionStyle MBR }
    $bootSize = if ($c.ModelsOnStick) { [uint64]8GB } else { [uint64]([Math]::Min([double]$disk.Size - 16MB, [double]30GB)) }
    $p1 = New-Partition -DiskNumber $c.Disk -Size $bootSize -AssignDriveLetter -IsActive
    Start-Sleep -Seconds 2
    Format-Volume -Partition $p1 -FileSystem FAT32 -NewFileSystemLabel "BUTCHIESKI" -Confirm:$false | Out-Null
    if ($c.ModelsOnStick) {
      $p2 = New-Partition -DiskNumber $c.Disk -UseMaximumSize -AssignDriveLetter
      Start-Sleep -Seconds 2
      Format-Volume -Partition $p2 -FileSystem exFAT -NewFileSystemLabel "BKIMODELLE" -Confirm:$false | Out-Null
      $c.ModelDrive = "$((Get-Partition -DiskNumber $c.Disk -PartitionNumber $p2.PartitionNumber).DriveLetter):\"
    }
    $usb = "$((Get-Partition -DiskNumber $c.Disk -PartitionNumber $p1.PartitionNumber).DriveLetter):\"
    Row fmt ok "Schnellformatierung" "FAT32$(if ($c.ModelsOnStick) { ' + exFAT für KI-Modelle' }) · $usb"; Pct 5
  } else {
    $usb = $c.Letter
    Row fmt ok "Vorhandener Butchies-Stick" "wird nur abgeglichen, nicht gelöscht" $usb; Pct 5
  }
  # --- Stick-Test
  Row test spin "Stick-Test" "Schreiben und Lesen prüfen"
  $tf = Join-Path $usb "butchies-test.bin"
  $data = New-Object byte[] (32MB); (New-Object Random).NextBytes($data)
  [IO.File]::WriteAllBytes($tf, $data)
  $back = [IO.File]::ReadAllBytes($tf); Remove-Item $tf -Force
  $sha = [Security.Cryptography.SHA256]::Create()
  if ([BitConverter]::ToString($sha.ComputeHash($data)) -ne [BitConverter]::ToString($sha.ComputeHash($back))) { Row test bad "Stick-Test" "Gelesene Daten stimmen nicht – Stick defekt?"; throw "Stick-Test fehlgeschlagen" }
  Row test ok "Stick-Test" "32 MB geschrieben und fehlerfrei gelesen"; Pct 8
  # --- Ubuntu kopieren (bei Abgleich nur, wenn eine neuere ISO da ist)
  $needIso = $true
  if ($c.Mode -eq "abgleich" -and (Test-Path (Join-Path $usb "butchies\iso.txt"))) {
    $needIso = ((Get-Content (Join-Path $usb "butchies\iso.txt") -Raw).Trim() -ne $c.IsoName)
  }
  if ($needIso) {
    if ($c.Mode -eq "abgleich") { Get-ChildItem $usb -Force | Where-Object { $_.Name -notin @("butchies-protokoll", "System Volume Information") } | Remove-Item -Recurse -Force }
    Row iso spin "Ubuntu-Dateien kopieren" $c.IsoName
    $img = Mount-DiskImage -ImagePath $c.Iso -PassThru; Start-Sleep -Seconds 2
    $isoDrive = "$(($img | Get-Volume).DriveLetter):\"
    try {
      $files = @(Get-ChildItem -Path $isoDrive -Recurse -Force -File)
      $total = ($files | Measure-Object -Property Length -Sum).Sum; $done = 0
      foreach ($f in $files) {
        $dst = Join-Path $usb $f.FullName.Substring($isoDrive.Length)
        $d2 = Split-Path -Parent $dst; if (-not (Test-Path $d2)) { New-Item -ItemType Directory -Force -Path $d2 | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        $done += $f.Length
        Row iso spin "Ubuntu-Dateien kopieren" ("{0:N1} / {1:N1} GB" -f ($done / 1GB), ($total / 1GB)) ([IO.Path]::GetFileName($f.Name))
        Pct (8 + 62 * $done / $total) "Ubuntu auf den Stick kopieren"
      }
    } finally { Dismount-DiskImage -ImagePath $c.Iso | Out-Null }
    Get-ChildItem -Path $usb -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) } catch {} }
    $grub = Join-Path $usb "boot\grub\grub.cfg"
    $g = [IO.File]::ReadAllText($grub)
    $g = [regex]::Replace($g, 'set timeout=\d+', 'set timeout=5')
    $rx = New-Object Text.RegularExpressions.Regex('(linux\s+/casper/vmlinuz)(\s+)(---)')
    if (-not $rx.IsMatch($g)) { throw "Startzeile in grub.cfg nicht gefunden – unbekannte ISO-Version" }
    $g = $rx.Replace($g, '$1 autoinstall $3', 1)
    $g = $g.Replace('menuentry "Try or Install Ubuntu Server"', 'menuentry "Butchies KI Studio installieren (automatisch)"')
    SchreibeLF $grub $g
    Row iso ok "Ubuntu-Dateien kopieren" $c.IsoName
  } else { Row iso ok "Ubuntu-Dateien" "schon aktuell – nichts zu kopieren" $c.IsoName }
  Pct 72
  # --- Butchies-Dateien und Einstellungen
  Row bki spin "Automatische Installation einbauen" "Startmenü, Sicherheitsprüfung, Butchies-Dateien"
  $payload = Join-Path $usb "butchies"
  if (Test-Path $payload) { Remove-Item $payload -Recurse -Force }
  $textExt = @(".sh", ".py", ".yaml", ".yml", ".service", ".timer", ".html", ".js", ".css", ".json", ".md", ".txt")
  foreach ($sub in "installer", "server") {
    $von = Join-Path $src $sub
    Get-ChildItem -Path $von -Recurse -Force -File | ForEach-Object {
      $dst = Join-Path (Join-Path $payload $sub) $_.FullName.Substring($von.Length).TrimStart("\")
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
      if ($textExt -contains $_.Extension.ToLower()) { SchreibeLF $dst ([IO.File]::ReadAllText($_.FullName, $utf8)) }
      else { Copy-Item -LiteralPath $_.FullName -Destination $dst -Force }
    }
  }
  SchreibeLF (Join-Path $usb "autoinstall.yaml") ([IO.File]::ReadAllText((Join-Path $src "installer\autoinstall.yaml"), $utf8))
  function Q($s) { "'" + ($s -replace "'", "'\''") + "'" }
  $ids = ($c.Models | Where-Object { $_.id -notlike "custom*" } | ForEach-Object { $_.id }) -join ","
  $cfg = "# Butchies KI Studio – Einstellungen für die Installation`n# Das Passwort wird nach der Installation automatisch vom Stick gelöscht.`n" +
         "BKI_HOSTNAME=$(Q $c.Host)`nBKI_USERNAME=$(Q $c.User)`nBKI_PASSWORD=$(Q $c.Password)`n" +
         "BKI_MODELS=$(Q $ids)`nBKI_CUSTOM_MODELS=$(Q ($c.Custom -join ' '))`nBKI_EXTENSIONS=$(Q ($c.Extensions -join ','))`n"
  SchreibeLF (Join-Path $payload "config.env") $cfg
  $c.Password = $null
  SchreibeLF (Join-Path $payload "VERSION") ((Get-Content (Join-Path $src "VERSION") -Raw).Trim())
  SchreibeLF (Join-Path $payload "iso.txt") $c.IsoName
  Row bki ok "Automatische Installation einbauen" "Butchies $((Get-Content (Join-Path $src 'VERSION') -Raw).Trim()) · $($c.Host) · $($c.User)"; Pct 78
  # --- KI-Modelle auf den Stick
  if ($c.ModelsOnStick) {
    $md = if ($c.ModelDrive) { $c.ModelDrive } else { $d = Get-Volume -FileSystemLabel "BKIMODELLE" -ErrorAction SilentlyContinue; if ($d) { "$($d.DriveLetter):\" } }
    if (-not $md) { throw "Bereich BKIMODELLE auf dem Stick fehlt – bitte Stick neu erstellen statt abgleichen" }
    New-Item -ItemType Directory -Force -Path (Join-Path $md "models") | Out-Null
    $i = 0
    foreach ($m in $c.Models) {
      $i++
      if (-not $m.localfile) { continue }
      $dst = Join-Path $md ("models\" + [IO.Path]::GetFileName($m.localfile))
      if (-not (Test-Path $dst) -or (Get-Item $dst).Length -ne (Get-Item $m.localfile).Length) {
        Row "mc$i" spin "KI-Modell $($m.name) kopieren" ("{0:N1} GB" -f ((Get-Item $m.localfile).Length / 1GB))
        Copy-Item $m.localfile $dst -Force
        Copy-Item "$($m.localfile).json" "$dst.json" -Force
      }
      Row "mc$i" ok "KI-Modell $($m.name)" "liegt auf dem Stick"
      Pct (78 + 14 * $i / $c.Models.Count) "KI-Modelle kopieren"
    }
  }
  # --- Abschlussprüfung
  Row chk spin "Abschlussprüfung" "jede Datei auf dem Stick wird nachgelesen"
  $bad = 0
  foreach ($f in (Get-ChildItem (Join-Path $usb "butchies") -Recurse -File)) { try { [void][IO.File]::ReadAllBytes($f.FullName) } catch { $bad++ } }
  foreach ($must in "autoinstall.yaml", "boot\grub\grub.cfg", "casper\vmlinuz", "butchies\installer\early.sh", "butchies\config.env") { if (-not (Test-Path (Join-Path $usb $must))) { $bad++ } }
  if ($bad -gt 0) { Row chk bad "Abschlussprüfung" "$bad Datei(en) fehlerhaft"; throw "Abschlussprüfung fehlgeschlagen" }
  Row chk ok "Abschlussprüfung" "alle Dateien in Ordnung"
  Pct 100 "Stick ist fertig"
  $sync.Done = "create"; Ping
}

"follow" {
  # Installation des Mini-PCs live mitverfolgen
  $h = $sync.Choice.Host; if (-not $h) { $h = "butchies-ki" }
  $phase = "setup"
  while (-not $sync.StopFollow) {
    $t = $null
    try {
      if ($phase -eq "setup") {
        $t = (GetText "http://butchies-ki-setup.local/status.json") | ConvertFrom-Json
        $sync.Follow = @{ Phase = "Installation"; Percent = [int]$t.percent; Text = $t.text; State = $t.state }
        if ($t.state -eq "fertig" -or $t.percent -ge 99) { $phase = "ki" }
      } else {
        $t = (GetText "http://$h.local/api/state") | ConvertFrom-Json
        $j = $t.job
        if ($j.running) { $sync.Follow = @{ Phase = "Ersteinrichtung (KI laden)"; Percent = [int]$j.percent; Text = $j.text; State = "running" } }
        else { $sync.Follow = @{ Phase = "Fertig"; Percent = 100; Text = "Mini-PC ist bereit: http://$h.local"; State = "fertig" } }
      }
    } catch {
      if (-not $sync.Follow) { $sync.Follow = @{ Phase = "Warte auf Mini-PC"; Percent = 0; Text = "Mini-PC einschalten – er meldet sich hier, sobald die Installation läuft."; State = "wait" } }
      elseif ($phase -eq "ki" -and $sync.Follow.Phase -ne "Fertig") { $sync.Follow = @{ Phase = "Neustart"; Percent = 100; Text = "Mini-PC startet neu …"; State = "running" } }
    }
    Ping
    Start-Sleep -Seconds 3
  }
}
}
}

function Starte($task) {
  $sync.Busy = $true; $sync.Error = ""; $sync.Done = ""
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = "STA"; $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript({
    param($sync, $task, $code)
    try { & ([scriptblock]::Create($code)) $sync $task }
    catch { $sync.Error = $_.Exception.Message; [void]$sync.Log.Add("FEHLER: " + $_.Exception.Message) }
    finally { $sync.Busy = $false; $sync.Ver++ }
  }).AddArgument($sync).AddArgument($task).AddArgument($workerCode.ToString())
  [void]$ps.BeginInvoke()
}

# =====================================================================================
# Oberfläche (WPF, Windows-11-Stil hell)
# =====================================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Butchies KI Studio – Einrichtung" Width="900" Height="640" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        Background="#F3F3F3" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#1A1A1A">
  <Window.Resources>
    <SolidColorBrush x:Key="Acc" Color="#0067C0"/>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Height" Value="34"/><Setter Property="MinWidth" Value="110"/><Setter Property="Padding" Value="16,0"/>
      <Setter Property="Background" Value="#FBFBFB"/><Setter Property="BorderBrush" Value="#D1D1D1"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.86"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#0067C0"/><Setter Property="BorderBrush" Value="#0067C0"/><Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="TextBox"><Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,5"/><Setter Property="BorderBrush" Value="#D1D1D1"/><Setter Property="BorderThickness" Value="1,1,1,2"/></Style>
    <Style TargetType="PasswordBox"><Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,5"/><Setter Property="BorderBrush" Value="#D1D1D1"/><Setter Property="BorderThickness" Value="1,1,1,2"/></Style>
    <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#E5E5E5"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="8"/><Setter Property="Padding" Value="12,9"/></Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition/><RowDefinition Height="64"/></Grid.RowDefinitions>
    <Grid.ColumnDefinitions><ColumnDefinition Width="210"/><ColumnDefinition/></Grid.ColumnDefinitions>

    <!-- Kopfzeile -->
    <Border Grid.ColumnSpan="2" Background="#EEEEEE" BorderBrush="#E0E0E0" BorderThickness="0,0,0,1">
      <DockPanel Margin="16,0">
        <Border DockPanel.Dock="Right" x:Name="AutoPill" CornerRadius="14" Background="#E5F1FB" Padding="10,4" VerticalAlignment="Center" Cursor="Hand">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="AutoDot" Width="8" Height="8" Fill="#0067C0" Margin="0,0,8,0" VerticalAlignment="Center"/>
            <TextBlock Text="KI-Autopilot" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <CheckBox x:Name="AutoToggle" IsChecked="True" VerticalAlignment="Center" ToolTip="Ausschalten: Du machst jeden Schritt selbst"/>
          </StackPanel>
        </Border>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="24" Height="24" CornerRadius="6" Background="#0067C0"><TextBlock Text="KI" Foreground="White" FontWeight="Bold" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <TextBlock Text="Butchies KI Studio – Einrichtung" Margin="10,0,0,0" VerticalAlignment="Center" FontWeight="SemiBold"/>
          <TextBlock x:Name="VerText" Margin="10,0,0,0" VerticalAlignment="Center" Foreground="#5C5C5C"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Schritte links -->
    <Border Grid.Row="1" Background="#EBEBEB" BorderBrush="#E0E0E0" BorderThickness="0,0,1,0">
      <StackPanel x:Name="StepList" Margin="18,18,10,0"/>
    </Border>

    <!-- Seiten -->
    <Grid Grid.Row="1" Grid.Column="1" Margin="28,22,28,10">
      <!-- 1 Willkommen -->
      <StackPanel x:Name="PgWelcome" VerticalAlignment="Center" HorizontalAlignment="Center">
        <Grid Width="120" Height="120" HorizontalAlignment="Center">
          <Border x:Name="Logo" Width="96" Height="96" CornerRadius="26" Background="#0067C0">
            <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
            <Border.Effect><DropShadowEffect Color="#0067C0" BlurRadius="30" ShadowDepth="0" Opacity="0.5"/></Border.Effect>
            <TextBlock Text="KI" Foreground="White" FontSize="34" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Grid>
        <TextBlock Text="Willkommen bei Butchies KI Studio" FontSize="26" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,18,0,6"/>
        <TextBlock TextWrapping="Wrap" TextAlignment="Center" MaxWidth="460" Foreground="#5C5C5C" Text="Der Assistent richtet zuerst deinen Windows-PC ein und baut dann den USB-Stick für den Mini-PC – alles geprüft und auf dem neuesten Stand."/>
        <TextBlock x:Name="WelcomeInfo" HorizontalAlignment="Center" Margin="0,14,0,0" Foreground="#0F6B0F"/>
      </StackPanel>

      <!-- Allgemeine Fortschritts-Seite -->
      <DockPanel x:Name="PgRows" Visibility="Collapsed">
        <StackPanel DockPanel.Dock="Top">
          <TextBlock x:Name="RowsTitle" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock x:Name="RowsSub" Foreground="#5C5C5C" Margin="0,2,0,12" TextWrapping="Wrap"/>
          <Border x:Name="BigBox" Style="{StaticResource Card}" Margin="0,0,0,10" Visibility="Collapsed">
            <StackPanel>
              <DockPanel><TextBlock DockPanel.Dock="Right" x:Name="BigPct" FontSize="26" FontWeight="SemiBold" Foreground="#0067C0"/><TextBlock x:Name="BigText" FontWeight="SemiBold" VerticalAlignment="Center"/></DockPanel>
              <UniformGrid x:Name="Blocks" Columns="20" Height="12" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <Border DockPanel.Dock="Bottom" x:Name="KiCard" Background="#E5F1FB" BorderBrush="#B7D6F0" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,8,0,0">
          <DockPanel>
            <Button DockPanel.Dock="Right" x:Name="KiSelf" Content="Selbst machen" Style="{StaticResource Btn}" MinWidth="0" Height="28" VerticalAlignment="Top"/>
            <StackPanel><TextBlock Text="KI-Autopilot" FontWeight="SemiBold" Foreground="#003E73"/><TextBlock x:Name="KiText" TextWrapping="Wrap" Foreground="#3B3B3B"/></StackPanel>
          </DockPanel>
        </Border>
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="Rows"/></ScrollViewer>
      </DockPanel>

      <!-- 4 USB-Frage -->
      <StackPanel x:Name="PgUsb" Visibility="Collapsed">
        <TextBlock Text="Hast du schon einen Butchies-Stick?" FontSize="22" FontWeight="SemiBold"/>
        <TextBlock Foreground="#5C5C5C" Margin="0,2,0,14" TextWrapping="Wrap" Text="Auch ein vorhandener Stick wird eingesteckt – ich gleiche ihn mit den Neuerungen ab. Ein neuer Stick wird nur nach deiner Bestätigung gelöscht."/>
        <UniformGrid Columns="2">
          <RadioButton x:Name="RbHave" GroupName="u" Margin="0,0,6,0" Padding="10"><StackPanel><TextBlock Text="Ja – Stick abgleichen" FontSize="15" FontWeight="SemiBold"/><TextBlock TextWrapping="Wrap" Foreground="#5C5C5C" Text="Version, Ubuntu und Butchies-Dateien prüfen, nur Geändertes erneuern."/></StackPanel></RadioButton>
          <RadioButton x:Name="RbNew" GroupName="u" Margin="6,0,0,0" Padding="10" IsChecked="True"><StackPanel><TextBlock Text="Nein – neuen Stick erstellen" FontSize="15" FontWeight="SemiBold"/><TextBlock TextWrapping="Wrap" Foreground="#5C5C5C" Text="Stick mit mind. 4 GB (für KI-Modelle auf dem Stick: 32 GB)."/></StackPanel></RadioButton>
        </UniformGrid>
        <TextBlock Text="Gefundene USB-Sticks:" Margin="0,16,0,6" FontWeight="SemiBold"/>
        <ListBox x:Name="DiskList" Height="140" BorderBrush="#E5E5E5"/>
        <StackPanel Orientation="Horizontal" Margin="0,8,0,0"><Button x:Name="BtnRescan" Content="Neu suchen" Style="{StaticResource Btn}"/><TextBlock x:Name="UsbInfo" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#5C5C5C"/></StackPanel>
      </StackPanel>

      <!-- 5 KI-Auswahl -->
      <DockPanel x:Name="PgKi" Visibility="Collapsed">
        <StackPanel DockPanel.Dock="Top">
          <TextBlock Text="Welche KI soll drauf?" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock Foreground="#5C5C5C" Margin="0,2,0,6" Text="Du entscheidest. Mehrere gleichzeitig gehen – wechseln kannst du später jederzeit."/>
          <Border Background="#DFF6DD" CornerRadius="10" Padding="10,3" HorizontalAlignment="Left" Margin="0,0,0,8"><TextBlock x:Name="KiListInfo" Foreground="#0F6B0F" FontSize="12"/></Border>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <DockPanel Margin="0,6,0,6"><Button DockPanel.Dock="Right" x:Name="BtnCustom" Content="Hinzufügen" Style="{StaticResource Btn}" MinWidth="0" Margin="8,0,0,0"/><TextBox x:Name="CustomUrl" ToolTip="Hugging-Face-Link zu einer .gguf-Datei"/></DockPanel>
          <UniformGrid Columns="2">
            <RadioButton x:Name="RbLater" GroupName="m" IsChecked="True" Margin="0,0,6,0"><StackPanel><TextBlock Text="Mini-PC lädt selbst" FontWeight="SemiBold"/><TextBlock Foreground="#5C5C5C" Text="nach der Installation · Stick ab 4 GB"/></StackPanel></RadioButton>
            <RadioButton x:Name="RbStick" GroupName="m" Margin="6,0,0,0"><StackPanel><TextBlock Text="Gleich mit auf den Stick" FontWeight="SemiBold"/><TextBlock Foreground="#5C5C5C" Text="komplett offline · neuer Stick ab 32 GB"/></StackPanel></RadioButton>
          </UniformGrid>
          <TextBlock x:Name="KiSum" HorizontalAlignment="Right" Foreground="#5C5C5C" Margin="0,6,0,0"/>
        </StackPanel>
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="KiList"/></ScrollViewer>
      </DockPanel>

      <!-- 6 Zugangsdaten / Bestätigung -->
      <StackPanel x:Name="PgStick" Visibility="Collapsed">
        <TextBlock x:Name="StickTitle" FontSize="22" FontWeight="SemiBold"/>
        <TextBlock x:Name="StickSub" Foreground="#5C5C5C" Margin="0,2,0,12" TextWrapping="Wrap"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <StackPanel><TextBlock Text="Name im Heimnetz" Foreground="#5C5C5C" Margin="0,0,0,4"/><TextBox x:Name="TbHost" Text="butchies-ki"/></StackPanel>
          <StackPanel Grid.Column="2"><TextBlock Text="Benutzer (Linux/SSH)" Foreground="#5C5C5C" Margin="0,0,0,4"/><TextBox x:Name="TbUser" Text="butchies"/></StackPanel>
          <StackPanel Grid.Column="4"><TextBlock Text="Passwort (mind. 8 Zeichen)" Foreground="#5C5C5C" Margin="0,0,0,4"/><PasswordBox x:Name="Pw1"/></StackPanel>
        </Grid>
        <StackPanel Orientation="Horizontal" Margin="0,8,0,0"><TextBlock Text="Passwort wiederholen:" Foreground="#5C5C5C" VerticalAlignment="Center" Margin="0,0,8,0"/><PasswordBox x:Name="Pw2" Width="220"/></StackPanel>
        <Border x:Name="WarnBox" Margin="0,16,0,0" Background="#FDE7E9" BorderBrush="#F1BBBC" BorderThickness="1" CornerRadius="8" Padding="14,10">
          <StackPanel>
            <TextBlock x:Name="WarnTitle" FontWeight="SemiBold"/>
            <TextBlock Foreground="#5C2B2B" Text="Fotos, Dokumente und andere Daten auf diesem Stick gehen verloren." Margin="0,2,0,8"/>
            <CheckBox x:Name="CbConfirm" Content="Ich habe verstanden – Stick löschen"/>
          </StackPanel>
        </Border>
        <TextBlock x:Name="StickErr" Foreground="#C42B1C" Margin="0,10,0,0" TextWrapping="Wrap"/>
      </StackPanel>

      <!-- 9 Fertig -->
      <StackPanel x:Name="PgDone" Visibility="Collapsed">
        <StackPanel Orientation="Horizontal">
          <Grid Width="84" Height="84"><Ellipse Fill="#DFF6DD"/><Path Data="M 22,44 L 36,58 L 62,28" Stroke="#0F7B0F" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Grid>
          <StackPanel Margin="18,0,0,0" VerticalAlignment="Center"><TextBlock Text="Alles bereit!" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock TextWrapping="Wrap" MaxWidth="460" Foreground="#5C5C5C" Text="Windows ist eingerichtet und der Stick ist fertig und geprüft. Das Butchies-KI-Symbol sitzt unten rechts in der Taskleiste."/></StackPanel>
        </StackPanel>
        <Border Style="{StaticResource Card}" Margin="0,16,0,0"><TextBlock TextWrapping="Wrap" LineHeight="22" Text="1. Stick und LAN-Kabel in den Mini-PC stecken (SSD eingebaut und leer)&#x0a;2. Mini-PC einschalten – er installiert sich selbst&#x0a;3. Hier siehst du den Fortschritt live – das Fenster darf offen bleiben"/></Border>
        <Border Style="{StaticResource Card}" Margin="0,10,0,0">
          <StackPanel>
            <DockPanel><TextBlock DockPanel.Dock="Right" x:Name="FPct" FontSize="22" FontWeight="SemiBold" Foreground="#0067C0"/><TextBlock x:Name="FPhase" FontWeight="SemiBold" VerticalAlignment="Center" Text="Mini-PC live"/></DockPanel>
            <UniformGrid x:Name="FBlocks" Columns="20" Height="10" Margin="0,8,0,6"/>
            <TextBlock x:Name="FText" Foreground="#5C5C5C" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </Grid>

    <!-- Fußzeile -->
    <Border Grid.Row="2" Grid.ColumnSpan="2" Background="#EEEEEE" BorderBrush="#E0E0E0" BorderThickness="0,1,0,0">
      <DockPanel Margin="20,0">
        <TextBlock x:Name="ErrText" Foreground="#C42B1C" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="440"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="BtnLog" Content="Protokoll" Style="{StaticResource Btn}" MinWidth="0" Margin="0,0,8,0"/>
          <Button x:Name="BtnBack" Content="Zurück" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
          <Button x:Name="BtnNext" Content="Los geht's" Style="{StaticResource Primary}"/>
        </StackPanel>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$w = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in "AutoPill", "AutoDot", "AutoToggle", "VerText", "StepList", "PgWelcome", "Logo", "WelcomeInfo", "PgRows", "RowsTitle", "RowsSub", "BigBox", "BigPct", "BigText", "Blocks", "KiCard", "KiSelf", "KiText", "Rows",
  "PgUsb", "RbHave", "RbNew", "DiskList", "BtnRescan", "UsbInfo", "PgKi", "KiListInfo", "BtnCustom", "CustomUrl", "RbLater", "RbStick", "KiSum", "KiList",
  "PgStick", "StickTitle", "StickSub", "TbHost", "TbUser", "Pw1", "Pw2", "WarnBox", "WarnTitle", "CbConfirm", "StickErr", "PgDone", "FPct", "FPhase", "FBlocks", "FText",
  "ErrText", "BtnLog", "BtnBack", "BtnNext") { $ui[$n] = $w.FindName($n) }

function Brush($c) { (New-Object Windows.Media.BrushConverter).ConvertFromString($c) }
foreach ($g in $ui.Blocks, $ui.FBlocks) { for ($i = 0; $i -lt 20; $i++) { $r = New-Object Windows.Shapes.Rectangle; $r.Margin = "1.5,0"; $r.RadiusX = 2; $r.RadiusY = 2; $r.Fill = Brush "#D4D4D4"; [void]$g.Children.Add($r) } }
function SetBlocks($grid, $p) { $on = [Math]::Floor($p / 5); for ($i = 0; $i -lt 20; $i++) { $grid.Children[$i].Fill = if ($i -lt $on) { Brush "#0067C0" } else { Brush "#D4D4D4" } } }

# Logo schweben lassen
$fa = New-Object Windows.Media.Animation.DoubleAnimation(0, -8, [TimeSpan]::FromMilliseconds(1500))
$fa.AutoReverse = $true; $fa.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
$fa.EasingFunction = New-Object Windows.Media.Animation.SineEase
$ui.Logo.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $fa)

$Steps = @("Willkommen", "Systemprüfung", "Windows-Teil", "USB-Stick", "KI-Auswahl", "Zugangsdaten", "Online-Prüfung", "Stick erstellen", "Fertig")
$script:step = 0
$script:selfMode = @{}

function ZeigeSchritte {
  $ui.StepList.Children.Clear()
  for ($i = 0; $i -lt $Steps.Count; $i++) {
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = "Horizontal"; $sp.Margin = "0,0,0,12"
    $b = New-Object Windows.Controls.Border; $b.Width = 24; $b.Height = 24; $b.CornerRadius = 12
    $t = New-Object Windows.Controls.TextBlock; $t.HorizontalAlignment = "Center"; $t.VerticalAlignment = "Center"; $t.FontSize = 11
    if ($i -lt $script:step) { $b.Background = Brush "#DFF6DD"; $t.Text = [string][char]0x2713; $t.Foreground = Brush "#0F7B0F"; $t.FontWeight = "Bold" }
    elseif ($i -eq $script:step) { $b.Background = Brush "#0067C0"; $t.Text = "$($i + 1)"; $t.Foreground = Brush "White"; $t.FontWeight = "Bold"
      $b.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = [Windows.Media.Color]::FromRgb(0, 103, 192); BlurRadius = 12; ShadowDepth = 0; Opacity = 0.6 } }
    else { $b.BorderBrush = Brush "#C4C4C4"; $b.BorderThickness = 1; $t.Text = "$($i + 1)"; $t.Foreground = Brush "#5C5C5C" }
    $b.Child = $t
    $l = New-Object Windows.Controls.TextBlock; $l.Text = $Steps[$i]; $l.Margin = "10,0,0,0"; $l.VerticalAlignment = "Center"
    if ($i -eq $script:step) { $l.FontWeight = "SemiBold" } else { $l.Foreground = Brush "#5C5C5C" }
    [void]$sp.Children.Add($b); [void]$sp.Children.Add($l); [void]$ui.StepList.Children.Add($sp)
  }
}

function Seite($name) {
  foreach ($p in "PgWelcome", "PgRows", "PgUsb", "PgKi", "PgStick", "PgDone") { $ui[$p].Visibility = if ($p -eq $name) { "Visible" } else { "Collapsed" } }
  $fade = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(350))
  $ui[$name].BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
  ZeigeSchritte
}
function RowsSeite($title, $sub, $ki, $big) {
  $sync.Rows.Clear(); $sync.Percent = -1; $ui.Rows.Children.Clear()
  $ui.RowsTitle.Text = $title; $ui.RowsSub.Text = $sub; $ui.KiText.Text = $ki
  $ui.BigBox.Visibility = if ($big) { "Visible" } else { "Collapsed" }
  $ui.KiCard.Visibility = if ($sync.Autopilot) { "Visible" } else { "Collapsed" }
  Seite "PgRows"
}

# --- Zeilen zeichnen (mit drehendem Kreis, Häkchen, Einblenden) ---------------------
$script:rowCache = @{}
function ZeichneZeilen {
  foreach ($r in @($sync.Rows)) {
    $key = $r.Key
    if (-not $script:rowCache.ContainsKey($key)) {
      $card = New-Object Windows.Controls.Border; $card.Style = $w.Resources["Card"]; $card.Margin = "0,0,0,6"
      $dp = New-Object Windows.Controls.DockPanel
      $icon = New-Object Windows.Controls.Grid; $icon.Width = 20; $icon.Height = 20; $icon.Margin = "0,0,12,0"; [Windows.Controls.DockPanel]::SetDock($icon, "Left")
      $right = New-Object Windows.Controls.TextBlock; $right.Foreground = Brush "#5C5C5C"; $right.VerticalAlignment = "Center"; $right.Margin = "10,0,0,0"; [Windows.Controls.DockPanel]::SetDock($right, "Right")
      $sp = New-Object Windows.Controls.StackPanel
      $t1 = New-Object Windows.Controls.TextBlock; $t2 = New-Object Windows.Controls.TextBlock; $t2.Foreground = Brush "#5C5C5C"; $t2.FontSize = 12; $t2.TextTrimming = "CharacterEllipsis"
      [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
      [void]$dp.Children.Add($icon); [void]$dp.Children.Add($right); [void]$dp.Children.Add($sp)
      $card.Child = $dp
      $tt = New-Object Windows.Media.TranslateTransform 0, 10; $card.RenderTransform = $tt; $card.Opacity = 0
      [void]$ui.Rows.Children.Add($card)
      $card.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(400))))
      $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Object Windows.Media.Animation.DoubleAnimation(10, 0, [TimeSpan]::FromMilliseconds(400))))
      $script:rowCache[$key] = @{ Icon = $icon; T1 = $t1; T2 = $t2; Right = $right; State = "" }
    }
    $c = $script:rowCache[$key]
    $c.T1.Text = $r.Title; $c.T2.Text = $r.Sub; $c.T2.Visibility = if ($r.Sub) { "Visible" } else { "Collapsed" }; $c.Right.Text = $r.Right
    if ($c.State -ne $r.State) {
      $c.State = $r.State; $c.Icon.Children.Clear()
      switch ($r.State) {
        "spin" {
          $e = New-Object Windows.Shapes.Ellipse; $e.Width = 16; $e.Height = 16; $e.StrokeThickness = 2.5
          $e.Stroke = Brush "#D4D4D4"; [void]$c.Icon.Children.Add($e)
          $a = New-Object Windows.Shapes.Path; $a.Data = [Windows.Media.Geometry]::Parse("M 10,2 A 8,8 0 0 1 18,10"); $a.Stroke = Brush "#0067C0"; $a.StrokeThickness = 2.5; $a.Width = 20; $a.Height = 20
          $rt = New-Object Windows.Media.RotateTransform 0, 10, 10; $a.RenderTransform = $rt
          $rt.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 360, [TimeSpan]::FromMilliseconds(900)) -Property @{ RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever }))
          [void]$c.Icon.Children.Add($a)
        }
        "ok" {
          $p = New-Object Windows.Shapes.Path; $p.Data = [Windows.Media.Geometry]::Parse("M 4,10.5 L 8.5,15 L 16,6"); $p.Stroke = Brush "#0F7B0F"; $p.StrokeThickness = 2.5; $p.StrokeStartLineCap = "Round"; $p.StrokeEndLineCap = "Round"
          $st = New-Object Windows.Media.ScaleTransform 0.3, 0.3, 10, 10; $p.RenderTransform = $st
          $an = New-Object Windows.Media.Animation.DoubleAnimation(0.3, 1, [TimeSpan]::FromMilliseconds(350)); $an.EasingFunction = New-Object Windows.Media.Animation.BackEase
          $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $an); $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $an)
          [void]$c.Icon.Children.Add($p)
        }
        "info" { $t = New-Object Windows.Controls.TextBlock; $t.Text = "!"; $t.FontWeight = "Bold"; $t.Foreground = Brush "#9D5D00"; $t.HorizontalAlignment = "Center"; [void]$c.Icon.Children.Add($t) }
        "bad" { $t = New-Object Windows.Controls.TextBlock; $t.Text = [string][char]0x2715; $t.FontWeight = "Bold"; $t.Foreground = Brush "#C42B1C"; $t.HorizontalAlignment = "Center"; [void]$c.Icon.Children.Add($t) }
        default { $e = New-Object Windows.Shapes.Ellipse; $e.Width = 16; $e.Height = 16; $e.Stroke = Brush "#C4C4C4"; $e.StrokeThickness = 2; [void]$c.Icon.Children.Add($e) }
      }
    }
  }
}

# --- KI-Auswahl-Liste ---------------------------------------------------------------
$script:kiChecks = @(); $script:custom = New-Object Collections.ArrayList
function ZeigeKiListe {
  $ui.KiList.Children.Clear(); $script:kiChecks = @()
  $cat = $sync.Catalog
  if (-not $cat) { $ui.KiListInfo.Text = "Katalog nicht erreichbar – bitte Internet prüfen"; return }
  $live = @($cat.models | Where-Object { $_.ok -ne $null }).Count
  $ui.KiListInfo.Text = "Liste aktualisiert ($($cat.updated)) · Quelle: GitHub-Katalog" + $(if ($live) { " + Hugging Face (Größen live geprüft)" } else { " · Größen werden geprüft …" })
  $items = @(); foreach ($m in $cat.models) { $items += @{ Kind = "model"; Obj = $m } }; foreach ($e in $cat.extensions) { $items += @{ Kind = "ext"; Obj = $e } }
  foreach ($u in $script:custom) { $items += @{ Kind = "custom"; Obj = [pscustomobject]@{ id = "custom"; name = [IO.Path]::GetFileName($u); desc = "Eigenes Modell"; size_gb = 0; url = $u } } }
  foreach ($it in $items) {
    $o = $it.Obj
    $cb = New-Object Windows.Controls.CheckBox; $cb.Margin = "0,0,0,6"; $cb.Padding = "8,0,0,0"; $cb.Tag = $it
    $grid = New-Object Windows.Controls.DockPanel; $grid.Width = 560
    $size = if ($o.live_gb) { $o.live_gb } else { $o.size_gb }
    $right = New-Object Windows.Controls.TextBlock; $right.Text = $(if ($size) { "{0:N1} GB" -f $size } else { "" }); $right.Foreground = Brush "#5C5C5C"; [Windows.Controls.DockPanel]::SetDock($right, "Right")
    $sp = New-Object Windows.Controls.StackPanel
    $t1 = New-Object Windows.Controls.TextBlock; $t1.FontWeight = "SemiBold"; $t1.Text = $o.name + $(if ($it.Kind -eq "ext") { "  · Erweiterung" } else { "" }) + $(if ($o.default) { "  · Empfehlung" } else { "" }) + $(if ($o.ok -eq $false) { "  · zurzeit nicht verfügbar" } else { "" })
    $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = $o.desc; $t2.Foreground = Brush "#5C5C5C"; $t2.FontSize = 12
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2); [void]$grid.Children.Add($right); [void]$grid.Children.Add($sp)
    $cb.Content = $grid
    if ($sync.Choice.ContainsKey("Picked")) { $cb.IsChecked = $sync.Choice.Picked -contains ("$($it.Kind):$($o.id):$($o.url)") }
    elseif ($sync.Autopilot) { $cb.IsChecked = [bool]$o.default -or $it.Kind -eq "custom" }
    if ($o.ok -eq $false) { $cb.IsEnabled = $false; $cb.IsChecked = $false }
    $cb.Add_Click({ SummeKi })
    [void]$ui.KiList.Children.Add($cb); $script:kiChecks += $cb
  }
  SummeKi
}
function SummeKi {
  $sum = 0.0; foreach ($cb in $script:kiChecks) { if ($cb.IsChecked) { $o = $cb.Tag.Obj; $sum += [double]$(if ($o.live_gb) { $o.live_gb } else { $o.size_gb }) } }
  $ui.KiSum.Text = ("Ausgewählt: {0:N1} GB" -f $sum) + $(if ($sync.Autopilot) { " · Vorschlag vom KI-Autopiloten – entscheiden tust du" } else { "" })
}
$ui.BtnCustom.Add_Click({
  $u = $ui.CustomUrl.Text.Trim()
  if ($u -match '^https://huggingface\.co/[\w.\-]+/[\w.\-]+/(resolve|blob)/[\w.\-]+/.+\.gguf$') { [void]$script:custom.Add(($u -replace '/blob/', '/resolve/')); $ui.CustomUrl.Text = ""; ZeigeKiListe }
  else { [Windows.MessageBox]::Show("Bitte einen Hugging-Face-Link zu einer .gguf-Datei einfügen, z. B.`nhttps://huggingface.co/<name>/<repo>/resolve/main/<datei>.gguf", "Eigenes Modell") | Out-Null }
})

# --- USB-Liste ----------------------------------------------------------------------
function ZeigeDisks {
  $keep = if ($ui.DiskList.SelectedItem) { $ui.DiskList.SelectedItem.Tag.Number } else { $null }
  $ui.DiskList.Items.Clear()
  foreach ($d in $sync.Disks) {
    $txt = "{0}  –  {1:N1} GB  {2}" -f $d.Name, ($d.Size / 1GB), $(if ($d.Butchies) { "· Butchies-Stick, Version $($d.Version) ($($d.Letter))" } elseif ($d.Letter) { "($($d.Letter))" } else { "" })
    $it = New-Object Windows.Controls.ListBoxItem; $it.Content = $txt; $it.Tag = $d; $it.Padding = "8,6"
    [void]$ui.DiskList.Items.Add($it)
    if ($keep -ne $null -and $d.Number -eq $keep) { $it.IsSelected = $true }
  }
  $bk = @($sync.Disks | Where-Object { $_.Butchies })
  if ($sync.Disks.Count -eq 0) { $ui.UsbInfo.Text = "Kein USB-Stick gefunden – bitte einstecken (wird alle 3 s gesucht)." }
  else { $ui.UsbInfo.Text = "$($sync.Disks.Count) Stick(s) gefunden" + $(if ($bk.Count) { " · davon $($bk.Count) Butchies-Stick" } else { "" }) }
  if ($sync.Autopilot -and $ui.DiskList.SelectedIndex -lt 0 -and $ui.DiskList.Items.Count -gt 0) {
    $pick = 0; for ($i = 0; $i -lt $ui.DiskList.Items.Count; $i++) { if ($ui.DiskList.Items[$i].Tag.Butchies) { $pick = $i } }
    $ui.DiskList.SelectedIndex = $pick
    if ($bk.Count) { $ui.RbHave.IsChecked = $true } else { $ui.RbNew.IsChecked = $true }
  }
}
$ui.BtnRescan.Add_Click({ if (-not $sync.Busy) { Starte "scan" } })

# --- Ablauf -------------------------------------------------------------------------
function Fehler($t) { $ui.ErrText.Text = $t }
function GeheZu($n) {
  $script:step = $n; Fehler ""; $script:rowCache = @{}; $sync.Done = ""
  $ui.BtnBack.IsEnabled = $n -gt 0 -and $n -ne 2 -and $n -lt 7
  switch ($n) {
    0 { Seite "PgWelcome"; $ui.BtnNext.Content = "Los geht's" }
    1 { RowsSeite "Systemprüfung" "Ich schaue nach, ob Windows alles hat, was gebraucht wird." "Fehlt etwas Wichtiges, sage ich dir genau, was zu tun ist. Ist alles da, geht es von selbst weiter." $false; $ui.BtnNext.Content = "Weiter"; Starte "system" }
    2 { RowsSeite "Windows-Teil wird installiert" "Taskleisten-Programm, Verknüpfungen, Autostart und Deinstallations-Eintrag." "Ich hole vorher die neueste Version von GitHub und richte alles für deinen PC ein." $true; $script:winStage = "payload"; Starte "payload" }
    3 { Seite "PgUsb"; $ui.BtnNext.Content = "Weiter"; Starte "scan" }
    4 { Seite "PgKi"; ZeigeKiListe; if (-not $script:sizesStarted) { $script:sizesStarted = $true; Starte "catalogsizes" } }
    5 {
      Seite "PgStick"; $d = $sync.Choice.DiskInfo
      if ($sync.Choice.Mode -eq "neu") {
        $ui.StickTitle.Text = "Neuen Stick erstellen"; $ui.StickSub.Text = "Lege die Zugangsdaten für den Mini-PC fest."
        $ui.WarnBox.Visibility = "Visible"; $ui.WarnTitle.Text = ("Alles auf »{0}« ({1:N1} GB) wird gelöscht" -f $d.Name, ($d.Size / 1GB)); $ui.CbConfirm.IsChecked = $false
      } else {
        $ui.StickTitle.Text = "Stick abgleichen – $($d.Name) ($($d.Letter))"
        $ui.StickSub.Text = "Auf dem Stick: $($d.Version) · neueste: $($sync.Latest). Das Passwort wird nach jeder Installation vom Stick gelöscht – bitte neu eingeben."
        $ui.WarnBox.Visibility = "Collapsed"
      }
    }
    6 { RowsSeite "Alles auf dem neuesten Stand?" "Bevor der Stick gebaut wird, prüfe ich jede Quelle und lade nur, was fehlt." "Ich suche die neuesten Versionen, prüfe Prüfsummen und wiederhole abgebrochene Downloads selbst. Einmal geladene Dateien merke ich mir (Offline-Modus)." $true; Starte "online" }
    7 { RowsSeite "Stick wird erstellt" "Bitte den Stick nicht abziehen." "Geht etwas schief, versuche ich es automatisch erneut und zeige dir genau, woran es lag." $true; Starte "create" }
    8 { Seite "PgDone"; $ui.BtnNext.Content = "Fertig"; $ui.BtnBack.IsEnabled = $false; $sync.StopFollow = $false; Starte "follow" }
  }
  $ui.BtnNext.IsEnabled = $n -in 0, 3, 4, 5, 8
}

$ui.BtnNext.Add_Click({
  switch ($script:step) {
    0 { GeheZu 1 }
    1 { GeheZu 2 }
    2 { GeheZu 3 }
    3 {
      $sel = $ui.DiskList.SelectedItem
      if (-not $sel) { Fehler "Bitte einen USB-Stick auswählen."; return }
      $d = $sel.Tag
      if ($ui.RbHave.IsChecked -and -not $d.Butchies) { Fehler "Auf diesem Stick ist kein Butchies-Stick – wähle »Nein – neuen Stick erstellen«."; return }
      $sync.Choice.Mode = if ($ui.RbHave.IsChecked) { "abgleich" } else { "neu" }
      $sync.Choice.Disk = $d.Number; $sync.Choice.DiskInfo = $d; $sync.Choice.Letter = $d.Letter
      GeheZu 4
    }
    4 {
      $models = @(); $exts = @(); $custom = @(); $picked = @()
      foreach ($cb in $script:kiChecks) {
        if (-not $cb.IsChecked) { continue }
        $it = $cb.Tag; $picked += "$($it.Kind):$($it.Obj.id):$($it.Obj.url)"
        switch ($it.Kind) { "model" { $models += $it.Obj } "ext" { $exts += $it.Obj.id } "custom" { $custom += $it.Obj.url } }
      }
      if ($models.Count -eq 0 -and $custom.Count -eq 0) { Fehler "Bitte mindestens ein KI-Modell auswählen."; return }
      $stick = [bool]$ui.RbStick.IsChecked
      if ($stick) {
        $need = 8 + ($models | ForEach-Object { if ($_.live_gb) { $_.live_gb } else { $_.size_gb } } | Measure-Object -Sum).Sum
        $d = $sync.Choice.DiskInfo
        if ($sync.Choice.Mode -eq "neu" -and $d.Size / 1e9 -lt $need) { Fehler ("Für Modelle auf dem Stick braucht er ca. {0:N0} GB – dieser hat {1:N0} GB." -f $need, ($d.Size / 1e9)); return }
        if ($sync.Choice.Mode -eq "abgleich" -and -not $d.Models) { Fehler "Dieser Stick hat keinen Bereich für Modelle – dafür bitte einen neuen Stick erstellen."; return }
        if ($custom.Count) { Fehler "Eigene Modelle lädt der Mini-PC selbst – sie kommen nicht auf den Stick."; }
      }
      $sync.Choice.Models = $models; $sync.Choice.Extensions = $exts; $sync.Choice.Custom = $custom; $sync.Choice.ModelsOnStick = $stick; $sync.Choice.Picked = $picked
      GeheZu 5
    }
    5 {
      $h = $ui.TbHost.Text.Trim().ToLower(); $u = $ui.TbUser.Text.Trim().ToLower()
      if ($h -notmatch '^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$') { $ui.StickErr.Text = "Name: nur Kleinbuchstaben, Ziffern und Bindestrich (max. 30)."; return }
      if ($u -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $u -in @("root", "admin", "ubuntu")) { $ui.StickErr.Text = "Benutzer: nur Kleinbuchstaben/Ziffern/_/-, nicht root/admin/ubuntu."; return }
      if ($ui.Pw1.Password.Length -lt 8 -or $ui.Pw1.Password -cne $ui.Pw2.Password -or $ui.Pw1.Password -match "[\r\n]") { $ui.StickErr.Text = "Passwörter zu kurz oder nicht gleich."; return }
      if ($sync.Choice.Mode -eq "neu" -and -not $ui.CbConfirm.IsChecked) { $ui.StickErr.Text = "Bitte bestätigen, dass der Stick gelöscht werden darf."; return }
      $ui.StickErr.Text = ""
      $sync.Choice.Host = $h; $sync.Choice.User = $u; $sync.Choice.Password = $ui.Pw1.Password
      $ui.Pw1.Clear(); $ui.Pw2.Clear()
      $tc = Join-Path $Home2 "taskleiste.json"; @{ host = $h; mac = ""; ip = "" } | ConvertTo-Json | Set-Content $tc -Encoding UTF8
      # Taskleisten-Programm auf den gewählten Namen umstellen
      Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'Butchies-KI\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      $tp = Join-Path $Home2 "Butchies-KI.ps1"
      if (Test-Path $tp) { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tp`" -MiniPC $h" }
      GeheZu 6
    }
    6 { GeheZu 7 }
    7 { GeheZu 8 }
    8 { $sync.StopFollow = $true; $w.Close() }
  }
})
$ui.BtnBack.Add_Click({ if ($script:step -gt 0 -and -not $sync.Busy) { GeheZu ($script:step - 1) } })
$ui.BtnLog.Add_Click({
  $f = Join-Path $Home2 "setup-protokoll.txt"
  ($sync.Log -join "`r`n") | Set-Content $f -Encoding UTF8
  Start-Process notepad.exe $f
})
$ui.AutoToggle.Add_Click({
  $sync.Autopilot = [bool]$ui.AutoToggle.IsChecked
  $ui.AutoPill.Background = Brush $(if ($sync.Autopilot) { "#E5F1FB" } else { "#E5E5E5" })
  $ui.AutoDot.Fill = Brush $(if ($sync.Autopilot) { "#0067C0" } else { "#8A8A8A" })
  $ui.KiCard.Visibility = if ($sync.Autopilot -and $ui.PgRows.Visibility -eq "Visible") { "Visible" } else { "Collapsed" }
})
$ui.KiSelf.Add_Click({ $script:selfMode[$script:step] = $true; $ui.KiCard.Visibility = "Collapsed" })
function AutoWeiter { $sync.Autopilot -and -not $script:selfMode[$script:step] }

# --- Zeitgeber: Fortschritt anzeigen und Abläufe weiterschalten ---------------------
$script:lastVer = -1; $script:lastScan = Get-Date
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
  if ($script:step -eq 3 -and -not $sync.Busy -and ((Get-Date) - $script:lastScan).TotalSeconds -gt 3) { $script:lastScan = Get-Date; Starte "scan" }
  if ($sync.Ver -eq $script:lastVer) { return }
  $script:lastVer = $sync.Ver
  if ($ui.PgRows.Visibility -eq "Visible") {
    ZeichneZeilen
    if ($sync.Percent -ge 0) { $ui.BigPct.Text = "$($sync.Percent) %"; $ui.BigText.Text = $sync.PercentText; SetBlocks $ui.Blocks $sync.Percent }
  }
  if ($sync.Error) { Fehler ("Fehler: " + $sync.Error + "  – »Zurück« und erneut versuchen, oder »Protokoll« ansehen."); $ui.BtnBack.IsEnabled = $true }
  switch ($sync.Done) {
    "start" {
      $sync.Done = ""
      $ui.VerText.Text = "Setup $SetupVersion"
      if ($sync.Latest) { $ui.WelcomeInfo.Text = "Neueste Butchies-Version auf GitHub: $($sync.Latest) – wird automatisch verwendet" }
      else { $ui.WelcomeInfo.Text = "GitHub gerade nicht erreichbar – Offline-Modus mit gespeicherten Dateien" }
    }
    "system-ok" { $sync.Done = ""; $ui.BtnNext.IsEnabled = $true; if (AutoWeiter) { GeheZu 2 } }
    "system-fail" { $sync.Done = ""; Fehler "Bitte die rot markierten Punkte beheben und mit »Zurück« erneut prüfen." }
    "payload" { $sync.Done = ""; if ($sync.ExtractDir) { Starte "windows" } }
    "windows" { $sync.Done = ""; $ui.BtnNext.IsEnabled = $true; if (AutoWeiter) { GeheZu 3 } }
    "scan" { $sync.Done = ""; ZeigeDisks }
    "catalogsizes" { $sync.Done = ""; if ($script:step -eq 4) { ZeigeKiListe } }
    "online" { $sync.Done = ""; $ui.BtnNext.IsEnabled = $true; if (AutoWeiter) { GeheZu 7 } }
    "create" { $sync.Done = ""; $ui.BtnNext.IsEnabled = $true; $ui.BtnNext.Content = "Weiter"; if (AutoWeiter) { GeheZu 8 } }
  }
  if ($script:step -eq 8 -and $sync.Follow) {
    $f = $sync.Follow
    $ui.FPhase.Text = "Mini-PC: $($f.Phase)"; $ui.FPct.Text = "$($f.Percent) %"; $ui.FText.Text = $f.Text; SetBlocks $ui.FBlocks $f.Percent
  }
})
$timer.Start()

$w.Add_Closing({ $sync.StopFollow = $true })
GeheZu 0
Starte "start"
[void]$w.ShowDialog()
