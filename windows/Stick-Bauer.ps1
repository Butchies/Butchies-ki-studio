<#
  Butchies KI Studio – Stick-Bauer
  Baut einen USB-Stick, der den Mini-PC vollautomatisch mit Ubuntu Server 24.04
  und Butchies KI Studio einrichtet.

  Start: Doppelklick auf "Stick-Bauer.bat" (fragt nach Administratorrechten).
  Optional: -IsoPfad "D:\ubuntu-24.04.x-live-server-amd64.iso" (spart den Download)
#>
param(
  [string]$IsoPfad = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Host.UI.RawUI.WindowTitle = "Butchies KI Studio – Stick-Bauer"

$Root = Split-Path -Parent $PSScriptRoot          # Projektordner
$Downloads = Join-Path $PSScriptRoot "downloads"
$ReleaseUrl = "https://releases.ubuntu.com/24.04/"

function Titel($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Yellow }
function Info($t)  { Write-Host "   $t" }
function Fehler($t) { Write-Host ""; Write-Host "FEHLER: $t" -ForegroundColor Red; Read-Host "Enter zum Beenden"; exit 1 }

# Fortschritt in Prozent, eine Zeile alle 5 % (als Ladebalken)
$script:LastStep = -5
function Fortschritt([double]$prozent, [string]$text) {
  $p = [Math]::Max(0, [Math]::Min(100, [int][Math]::Floor($prozent)))
  $step = [int]([Math]::Floor($p / 5) * 5)
  if ($step -ge $script:LastStep + 5) {
    $script:LastStep = $step
    $bar = ("#" * ($step / 5)).PadRight(20, "-")
    Write-Host ("   [{0}] {1,3} %  {2}" -f $bar, $step, $text)
  }
}
function FortschrittNeu { $script:LastStep = -5 }

# --- Administratorrechte ---------------------------------------------------
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Fehler "Bitte über Stick-Bauer.bat starten (Administratorrechte nötig)." }

foreach ($d in @("installer", "server")) {
  if (-not (Test-Path (Join-Path $Root $d))) { Fehler "Ordner '$d' fehlt neben dem windows-Ordner. Bitte das ganze Paket entpacken." }
}

Clear-Host
Write-Host "  Butchies KI Studio – Stick-Bauer" -ForegroundColor Yellow
Write-Host "  Baut einen Stick, der deinen Mini-PC vollautomatisch einrichtet."
Write-Host ""

# --- 1. Angaben ---------------------------------------------------------------
Titel "1/5  Angaben"
do {
  $hostname = Read-Host "   Name des Mini-PCs im Heimnetz [butchies-ki]"
  if ([string]::IsNullOrWhiteSpace($hostname)) { $hostname = "butchies-ki" }
  $hostname = $hostname.Trim().ToLower()
  $ok = $hostname -match '^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'
  if (-not $ok) { Info "Nur Kleinbuchstaben, Ziffern und Bindestrich (max. 30 Zeichen)." }
} until ($ok)

do {
  $username = Read-Host "   Benutzername für Linux/SSH [butchies]"
  if ([string]::IsNullOrWhiteSpace($username)) { $username = "butchies" }
  $username = $username.Trim().ToLower()
  $ok = ($username -match '^[a-z_][a-z0-9_-]{0,31}$') -and ($username -notin @("root", "admin", "ubuntu"))
  if (-not $ok) { Info "Nur Kleinbuchstaben/Ziffern/_/-, nicht root/admin/ubuntu." }
} until ($ok)

function Klartext($sec) {
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
do {
  $pw1 = Klartext (Read-Host "   Passwort für Linux/SSH (mind. 8 Zeichen)" -AsSecureString)
  $pw2 = Klartext (Read-Host "   Passwort wiederholen" -AsSecureString)
  $ok = ($pw1.Length -ge 8) -and ($pw1 -ceq $pw2) -and ($pw1 -notmatch "[\r\n]")
  if (-not $ok) { Info "Passwörter unterschiedlich oder zu kurz – nochmal." }
} until ($ok)

# --- 2. Ubuntu-ISO ----------------------------------------------------------------
Titel "2/5  Ubuntu Server 24.04 LTS"
New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromHours(3)
$http.DefaultRequestHeaders.UserAgent.ParseAdd("ButchiesKIStickBauer/0.1")

$isoName = $null; $isoHash = $null
if ($IsoPfad) {
  if (-not (Test-Path $IsoPfad)) { Fehler "ISO nicht gefunden: $IsoPfad" }
  $iso = (Resolve-Path $IsoPfad).Path
  Info "Benutze vorhandene ISO: $iso (ohne Prüfsumme)"
} else {
  Info "Suche aktuelle Version auf releases.ubuntu.com …"
  try { $sums = $http.GetStringAsync($ReleaseUrl + "SHA256SUMS").Result }
  catch { Fehler "Keine Verbindung zu releases.ubuntu.com. Internet prüfen oder -IsoPfad angeben." }
  $best = $null
  foreach ($line in ($sums -split "`n")) {
    if ($line -match '^([0-9a-f]{64}) \*?(ubuntu-24\.04(\.\d+)?-live-server-amd64\.iso)\s*$') {
      if (-not $best -or $Matches[2] -gt $best[1]) { $best = @($Matches[1], $Matches[2]) }
    }
  }
  if (-not $best) { Fehler "Keine passende ISO in SHA256SUMS gefunden." }
  $isoHash, $isoName = $best
  $iso = Join-Path $Downloads $isoName
  Info "Version: $isoName"

  $needDownload = $true
  if (Test-Path $iso) {
    Info "ISO schon vorhanden – prüfe Prüfsumme …"
    if ((Get-FileHash $iso -Algorithm SHA256).Hash.ToLower() -eq $isoHash) { $needDownload = $false; Info "Prüfsumme stimmt ✓" }
  }
  if ($needDownload) {
    Info "Lade ISO herunter (ca. 3 GB) …"
    FortschrittNeu
    $resp = $http.GetAsync($ReleaseUrl + $isoName, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    if (-not $resp.IsSuccessStatusCode) { Fehler "Download fehlgeschlagen: $($resp.StatusCode)" }
    $total = [double]$resp.Content.Headers.ContentLength
    $in = $resp.Content.ReadAsStreamAsync().Result
    $out = [IO.File]::Create($iso + ".part")
    $buf = New-Object byte[] (4MB); $done = 0
    try {
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
        $out.Write($buf, 0, $n); $done += $n
        if ($total -gt 0) { Fortschritt (100 * $done / $total) ("{0:N1} / {1:N1} GB" -f ($done / 1GB), ($total / 1GB)) }
      }
    } finally { $out.Close(); $in.Close() }
    Move-Item -Force ($iso + ".part") $iso
    Info "Prüfe Prüfsumme …"
    if ((Get-FileHash $iso -Algorithm SHA256).Hash.ToLower() -ne $isoHash) {
      Remove-Item $iso -Force
      Fehler "Prüfsumme falsch – Download beschädigt. Bitte erneut starten."
    }
    Info "Prüfsumme stimmt ✓"
  }
}

# --- 3. USB-Stick wählen ---------------------------------------------------------
Titel "3/5  USB-Stick auswählen"
$disks = @(Get-Disk | Where-Object { $_.BusType -eq "USB" -and $_.Size -ge 4GB })
if ($disks.Count -eq 0) { Fehler "Kein USB-Stick (mind. 4 GB) gefunden. Stick einstecken und neu starten." }
foreach ($d in $disks) {
  Info ("[{0}]  {1}  –  {2:N1} GB" -f $d.Number, $d.FriendlyName, ($d.Size / 1GB))
}
do {
  $sel = Read-Host "   Nummer des Sticks"
  $disk = $disks | Where-Object { "$($_.Number)" -eq $sel.Trim() }
} until ($disk)
if ($disk.IsBoot -or $disk.IsSystem) { Fehler "Das ist ein Systemlaufwerk – abgebrochen." }
Write-Host ""
Write-Host ("   ACHTUNG: Alles auf '{0}' ({1:N1} GB) wird gelöscht!" -f $disk.FriendlyName, ($disk.Size / 1GB)) -ForegroundColor Red
$confirm = Read-Host "   Zum Fortfahren JA eingeben"
if ($confirm -cne "JA") { Fehler "Abgebrochen – nichts wurde verändert." }

# --- 4. Stick vorbereiten + Ubuntu kopieren -----------------------------------
Titel "4/5  Stick wird erstellt"
Info "Lösche und formatiere den Stick (FAT32) …"
$disk | Set-Disk -IsReadOnly $false -ErrorAction SilentlyContinue
# Ein ganz neuer (RAW) Stick lässt sich nicht "leeren" – dann direkt weiter
if ($disk.PartitionStyle -ne "RAW") { $disk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false }
$disk = Get-Disk -Number $disk.Number
if ($disk.PartitionStyle -eq "RAW") { $disk | Initialize-Disk -PartitionStyle MBR }
$size = [uint64]([Math]::Min([double]$disk.Size - 16MB, [double]30GB))   # FAT32 unter Windows max. 32 GB
$part = New-Partition -DiskNumber $disk.Number -Size $size -AssignDriveLetter -IsActive
Start-Sleep -Seconds 2
$vol = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel "BUTCHIESKI" -Confirm:$false
$usb = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter
if (-not $usb) { Fehler "Der Stick hat keinen Laufwerksbuchstaben bekommen." }
$usb = "$($usb):\"
Info "Stick bereit unter $usb"

Info "Binde ISO ein …"
$img = Mount-DiskImage -ImagePath $iso -PassThru
Start-Sleep -Seconds 2
$isoDrive = "$(($img | Get-Volume).DriveLetter):\"
try {
  $files = @(Get-ChildItem -Path $isoDrive -Recurse -Force -File)
  $total = ($files | Measure-Object -Property Length -Sum).Sum
  foreach ($f in $files) { if ($f.Length -ge 4GB) { Fehler "Datei zu groß für FAT32: $($f.FullName)" } }
  Info ("Kopiere Ubuntu auf den Stick ({0:N1} GB) …" -f ($total / 1GB))
  FortschrittNeu
  $done = 0
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($isoDrive.Length)
    $dst = Join-Path $usb $rel
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    $done += $f.Length
    Fortschritt (100 * $done / $total) $rel
  }
} finally {
  Dismount-DiskImage -ImagePath $iso | Out-Null
}
Get-ChildItem -Path $usb -Recurse -Force | ForEach-Object { try { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) } catch {} }

# --- 5. Automatik einbauen ----------------------------------------------------
Titel "5/5  Automatische Installation einbauen"
$utf8 = New-Object System.Text.UTF8Encoding($false)
function SchreibeLF($pfad, $text) { [IO.File]::WriteAllText($pfad, ($text -replace "`r`n", "`n"), $utf8) }

# grub.cfg: Startparameter "autoinstall", kurze Wartezeit
$grub = Join-Path $usb "boot\grub\grub.cfg"
if (-not (Test-Path $grub)) { Fehler "boot\grub\grub.cfg fehlt auf dem Stick – ISO beschädigt?" }
$g = [IO.File]::ReadAllText($grub)
$g = [regex]::Replace($g, 'set timeout=\d+', 'set timeout=5')
$rx = New-Object System.Text.RegularExpressions.Regex('(linux\s+/casper/vmlinuz)(\s+)(---)')
if (-not $rx.IsMatch($g)) { Fehler "Startzeile in grub.cfg nicht gefunden – unbekannte ISO-Version." }
$g = $rx.Replace($g, '$1 autoinstall $3', 1)
$g = $g.Replace('menuentry "Try or Install Ubuntu Server"', 'menuentry "Butchies KI Studio installieren (automatisch)"')
SchreibeLF $grub $g
Info "grub.cfg angepasst ✓"

# Nutzdaten kopieren (Zeilenenden auf LF, damit Linux sie lesen kann)
$textExt = @(".sh", ".py", ".yaml", ".yml", ".service", ".timer", ".html", ".js", ".css", ".json", ".md", ".txt")
function KopiereOrdner($von, $nach) {
  Get-ChildItem -Path $von -Recurse -Force -File | ForEach-Object {
    $rel = $_.FullName.Substring($von.Length).TrimStart("\")
    $dst = Join-Path $nach $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    if ($textExt -contains $_.Extension.ToLower()) {
      SchreibeLF $dst ([IO.File]::ReadAllText($_.FullName, $utf8))
    } else {
      Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    }
  }
}
$payload = Join-Path $usb "butchies"
KopiereOrdner (Join-Path $Root "installer") (Join-Path $payload "installer")
KopiereOrdner (Join-Path $Root "server") (Join-Path $payload "server")
SchreibeLF (Join-Path $usb "autoinstall.yaml") ([IO.File]::ReadAllText((Join-Path $Root "installer\autoinstall.yaml"), $utf8))

function ShQuote($s) { "'" + ($s -replace "'", "'\''") + "'" }
$cfg = "# Butchies KI Studio – Einstellungen für die Installation`n" +
       "# Das Passwort wird nach der Installation automatisch vom Stick gelöscht.`n" +
       "BKI_HOSTNAME=$(ShQuote $hostname)`n" +
       "BKI_USERNAME=$(ShQuote $username)`n" +
       "BKI_PASSWORD=$(ShQuote $pw1)`n"
SchreibeLF (Join-Path $payload "config.env") $cfg
$pw1 = $null; $pw2 = $null
Info "Butchies-Dateien und Einstellungen kopiert ✓"

Write-Host ""
Write-Host "   [####################] 100 %  Stick ist fertig!" -ForegroundColor Green
Write-Host ""
Write-Host "   So geht es weiter:"
Write-Host "   1. Stick und LAN-Kabel in den Mini-PC stecken (SSD eingebaut – sie wird komplett gelöscht)."
Write-Host "   2. Mini-PC einschalten – er startet vom Stick und installiert alles allein."
Write-Host "   3. Fortschritt im Browser:  http://butchies-ki-setup.local"
Write-Host "   4. Nach dem Neustart:        http://$hostname.local"
Write-Host "      (dort lädt er beim ersten Mal die KI, ca. 17 GB)"
Write-Host ""
Write-Host "   Der Stick kann danach stecken bleiben – der Mini-PC startet von der SSD."
Write-Host "   ACHTUNG: Der Stick löscht beim Start die eingebaute SSD – nur im Mini-PC benutzen!"
Write-Host ""
Read-Host "Enter zum Beenden"
