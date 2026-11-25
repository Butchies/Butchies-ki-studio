<#
  Butchies KI – Taskleisten-Programm (ersetzt den Weck-Helfer)

  * Symbol unten rechts: Farbe = Zustand, Zahl = Prozessor-Auslastung des Mini-PCs
      grün = wach · Akzentfarbe = KI arbeitet · grau "Zz" = schläft/aus · rot "!" = Problem · "?" = Anmeldung nötig
  * Klick aufs Symbol: Status-Fenster im Windows-11-Stil (hell/dunkel + Akzentfarbe wie in Windows)
  * "Oberfläche öffnen": eigenes Fenster (Edge-App-Modus), weckt den Mini-PC bei Bedarf
  * Weckseite http://localhost:8765 (Desktop-Verknüpfung "Butchies KI")
  * Das Abfragen des Status hält den Mini-PC NICHT wach.
#>
param([string]$MiniPC = "", [switch]$OpenOnStart, [switch]$ConsoleOnly)

$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, PresentationFramework, PresentationCore, WindowsBase, WindowsFormsIntegration
Add-Type -Namespace BKI -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);'

# --- Einstellungen ------------------------------------------------------------
$cfgDir = Join-Path $env:APPDATA "ButchiesKI"
$cfgFile = Join-Path $cfgDir "taskleiste.json"
$pwFile = Join-Path $cfgDir "passwort.dat"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$cfg = @{ host = "butchies-ki"; mac = ""; ip = "" }
foreach ($f in @($cfgFile, (Join-Path $cfgDir "weck-helfer.json"))) {
  if (Test-Path $f) { try { $j = Get-Content $f -Raw | ConvertFrom-Json; foreach ($k in "host", "mac", "ip") { if ($j.$k) { $cfg[$k] = $j.$k } }; break } catch {} }
}
if ($MiniPC -and $MiniPC -ne $cfg.host) {
  $cfg.host = $MiniPC; $cfg.ip = ""; $cfg.mac = ""
  if (Test-Path $pwFile) { Remove-Item $pwFile -Force }
}
function Speichern { $cfg | ConvertTo-Json | Set-Content -Path $cfgFile -Encoding UTF8 }
if ($cfg.host -ieq "butchies-ki.local") { $cfg.host = "butchies-ki"; Speichern }
function LadePasswort {
  if (-not (Test-Path $pwFile)) { return "" }
  try {
    $sec = Get-Content $pwFile -Raw | ConvertTo-SecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  } catch { return "" }
}
function SpeicherePasswort($pw) {
  if ($pw) { ConvertTo-SecureString $pw -AsPlainText -Force | ConvertFrom-SecureString | Set-Content $pwFile }
  elseif (Test-Path $pwFile) { Remove-Item $pwFile -Force }
}

function OeffneLinuxKonsole {
  $target = $cfg.host
  if ($target -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$') {
    [Windows.Forms.MessageBox]::Show("Bitte in den Einstellungen einen gültigen Servernamen oder eine IPv4-Adresse hinterlegen.", "Linux-Konsole") | Out-Null
    return
  }
  $ssh = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $ssh) {
    [Windows.Forms.MessageBox]::Show("Aktiviere unter Windows den OpenSSH-Client in den optionalen Features.", "Linux-Konsole") | Out-Null
    return
  }
  Add-Type -AssemblyName Microsoft.VisualBasic
  $user = [Microsoft.VisualBasic.Interaction]::InputBox("Linux-Benutzername für $target", "Linux-Konsole (SSH)", "butchies").Trim()
  if (-not $user) { return }
  if ($user -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') {
    [Windows.Forms.MessageBox]::Show("Ungültiger Linux-Benutzername.", "Linux-Konsole") | Out-Null
    return
  }
  $sshPath = $ssh.Source.Replace("'", "''")
  $command = "& '$sshPath' -l '$user' -- '$target'"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  Start-Process -FilePath (Join-Path $PSHOME "powershell.exe") -ArgumentList "-NoProfile", "-NoExit", "-EncodedCommand", $encoded
}

if ($ConsoleOnly) { OeffneLinuxKonsole; return }

# --- Gemeinsamer Zustand mit dem Hintergrund-Thread -----------------------------
$sync = [hashtable]::Synchronized(@{
  Host = $cfg.host; Base = ""; Ip = $cfg.ip; Mac = $cfg.mac; Password = (LadePasswort)
  Remember = (Test-Path $pwFile); State = "unbekannt"; Status = $null; Version = 0; Stop = $false; Fast = $false
  Queue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
  Message = ""; Notify = ""; LastSeen = $null; LoginError = ""
  TrayVersion = "0.4.14"; UpdateCache = (Join-Path $cfgDir "cache")
  WindowsUpdate = $null; Updating = $false; UpdateNotice = ""
})

# --- Hintergrund-Thread: fragt den Mini-PC ab, führt Befehle aus ------------------
$worker = {
  param($sync)
  $cookies = New-Object Net.CookieContainer

  $githubDownload = "https://raw.githubusercontent.com/Butchies/Butchies-ki-studio/refs/heads/fix/0.4.8-studio-login/download"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $nextUpdateCheck = [datetime]::MinValue

  function PruefeWindowsUpdate([bool]$manual) {
    try {
      $manifest = Invoke-RestMethod -UseBasicParsing -Uri "$githubDownload/update.json" -TimeoutSec 12 -ErrorAction Stop
      if ($manifest.version -notmatch '^\d+\.\d+\.\d+$' -or $manifest.sha256 -notmatch '^[a-f0-9]{64}$') {
        throw "Update-Metadaten ungültig."
      }
      if ([version]$manifest.version -gt [version]$sync.TrayVersion) {
        $previous = $sync.WindowsUpdate
        $sync.WindowsUpdate = $manifest
        if ($manual -or -not $previous -or $previous.version -ne $manifest.version) {
          $sync.UpdateNotice = "Windows-Update $($manifest.version) verfügbar. Im Taskleistenmenü kannst du es installieren."
        }
      } else {
        $sync.WindowsUpdate = $null
        if ($manual) { $sync.UpdateNotice = "Butchies KI für Windows ist aktuell ($($sync.TrayVersion))." }
      }
    } catch {
      if ($manual) { $sync.UpdateNotice = "GitHub-Updateprüfung fehlgeschlagen: $($_.Exception.Message)" }
    }
  }

  function InstalliereWindowsUpdate {
    $manifest = $sync.WindowsUpdate
    if (-not $manifest) { $sync.Updating = $false; return }
    $part = $null
    try {
      New-Item -ItemType Directory -Force -Path $sync.UpdateCache -ErrorAction Stop | Out-Null
      $setup = Join-Path $sync.UpdateCache ("Butchies-KI-Setup-" + $manifest.version + ".exe")
      $part = "$setup.part"
      Invoke-WebRequest -UseBasicParsing -Uri "$githubDownload/Butchies-KI-Setup.exe" -OutFile $part -TimeoutSec 90 -ErrorAction Stop
      if ((Get-FileHash -Algorithm SHA256 -LiteralPath $part -ErrorAction Stop).Hash -ine $manifest.sha256) {
        throw "Die Prüfsumme stimmt nicht. Bitte erneut nach Updates suchen."
      }
      Move-Item -LiteralPath $part -Destination $setup -Force -ErrorAction Stop
      Start-Process -FilePath $setup -ErrorAction Stop
    } catch {
      $sync.UpdateNotice = "Windows-Update konnte nicht gestartet werden: $($_.Exception.Message)"
    } finally {
      if ($part -and (Test-Path -LiteralPath $part)) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
      $sync.Updating = $false
    }
  }

  function Anfrage($method, $path, $body, $ms) {
    $result = @{ Code = 0; Text = "" }
    $bases = @("http://$($sync.Host)")
    if ($sync.Ip) { $bases += "http://$($sync.Ip)" }
    foreach ($base in ($bases | Select-Object -Unique)) {
      try {
        $req = [Net.HttpWebRequest]::Create("$base$path")
        $req.AllowAutoRedirect = $false; $req.Method = $method; $req.Timeout = $ms; $req.ReadWriteTimeout = $ms
        $req.CookieContainer = $cookies; $req.UserAgent = "ButchiesKI-Taskleiste"
        if ($body -ne $null) {
          $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress))
          $req.ContentType = "application/json"; $req.ContentLength = $bytes.Length
          $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        }
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $result.Text = $sr.ReadToEnd(); $result.Code = [int]$resp.StatusCode; $sync.Base = $base; $resp.Close()
        return $result
      } catch [Net.WebException] {
        if ($_.Exception.Response) {
          $response = $_.Exception.Response
          $result.Code = [int]$response.StatusCode
          $response.Close()
          if ($result.Code -eq 401) { $sync.Base = $base; return $result }
        }
      } catch {}
    }
    return $result
  }
  function Wecken {
    if (-not $sync.Mac) { $sync.Message = "MAC-Adresse unbekannt – Mini-PC einmal normal einschalten."; return }
    $mac = $sync.Mac -split "[:-]" | ForEach-Object { [Convert]::ToByte($_, 16) }
    $packet = [byte[]](@(0xFF) * 6 + ($mac * 16))
    $udp = New-Object Net.Sockets.UdpClient; $udp.EnableBroadcast = $true
    $ziele = @("255.255.255.255"); if ($sync.Ip -match '^(\d+\.\d+\.\d+)\.\d+$') { $ziele += "$($Matches[1]).255" }
    foreach ($z in $ziele) { foreach ($p in 9, 7) { try { [void]$udp.Send($packet, $packet.Length, $z, $p) } catch {} } }
    $udp.Close(); $sync.Message = "Weck-Signal gesendet …"
  }
  function Anmelden {
    if (-not $sync.Password) { $sync.State = "anmelden"; return $false }
    $r = Anfrage "POST" "/api/login" @{ password = $sync.Password } 5000
    if ($r.Code -eq 200) {
      $sync.LoginError = ""
      if ($sync.Remember) { $sync.AcceptedPassword = $sync.Password }
      else { $sync.Password = "" }
      return $true
    }
    if ($r.Code -eq 401) { $sync.LoginError = "Passwort falsch"; $sync.Password = ""; $sync.State = "anmelden" }
    return $false
  }
  $lastLearn = [datetime]::MinValue; $wasRunning = $false
  while (-not $sync.Stop) {
    # Befehle aus dem Fenster
    $cmd = $null
    while ($sync.Queue.TryDequeue([ref]$cmd)) {
      switch -Regex ($cmd) {
        "^wake$" { Wecken }
        "^login$" { [void](Anmelden) }
        "^update-check$" {
          PruefeWindowsUpdate $true
          $nextUpdateCheck = [datetime]::UtcNow.AddHours(1)
        }
        "^update-install$" { InstalliereWindowsUpdate }
        "^(sleep|reboot|shutdown)$" {
          $r = Anfrage "POST" "/api/system/$cmd" @{} 5000
          $sync.Message = if ($r.Code -eq 200) { @{ sleep = "Mini-PC wird schlafen gelegt."; reboot = "Mini-PC startet neu."; shutdown = "Mini-PC fährt herunter." }[$cmd] } else { "Befehl fehlgeschlagen (Code $($r.Code))." }
          if ($r.Code -eq 200 -and $cmd -ne "reboot") { $sync.State = "schlaeft"; $sync.Status = $null; $sync.Version++ }
        }
      }
    }
    if ([datetime]::UtcNow -ge $nextUpdateCheck) {
      PruefeWindowsUpdate $false
      $nextUpdateCheck = [datetime]::UtcNow.AddHours(1)
    }
    # Status abfragen (GET hält den Mini-PC nicht wach)
    $r = Anfrage "GET" "/api/status" $null 2500
    if ($r.Code -eq 401) { if (Anmelden) { $r = Anfrage "GET" "/api/status" $null 2500 } }
    if ($r.Code -eq 200) {
      try {
        $st = $r.Text | ConvertFrom-Json
        $sync.Status = $st; $sync.LastSeen = Get-Date
        $busy = ($st.sleep_blockers -contains "KI antwortet") -or $st.job.running
        $bad = ($st.llama.state -eq "abgestürzt") -or [bool]$st.job.error
        $sync.State = if ($bad) { "problem" } elseif ($busy) { "arbeitet" } else { "wach" }
        if ($wasRunning -and -not $st.job.running) {
          $sync.Notify = if ($st.job.error) { "$($st.job.name): Fehler – $($st.job.error)" } else { "$($st.job.name) ist fertig." }
        }
        $wasRunning = [bool]$st.job.running
        if (((Get-Date) - $lastLearn).TotalMinutes -gt 10 -and $st.mac) {
          $sync.Mac = $st.mac; $sync.Ip = $st.ip; $lastLearn = Get-Date
        }
      } catch {}
    } elseif ($r.Code -ne 401) {
      if ($sync.State -ne "anmelden") { $sync.State = "schlaeft" }
      $sync.Status = $null
    }
    $sync.Version++
    $wait = if ($sync.Fast) { 3 } elseif ($sync.State -eq "schlaeft") { 20 } else { 10 }
    for ($i = 0; $i -lt $wait * 4 -and -not $sync.Stop -and $sync.Queue.IsEmpty; $i++) { Start-Sleep -Milliseconds 250 }
  }
}
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = "MTA"; $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript($worker).AddArgument($sync)
$handle = $ps.BeginInvoke()

# --- Windows-Design (hell/dunkel + Akzentfarbe) ----------------------------------
function WindowsDesign {
  $light = $true
  try { $light = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize").AppsUseLightTheme -ne 0 } catch {}
  $acc = [Drawing.Color]::FromArgb(0, 103, 192)
  try {
    # DWORD kann als negative Zahl kommen – nur mit -band zerlegen, nicht nach [uint32] umwandeln
    $v = [int64](Get-ItemProperty "HKCU:\Software\Microsoft\Windows\DWM").AccentColor
    $acc = [Drawing.Color]::FromArgb($v -band 0xFF, ($v -shr 8) -band 0xFF, ($v -shr 16) -band 0xFF)
  } catch {}
  if (-not $light) {  # im dunklen Design hellere Variante wie Windows
    $acc = [Drawing.Color]::FromArgb([int]($acc.R + (255 - $acc.R) * 0.45), [int]($acc.G + (255 - $acc.G) * 0.45), [int]($acc.B + (255 - $acc.B) * 0.45))
  }
  $lum = (0.2126 * $acc.R + 0.7152 * $acc.G + 0.0722 * $acc.B) / 255
  $hex = "#{0:X2}{1:X2}{2:X2}" -f $acc.R, $acc.G, $acc.B
  $t = if ($light) {
    @{ Bg = "#F3F3F3"; Border = "#D9D9D9"; Card = "#FBFBFB"; CardBorder = "#E5E5E5"; Text = "#1A1A1A"; Sub = "#5C5C5C"; Track = "#D4D4D4"
       Btn = "#FDFDFD"; BtnBorder = "#D1D1D1"; Ok = "#0F7B0F"; OkBg = "#DFF6DD"; Crit = "#C42B1C"; Sep = "#E5E5E5"; Input = "#FFFFFF"; Ram = "#3B8ED6" }
  } else {
    @{ Bg = "#2C2C2C"; Border = "#434343"; Card = "#363636"; CardBorder = "#3D3D3D"; Text = "#FFFFFF"; Sub = "#C5C5C5"; Track = "#4A4A4A"
       Btn = "#3A3A3A"; BtnBorder = "#4A4A4A"; Ok = "#8FD88A"; OkBg = "#2D3B2C"; Crit = "#FF99A4"; Sep = "#3D3D3D"; Input = "#1F1F1F"; Ram = "#9FD8FF" }
  }
  $t.Accent = $hex; $t.OnAccent = if ($lum -gt 0.55) { "#000000" } else { "#FFFFFF" }; $t.AccentColor = $acc; $t.Light = $light
  return $t
}

# --- Taskleisten-Symbol zeichnen --------------------------------------------------
$script:hIcon = [IntPtr]::Zero
function NeuesSymbol([Drawing.Color]$farbe, [string]$text, [Drawing.Color]$schrift) {
  $bmp = New-Object Drawing.Bitmap 32, 32
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = "AntiAlias"; $g.TextRenderingHint = "AntiAliasGridFit"
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $r = 7; $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $path.AddArc(31 - $r * 2, 0, $r * 2, $r * 2, 270, 90)
  $path.AddArc(31 - $r * 2, 31 - $r * 2, $r * 2, $r * 2, 0, 90); $path.AddArc(0, 31 - $r * 2, $r * 2, $r * 2, 90, 90); $path.CloseFigure()
  $g.FillPath((New-Object Drawing.SolidBrush $farbe), $path)
  $size = if ($text.Length -ge 3) { 11 } elseif ($text.Length -eq 2) { 14 } else { 17 }
  $font = New-Object Drawing.Font("Segoe UI", $size, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object Drawing.StringFormat; $sf.Alignment = "Center"; $sf.LineAlignment = "Center"
  $g.DrawString($text, $font, (New-Object Drawing.SolidBrush $schrift), (New-Object Drawing.RectangleF(0, 1, 32, 32)), $sf)
  $h = $bmp.GetHicon(); $icon = [Drawing.Icon]::FromHandle($h)
  if ($script:hIcon -ne [IntPtr]::Zero) { [void][BKI.Native]::DestroyIcon($script:hIcon) }
  $script:hIcon = $h; $g.Dispose(); $bmp.Dispose()
  return $icon
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Visible = $true
$script:lastIconKey = ""
function AktualisiereSymbol {
  $t = WindowsDesign; $st = $sync.Status
  $cpu = if ($st) { [string][int]$st.cpu } else { "" }
  switch ($sync.State) {
    "wach"     { $c = [Drawing.Color]::FromArgb(16, 124, 16); $txt = $cpu; $fg = [Drawing.Color]::White; $tip = "wach" }
    "arbeitet" { $c = $t.AccentColor; $txt = $cpu; $fg = if ($t.OnAccent -eq "#000000") { [Drawing.Color]::Black } else { [Drawing.Color]::White }; $tip = "KI arbeitet" }
    "problem"  { $c = [Drawing.Color]::FromArgb(196, 43, 28); $txt = "!"; $fg = [Drawing.Color]::White; $tip = "Problem" }
    "anmelden" { $c = [Drawing.Color]::FromArgb(110, 110, 110); $txt = "?"; $fg = [Drawing.Color]::White; $tip = "Anmeldung nötig" }
    default    { $c = [Drawing.Color]::FromArgb(110, 110, 110); $txt = "Zz"; $fg = [Drawing.Color]::White; $tip = "schläft oder aus" }
  }
  $key = "$($c.ToArgb())|$txt"
  if ($key -ne $script:lastIconKey) { $tray.Icon = NeuesSymbol $c $txt $fg; $script:lastIconKey = $key }
  $tipText = "Butchies KI: $tip"
  if ($st) { $tipText += (" · CPU {0} % · RAM {1:N0}/{2:N0} GB" -f [int]$st.cpu, ($st.mem_used / 1GB), ($st.mem_total / 1GB)) }
  if ($tipText.Length -gt 63) { $tipText = $tipText.Substring(0, 63) }
  $tray.Text = $tipText
}

# --- Status-Fenster (WPF, Windows-11-Stil) ----------------------------------------
$xamlVorlage = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Butchies KI" Width="396" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12" Foreground="%Text%">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Height" Value="34"/><Setter Property="Foreground" Value="%Text%"/>
      <Setter Property="Background" Value="%Btn%"/><Setter Property="BorderBrush" Value="%BtnBorder%"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="%Accent%"/><Setter Property="BorderBrush" Value="%Accent%"/>
      <Setter Property="Foreground" Value="%OnAccent%"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Foreground" Value="%Sub%"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button"><TextBlock Text="{TemplateBinding Content}" TextDecorations="Underline" Foreground="{TemplateBinding Foreground}"/></ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Border Margin="8" CornerRadius="8" Background="%Bg%" BorderBrush="%Border%" BorderThickness="1" Padding="18">
    <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="3" Opacity="0.35"/></Border.Effect>
    <StackPanel>
      <DockPanel LastChildFill="True">
<Border DockPanel.Dock="Left" Margin="0,0,12,0"><Viewbox Width="42" Height="42"><Canvas Width="100" Height="100"><Rectangle Canvas.Left="4" Canvas.Top="4" Width="92" Height="92" RadiusX="22" RadiusY="22" Fill="#0067C0"/><Path Data="M33,24 H53 C63,24 69,29 69,37 C69,42 66,46 62,47 C68,48 72,53 72,59 C72,68 65,74 54,74 H33 Z" Stroke="White" StrokeThickness="8" StrokeLineJoin="Round"/><Ellipse Canvas.Left="72.5" Canvas.Top="16.5" Width="11" Height="11" Fill="#9FD8FF"/><Line X1="69" Y1="31" X2="75" Y2="25" Stroke="#9FD8FF" StrokeThickness="3.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas></Viewbox></Border>
        <Border x:Name="Pill" DockPanel.Dock="Right" CornerRadius="10" Padding="10,3" VerticalAlignment="Center">
          <TextBlock x:Name="PillText" FontSize="12"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Butchies KI" FontSize="15" FontWeight="SemiBold"/>
          <TextBlock x:Name="Sub" Foreground="%Sub%" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </DockPanel>

      <StackPanel x:Name="LoginPanel" Margin="0,14,0,0" Visibility="Collapsed">
        <TextBlock Text="Passwort der Butchies-KI-Oberfläche:" Foreground="%Sub%" Margin="0,0,0,6"/>
        <PasswordBox x:Name="Pw" Height="32" Padding="6,5" Background="%Input%" Foreground="%Text%" BorderBrush="%BtnBorder%"/>
        <TextBlock x:Name="LoginMsg" Foreground="%Crit%" Margin="0,4,0,0"/>
        <CheckBox x:Name="RememberLogin" Content="Automatisch anmelden" Margin="0,6,0,0"/>
        <Button x:Name="BtnLogin" Content="Anmelden" Style="{StaticResource Primary}" Margin="0,8,0,0"/>
        <TextBlock Text="Bei automatischer Anmeldung speichert Windows das Passwort verschlüsselt." Foreground="%Sub%" Margin="0,6,0,0" TextWrapping="Wrap"/>
      </StackPanel>

      <StackPanel x:Name="DataPanel" Margin="0,14,0,0">
        <Border Background="%Card%" BorderBrush="%CardBorder%" BorderThickness="1" CornerRadius="6" Padding="12">
          <StackPanel>
            <DockPanel><TextBlock DockPanel.Dock="Right" x:Name="CpuText"/><TextBlock Text="Prozessor" Foreground="%Sub%"/></DockPanel>
            <Grid Height="4" Margin="0,4,0,10"><Border Background="%Track%" CornerRadius="2"/><Border x:Name="CpuBar" Background="%Accent%" CornerRadius="2" HorizontalAlignment="Left" Width="0"/></Grid>
            <DockPanel><TextBlock DockPanel.Dock="Right" x:Name="RamText"/><TextBlock Text="Arbeitsspeicher" Foreground="%Sub%"/></DockPanel>
            <Grid Height="4" Margin="0,4,0,10"><Border Background="%Track%" CornerRadius="2"/><Border x:Name="RamBar" Background="%Ram%" CornerRadius="2" HorizontalAlignment="Left" Width="0"/></Grid>
            <DockPanel><TextBlock DockPanel.Dock="Right" x:Name="DiskText"/><TextBlock Text="SSD" Foreground="%Sub%"/></DockPanel>
            <Grid Height="4" Margin="0,4,0,10"><Border Background="%Track%" CornerRadius="2"/><Border x:Name="DiskBar" Background="%Sub%" CornerRadius="2" HorizontalAlignment="Left" Width="0"/></Grid>
            <UniformGrid Columns="3">
              <StackPanel><TextBlock Text="Temperatur" Foreground="%Sub%" FontSize="11"/><TextBlock x:Name="TempText" FontSize="14" FontWeight="SemiBold"/></StackPanel>
              <StackPanel><TextBlock Text="Tempo" Foreground="%Sub%" FontSize="11"/><TextBlock x:Name="TpsText" FontSize="14" FontWeight="SemiBold"/></StackPanel>
              <StackPanel><TextBlock Text="KI" Foreground="%Sub%" FontSize="11"/><TextBlock x:Name="KiText" FontSize="14" FontWeight="SemiBold"/></StackPanel>
            </UniformGrid>
          </StackPanel>
        </Border>
        <Border x:Name="JobBox" Background="%Card%" BorderBrush="%CardBorder%" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,10,0,0" Visibility="Collapsed">
          <StackPanel>
            <DockPanel><TextBlock DockPanel.Dock="Right" x:Name="JobPct" FontWeight="SemiBold"/><TextBlock x:Name="JobName" TextTrimming="CharacterEllipsis"/></DockPanel>
            <UniformGrid x:Name="JobBlocks" Columns="20" Height="6" Margin="0,6,0,6"/>
            <TextBlock x:Name="JobText" Foreground="%Sub%" FontSize="11" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>
        <TextBlock x:Name="UpdateText" Foreground="%Accent%" Margin="0,10,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
      </StackPanel>

      <TextBlock x:Name="Info" Foreground="%Sub%" Margin="0,12,0,0" TextWrapping="Wrap"/>

      <Grid Margin="0,12,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="8"/><RowDefinition/></Grid.RowDefinitions>
        <Button x:Name="BtnOpen" Grid.ColumnSpan="3" Content="Oberfläche öffnen" Style="{StaticResource Primary}" Height="36"/>
        <Button x:Name="BtnSleep" Grid.Row="2" Content="Schlafen legen" Style="{StaticResource Btn}"/>
        <Button x:Name="BtnReboot" Grid.Row="2" Grid.Column="2" Content="Neu starten" Style="{StaticResource Btn}"/>
      </Grid>

      <StackPanel x:Name="SettingsPanel" Margin="0,12,0,0" Visibility="Collapsed">
        <TextBlock Text="Name des Mini-PCs im Heimnetz:" Foreground="%Sub%" Margin="0,0,0,4"/>
        <TextBox x:Name="HostBox" Height="30" Padding="6,4" Background="%Input%" Foreground="%Text%" BorderBrush="%BtnBorder%"/>
        <CheckBox x:Name="AutoStart" Content="Mit Windows starten" Foreground="%Text%" Margin="0,8,0,0"/>
        <Grid Margin="0,8,0,0">
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
          <Button x:Name="BtnSave" Content="Speichern" Style="{StaticResource Primary}"/>
          <Button x:Name="BtnForget" Grid.Column="2" Content="Passwort vergessen" Style="{StaticResource Btn}"/>
        </Grid>
      </StackPanel>

      <Border BorderBrush="%Sep%" BorderThickness="0,1,0,0" Margin="0,12,0,0" Padding="0,10,0,0">
        <DockPanel>
          <Button x:Name="LinkShutdown" DockPanel.Dock="Right" Content="Herunterfahren" Style="{StaticResource Link}" Foreground="%Crit%"/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="LinkSettings" Content="Einstellungen" Style="{StaticResource Link}" Margin="0,0,14,0"/>
            <Button x:Name="LinkQuit" Content="Beenden" Style="{StaticResource Link}"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </StackPanel>
  </Border>
</Window>
'@

$script:win = $null
$script:closedAt = [datetime]::MinValue
$startupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Butchies KI.lnk"
$BarWidth = 318.0

function Brush($hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }

function OeffneOberflaeche {
  $sync.Queue.Enqueue("wake") | Out-Null
  $acc = (WindowsDesign).Accent.TrimStart("#")
  $url = "http://localhost:8765/?accent=$acc"
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($edge) {
    $prof = Join-Path $cfgDir "edge-profil"
    $origins = "http://$($sync.Host)" + $(if ($sync.Ip) { ",http://$($sync.Ip)" } else { "" })
    Start-Process $edge -ArgumentList "--app=$url", "--user-data-dir=`"$prof`"", "--window-size=1400,900", "--unsafely-treat-insecure-origin-as-secure=$origins"
  } else { Start-Process $url }
}

function ZeigeFenster {
  if (((Get-Date) - $script:closedAt).TotalMilliseconds -lt 400) { return }  # Klick zum Schließen
  if ($script:win) { $script:win.Close(); return }
  $t = WindowsDesign
  $xaml = $xamlVorlage
  foreach ($k in "Bg", "Border", "Card", "CardBorder", "Text", "Sub", "Track", "Btn", "BtnBorder", "Crit", "Sep", "Input", "Ram", "Accent", "OnAccent") { $xaml = $xaml.Replace("%$k%", $t[$k]) }
  $w = [Windows.Markup.XamlReader]::Parse($xaml)
  [System.Windows.Forms.Integration.ElementHost]::EnableModelessKeyboardInterop($w)
  $n = @{}
  foreach ($name in "Pill", "PillText", "Sub", "LoginPanel", "Pw", "LoginMsg", "RememberLogin", "BtnLogin", "DataPanel", "CpuText", "CpuBar", "RamText", "RamBar", "DiskText", "DiskBar", "TempText", "TpsText", "KiText", "JobBox", "JobPct", "JobName", "JobBlocks", "JobText", "UpdateText", "Info", "BtnOpen", "BtnSleep", "BtnReboot", "SettingsPanel", "HostBox", "AutoStart", "BtnSave", "BtnForget", "LinkShutdown", "LinkSettings", "LinkQuit") {
    $n[$name] = $w.FindName($name)
  }
  for ($i = 0; $i -lt 20; $i++) { $r = New-Object Windows.Shapes.Rectangle; $r.Margin = "1,0,1,0"; $r.RadiusX = 1; $r.RadiusY = 1; [void]$n.JobBlocks.Children.Add($r) }
  $w.Tag = @{ N = $n; T = $t }

  $n.BtnOpen.Add_Click({ OeffneOberflaeche; $script:win.Close() })
  $n.BtnSleep.Add_Click({
    if ($sync.State -eq "schlaeft") { $sync.Queue.Enqueue("wake") } else { $sync.Queue.Enqueue("sleep") }
  })
  $n.BtnReboot.Add_Click({
    if ([Windows.MessageBox]::Show("Mini-PC neu starten?", "Butchies KI", "YesNo", "Question") -eq "Yes") { $sync.Queue.Enqueue("reboot") }
  })
  $n.LinkShutdown.Add_Click({
    if ([Windows.MessageBox]::Show("Mini-PC herunterfahren?`nEinschalten geht dann nur per Wake-on-LAN oder am Gerät.", "Butchies KI", "YesNo", "Warning") -eq "Yes") { $sync.Queue.Enqueue("shutdown") }
  })
  $n.RememberLogin.IsChecked = $sync.Remember
  $n.BtnLogin.Add_Click({
    $pw = $script:win.Tag.N.Pw.Password
    if ($pw.Length -lt 4) { $script:win.Tag.N.LoginMsg.Text = "Mindestens 4 Zeichen."; return }
    $sync.Remember = [bool]$script:win.Tag.N.RememberLogin.IsChecked
    if (-not $sync.Remember) { $sync.AcceptedPassword = ""; SpeicherePasswort "" }
    $sync.Password = $pw; $sync.Queue.Enqueue("login"); $script:win.Tag.N.Pw.Clear()
    $script:win.Tag.N.LoginMsg.Text = "Melde an …"
  })
  $n.LinkSettings.Add_Click({
    $p = $script:win.Tag.N.SettingsPanel
    $p.Visibility = if ($p.Visibility -eq "Visible") { "Collapsed" } else { "Visible" }
    $script:win.Tag.N.HostBox.Text = $cfg.host
    $script:win.Tag.N.AutoStart.IsChecked = Test-Path $startupLnk
  })
  $n.BtnSave.Add_Click({
    $h = $script:win.Tag.N.HostBox.Text.Trim().ToLower()
    if ($h -match '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$' -and $h -ne $cfg.host) { SpeicherePasswort ""; $sync.Password = ""; $sync.AcceptedPassword = ""; $sync.Base = ""; $sync.Host = $h; $sync.Ip = ""; $sync.Mac = ""; $cfg.host = $h; $cfg.ip = ""; $cfg.mac = ""; Speichern }
    AutostartSetzen ([bool]$script:win.Tag.N.AutoStart.IsChecked)
    $script:win.Tag.N.SettingsPanel.Visibility = "Collapsed"
  })
  $n.BtnForget.Add_Click({ SpeicherePasswort ""; $sync.Remember = $false; $sync.AcceptedPassword = ""; $sync.Password = ""; $sync.State = "anmelden"; $sync.Version++ })
  $n.LinkQuit.Add_Click({ Beenden })
  $w.Add_Deactivated({ if ($script:win) { $script:win.Close() } })
  $w.Add_Closed({ $script:win = $null; $script:closedAt = Get-Date; $sync.Fast = $false })
  $w.Add_SizeChanged({
    $wa = [Windows.SystemParameters]::WorkArea
    $script:win.Left = $wa.Right - $script:win.ActualWidth - 4
    $script:win.Top = $wa.Bottom - $script:win.ActualHeight - 4
  })
  $wa0 = [Windows.SystemParameters]::WorkArea
  $w.WindowStartupLocation = "Manual"; $w.Left = $wa0.Right - 400; $w.Top = $wa0.Bottom - 640
  $script:win = $w
  $sync.Fast = $true
  FensterAktualisieren
  $w.Show(); [void]$w.Activate()
}

function FensterAktualisieren {
  if (-not $script:win) { return }
  $n = $script:win.Tag.N; $t = $script:win.Tag.T; $st = $sync.Status
  $state = $sync.State
  $labels = @{ wach = "Wach"; arbeitet = "KI arbeitet"; problem = "Problem"; anmelden = "Anmelden"; schlaeft = "Schläft / aus"; unbekannt = "Prüfe …" }
  $n.PillText.Text = "● " + $labels[$state]
  switch ($state) {
    "wach"     { $n.Pill.Background = Brush $t.OkBg; $n.PillText.Foreground = Brush $t.Ok }
    "arbeitet" { $n.Pill.Background = Brush $t.Accent; $n.PillText.Foreground = Brush $t.OnAccent }
    "problem"  { $n.Pill.Background = Brush $t.Card; $n.PillText.Foreground = Brush $t.Crit }
    default    { $n.Pill.Background = Brush $t.Card; $n.PillText.Foreground = Brush $t.Sub }
  }
  $n.LoginPanel.Visibility = if ($state -eq "anmelden") { "Visible" } else { "Collapsed" }
  if ($state -eq "anmelden" -and $sync.LoginError) { $n.LoginMsg.Text = $sync.LoginError }
  $n.DataPanel.Visibility = if ($st) { "Visible" } else { "Collapsed" }
  $n.BtnSleep.Content = if ($state -eq "schlaeft") { "Aufwecken" } else { "Schlafen legen" }
  $n.BtnSleep.IsEnabled = $state -ne "anmelden"
  $n.BtnReboot.IsEnabled = [bool]$st
  $n.LinkShutdown.IsEnabled = [bool]$st
  if ($st) {
    $model = if ($st.llama.model) { $st.llama.model -replace '\.gguf$', '' } else { "kein Modell" }
    $n.Sub.Text = "$($st.host) · $model"
    $n.CpuText.Text = "$([int]$st.cpu) %"; $n.CpuBar.Width = $BarWidth * [Math]::Min(1, $st.cpu / 100)
    $n.RamText.Text = "{0:N1} / {1:N0} GB" -f ($st.mem_used / 1GB), ($st.mem_total / 1GB); $n.RamBar.Width = $BarWidth * ($st.mem_used / [Math]::Max(1, $st.mem_total))
    $n.DiskText.Text = "{0:N0} / {1:N0} GB" -f ($st.disk_used / 1GB), ($st.disk_total / 1GB); $n.DiskBar.Width = $BarWidth * ($st.disk_used / [Math]::Max(1, $st.disk_total))
    $n.TempText.Text = if ($st.temp -ne $null) { "$($st.temp) °C" } else { "–" }
    $n.TpsText.Text = if ($st.llama.tps) { ("{0:N1} T/s" -f $st.llama.tps) } else { "–" }
    $n.KiText.Text = $st.llama.state
    $n.KiText.Foreground = if ($st.llama.state -eq "bereit") { Brush $t.Ok } elseif ($st.llama.state -eq "abgestürzt") { Brush $t.Crit } else { Brush $t.Text }
    $job = $st.job
    $showJob = $job.running -or $job.error
    $n.JobBox.Visibility = if ($showJob) { "Visible" } else { "Collapsed" }
    if ($showJob) {
      $n.JobName.Text = $job.name; $n.JobPct.Text = "$($job.percent) %"
      $n.JobText.Text = if ($job.error) { "Fehler: $($job.error)" } else { $job.text }
      $on = [Math]::Floor($job.percent / 5)
      for ($i = 0; $i -lt 20; $i++) { $n.JobBlocks.Children[$i].Fill = if ($i -lt $on) { Brush $t.Accent } else { Brush $t.Track } }
    }
    $ups = @($st.updates_available)
    $n.UpdateText.Visibility = if ($ups.Count -gt 0) { "Visible" } else { "Collapsed" }
    $n.UpdateText.Text = "Update verfügbar: " + ($ups -join ", ") + " – in der Oberfläche unter System."
    if ($st.sleep_blockers.Count -gt 0) { $n.Info.Text = "Bleibt wach: " + ($st.sleep_blockers -join ", ") + "." }
    elseif ($st.sleep_enabled) {
      $rest = [Math]::Max(0, [Math]::Ceiling(($st.sleep_minutes * 60 - $st.idle_seconds) / 60))
      $n.Info.Text = "Schläft in ca. $rest Minute$(if ($rest -ne 1) { 'n' }), wenn du ihn nicht benutzt."
    } else { $n.Info.Text = "Ruhezustand ist ausgeschaltet." }
  } else {
    $n.Sub.Text = "$($sync.Host)"
    $n.Info.Text = switch ($state) {
      "schlaeft" { if ($sync.LastSeen) { "Zuletzt wach: $($sync.LastSeen.ToString('HH:mm')) Uhr. »Aufwecken« oder »Oberfläche öffnen« weckt ihn." } else { "Nicht erreichbar – schläft er, oder ist er aus?" } }
      "anmelden" { "Einmal anmelden, dann zeigt das Fenster alle Werte." }
      default { "Verbinde …" }
    }
  }
  if ($sync.Message) { $n.Info.Text = $sync.Message + "  " + $n.Info.Text }
}

function AutostartSetzen([bool]$an) {
  if ($an) {
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($startupLnk)
    $l.TargetPath = "powershell.exe"
    $l.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $l.WindowStyle = 7; $l.Save()
  } elseif (Test-Path $startupLnk) { Remove-Item $startupLnk -Force }
}

function Beenden {
  $sync.Stop = $true
  if ($script:win) { $script:win.Close() }
  $tray.Visible = $false
  try { $listener.Stop() } catch {}
  [Windows.Forms.Application]::Exit()
}

# --- Weckseite http://localhost:8765 ---------------------------------------------
$page = @'
<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Butchies KI</title>
<style>:root{color-scheme:light dark}body{margin:0;font:15px "Segoe UI",sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;background:Canvas;color:CanvasText}
.c{text-align:center;max-width:460px}.d{width:42px;height:42px;border:4px solid #8888;border-top-color:ACCENT;border-radius:50%;margin:0 auto 18px;animation:r 1s linear infinite}
@keyframes r{to{transform:rotate(360deg)}}.m{opacity:.75;font-size:14px}</style></head>
<body><div class="c"><div class="d"></div><h2 id="t">Mini-PC wird geweckt …</h2><p class="m" id="m">Das dauert meist 3–10 Sekunden.</p></div>
<script>
let n=0;
async function tick(){n++;try{const r=await (await fetch("/status",{cache:"no-store"})).json();
if(r.awake){document.getElementById("t").textContent="Wach – öffne Butchies KI …";location.href=r.url+location.search;return;}
if(!r.mac){document.getElementById("m").textContent="Die MAC-Adresse ist noch unbekannt. Mini-PC einmal normal einschalten – dann merkt sich das Programm sie.";}
}catch(e){}
if(n%10===0)fetch("/wake").catch(()=>{});
if(n>45){document.getElementById("t").textContent="Keine Antwort";document.getElementById("m").textContent="Ist der Mini-PC am Strom und das LAN-Kabel drin? Wake-on-LAN im BIOS an?";return;}
setTimeout(tick,1500);}
fetch("/wake").catch(()=>{});tick();
</script></body></html>
'@

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:8765/")
try { $listener.Start() } catch {
  [Windows.Forms.MessageBox]::Show("Butchies KI läuft schon (Port 8765 belegt).", "Butchies KI") | Out-Null
  $sync.Stop = $true; exit
}
$script:pending = $listener.GetContextAsync()
function Antwort($ctx, $text, $type) {
  $b = [Text.Encoding]::UTF8.GetBytes($text)
  $ctx.Response.ContentType = $type; $ctx.Response.Headers.Add("Cache-Control", "no-store")
  $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
}
function Bearbeite($ctx) {
  $base = $sync.Base
  $wach = $base -and ($sync.State -in @("wach", "arbeitet", "problem", "anmelden"))
  $ui = "$base/"
  switch ($ctx.Request.Url.AbsolutePath) {
    "/wake" { $sync.Queue.Enqueue("wake"); $sync.Fast = $true; Antwort $ctx '{"ok":true}' "application/json" }
    "/status" { Antwort $ctx (@{ awake = $wach; url = $ui; mac = $sync.Mac } | ConvertTo-Json -Compress) "application/json" }
    default {
      if ($wach) { $ctx.Response.Redirect($ui + $ctx.Request.Url.Query); $ctx.Response.Close() }
      else { $sync.Fast = $true; Antwort $ctx $page.Replace("ACCENT", (WindowsDesign).Accent) "text/html; charset=utf-8" }
    }
  }
}

# --- Taskleiste: Menü, Klicks, Zeitgeber -------------------------------------------
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add("Status anzeigen", $null, { ZeigeFenster })
[void]$menu.Items.Add("Oberfläche öffnen", $null, { OeffneOberflaeche })
[void]$menu.Items.Add("Linux-Konsole (SSH)", $null, { OeffneLinuxKonsole })
[void]$menu.Items.Add("GitHub-Updates prüfen", $null, { $sync.Queue.Enqueue("update-check") })
$installUpdate = $menu.Items.Add("Windows-Update installieren", $null, {
  if (-not $sync.WindowsUpdate -or $sync.Updating) { return }
  $sync.Updating = $true
  $sync.Queue.Enqueue("update-install")
})
$installUpdate.Enabled = $false
[void]$menu.Items.Add("Mini-PC aufwecken", $null, { $sync.Queue.Enqueue("wake") })
[void]$menu.Items.Add("-")
[void]$menu.Items.Add("Beenden", $null, { Beenden })
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq "Left") { ZeigeFenster } })

$script:lastVersion = -1
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150
$timer.add_Tick({
  if ($script:pending.IsCompleted) {
    try { Bearbeite $script:pending.Result } catch {}
    try { $script:pending = $listener.GetContextAsync() } catch {}
  }
  if ($sync.Version -ne $script:lastVersion) {
    $script:lastVersion = $sync.Version
    AktualisiereSymbol
    FensterAktualisieren
    if ($sync.Mac -and ($sync.Mac -ne $cfg.mac -or $sync.Ip -ne $cfg.ip)) { $cfg.mac = $sync.Mac; $cfg.ip = $sync.Ip; Speichern }
    if ($sync.AcceptedPassword) { SpeicherePasswort $sync.AcceptedPassword; $sync.AcceptedPassword = "" }
    $installUpdate.Enabled = [bool]$sync.WindowsUpdate -and -not $sync.Updating
    $installUpdate.Text = if ($sync.Updating) { "Windows-Update wird geladen …" }
      elseif ($sync.WindowsUpdate) { "Windows-Update $($sync.WindowsUpdate.version) installieren" }
      else { "Windows-Update installieren" }
    if ($sync.UpdateNotice) {
      $tray.ShowBalloonTip(6500, "Butchies KI · GitHub", $sync.UpdateNotice, "Info")
      $sync.UpdateNotice = ""
    }
    if ($sync.Notify) { $tray.ShowBalloonTip(5000, "Butchies KI", $sync.Notify, "Info"); $sync.Notify = "" }
    if ($sync.Message -and -not $script:win) { $sync.Message = "" }
  }
})
$timer.Start()
AktualisiereSymbol
if ($OpenOnStart) { OeffneOberflaeche }

[Windows.Forms.Application]::Run()
$sync.Stop = $true
try { $ps.EndInvoke($handle) } catch {}
