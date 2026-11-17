# Windows-LAN-Einrichtung fuer den LLM-Stapel (Einmal-Aufruf, PowerShell als Administrator)
#
# Was dieses Skript tut (alles idempotent):
#   1. hosts-Datei um die LAN-Namen des Rechners ergaenzen
#   2. das exportierte Caddy-Root importieren (falls als Datei angegeben)
#   3. jede Route pruefen und das Ergebnis ausgeben
#
# Vorbereitung auf dem Linux-Rechner (liefert beides):
#   ./scripts/74-setup-local-proxy.sh --ca-export      # Root-Datei + Pfade
#   ./scripts/74-setup-local-proxy.sh --print-hosts    # Namen und Adresse
#
# Aufruf auf Windows 11 (PowerShell als Administrator):
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\windows-lan-client-setup.ps1 -LanIp 192.168.0.198 -Domain cachyos-x8664 `
#       -CertPath C:\temp\caddy-local-authority-root.crt
#
# Rueckbau:
#   .\windows-lan-client-setup.ps1 -RemoveOnly              # nur hosts-Eintraege
#   .\windows-lan-client-setup.ps1 -RemoveOnly -RemoveCert  # plus Stammzertifikat
#   (Einzelne Handarbeit: certutil -delstore ROOT "Caddy Local Authority")
#
# Fingerprints vergleichen: --ca-export auf dem Linux-Rechner nennt den
# SHA-256-Fingerprint des Roots. Beim Import kann das Skript ihn erzwingen:
#   .\windows-lan-client-setup.ps1 -CertPath C:\temp\caddy-local-authority-root.crt `
#       -ExpectedThumbprint 'AA:BB:...:FF'
# Bei Abweichung bricht das Skript ab, bevor das Zertifikat importiert wird.

param(
    [string]$LanIp = '192.168.0.198',
    [string]$Domain = 'cachyos-x8664',
    [string]$CertPath = '',
    [string]$ExpectedThumbprint = '',
    [string[]]$RouteNames = @('homepage', 'grafana', 'littlem', 'llm-direct', 'dozzle', 'direct-llm'),
    [switch]$RemoveOnly,
    [switch]$RemoveCert
)

$ErrorActionPreference = 'Stop'
$HostsDatei = "$env:SystemRoot\System32\drivers\etc\hosts"
# Massgeblich ist die Liste auf dem Linux-Rechner: ./scripts/74-setup-local-proxy.sh
# --print-hosts. -RouteNames ueberschreibt die Auswahl hier, falls dort Namen
# geaendert oder ergaenzt wurden.
$Namen = $RouteNames

function Normalize-Thumbprint($Wert) {
    # Doppelpunkte, Leerzeichen und Minus entfernen, gross schreiben - damit
    # 'AA:BB:..' aus openssl x509 -fingerprint und 'AABB..' direkt vergleichbar sind.
    if ($null -eq $Wert) { return '' }
    return (($Wert -replace '[^0-9A-Fa-f]', '')).ToUpperInvariant()
}

function Get-CertSha256($Path) {
    # SHA-256-Fingerprint ueber die DER-Kodierung (RawData) - derselbe Wert, den
    # auf dem Linux-Rechner "openssl x509 -noout -fingerprint -sha256" ausgibt.
    # Der certutil-dump-Text ist auf deutschen Windows-Versionen anders betitelt,
    # deshalb vergleichen wir selbst und verlassen uns nicht auf certutil-Ausgaben.
    if (-not (Test-Path $Path)) { return '' }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $Path
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash($cert.RawData) | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Test-IPv4($Wert) {
    if ($Wert -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($t in ($Wert -split '\.')) { if ([int]$t -gt 255) { return $false } }
    return $true
}

function Write-Schritt($Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok($Text)      { Write-Host "    OK   $Text" -ForegroundColor Green }
function Write-Fehl($Text)    { Write-Host "    FEHLT $Text" -ForegroundColor Red }

# --- Administrator pruefen: hosts-Datei und Stammzertifikat brauchen Rechte ---
$IstAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IstAdmin) {
    Write-Fehl 'Diese PowerShell ist nicht als Administrator geoeffnet. Die hosts-Datei und das Stammzertifikat brauchen Rechte.'
    exit 1
}

# --- Parameter pruefen: die Werte steuern eine Umbenennung in der hosts-Datei ---
# Der Domain-Filter wird als regularer Ausdruck benutzt. Ohne Beschraenkung
# koennte ein Wert wie '.*' fremde Zeilen loeschen - deshalb nur Namenszeichen zu.
if (-not (Test-IPv4 $LanIp)) {
    Write-Fehl "Ungueltige -LanIp '$LanIp'. Erwartet eine IPv4 wie 192.168.0.198 (Ausgabe: ./scripts/74-setup-local-proxy.sh --print-hosts)"
    exit 1
}
if ($Domain -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$') {
    Write-Fehl "Ungueltige -Domain '$Domain'. Erlaubt sind Rechnernamen aus Buchstaben, Ziffern, Bindestrichen und Punkten (Ausgabe: --print-hosts)"
    exit 1
}

# --- Rueckbau ---
if ($RemoveCert) {
    Write-Schritt 'Rueckbau: Caddy-Stammzertifikat aus dem Computerspeicher entfernen'
    # erst pruefen, dann loeschen - certutil liefert beim Loeschen eines
    # nicht vorhandenen Eintrags Fehlercodes, die wir nicht im Einzelnen kennen
    certutil -store ROOT 'Caddy Local Authority' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Ok 'Stammzertifikat war nicht im Speicher'
    } else {
        certutil -delstore ROOT 'Caddy Local Authority' | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'Stammzertifikat entfernt'
        } else {
            Write-Fehl "certutil -delstore meldete $LASTEXITCODE - von Hand nachlesen: certutil -store ROOT 'Caddy Local Authority'"
        }
    }
}
if ($RemoveOnly -or $RemoveCert) {
    if (-not $RemoveOnly) {
        # Nur -RemoveCert: Zertifikat ist weg, aber nichts neu schreiben oder pruefen.
        Write-Host '    Weiter: ./scripts/74-setup-local-proxy.sh --check (Linux-Rechner)' -ForegroundColor Cyan
        exit 0
    }
    Write-Schritt 'Rueckbau: Eintraege dieses Rechners aus der hosts-Datei entfernen'
    $alt = Get-Content $HostsDatei -Encoding ascii
    $neu = $alt | Where-Object { $_ -notmatch "\.$([regex]::Escape($Domain))\b" }
    Set-Content -Path $HostsDatei -Value $neu -Encoding ascii
    Write-Ok "$($alt.Count - $neu.Count) Zeile(n) entfernt"
    ipconfig /flushdns | Out-Null
    if (-not $RemoveCert) {
        Write-Host '    HINWEIS: Das Stammzertifikat bleibt im Computerspeicher. Mit -RemoveCert -RemoveOnly ist auch es weg.' -ForegroundColor Yellow
    }
    exit 0
}

# --- 1) hosts-Datei ---
Write-Schritt "hosts-Datei: $LanIp -> $($Namen -join ', ').$Domain"
$zeile = "$LanIp " + (($Namen | ForEach-Object { "$_.$Domain" }) -join ' ')
$DomainEsc = [regex]::Escape($Domain)
$alt = Get-Content $HostsDatei -Encoding ascii
if (($alt | Where-Object { $_ -match "\.$DomainEsc\b" }) -join "`n" -eq $zeile) {
    Write-Ok 'Eintrag ist bereits vorhanden'
} else {
    $ohneFremde = $alt | Where-Object { $_ -notmatch "\.$DomainEsc\b" }
    Set-Content -Path $HostsDatei -Value ($ohneFremde + $zeile) -Encoding ascii
    Write-Ok 'Eintrag geschrieben'
}
ipconfig /flushdns | Out-Null

# --- 2) Stammzertifikat ---
if ($CertPath -ne '') {
    if (-not (Test-Path $CertPath)) {
        Write-Fehl "Zertifikatsdatei nicht gefunden: $CertPath  (vom Linux-Rechner mit --ca-export holen)"
        exit 1
    }
    Write-Schritt 'Stammzertifikat importieren (Lokaler Computer / Vertrauenswuerdige Stammzertifizierungsstellen)'
    # Fingerprint selbst bestimmen (SHA-256 ueber DER) und ausgeben. Der Wert muss
    # dem aus "openssl x509 -in caddy-local-authority-root.crt -noout -fingerprint
    # -sha256" auf dem Linux-Rechner gleichen - nur dann wurde die Datei unveraendert
    # und vom richtigen Rechner uebertragen.
    $sha256 = Get-CertSha256 $CertPath
    if ($sha256 -eq '') {
        Write-Fehl "Zertifikat nicht lesbar: $CertPath (PEM aus --ca-export erwartet)"
        exit 1
    }
    Write-Host "    SHA-256-Fingerprint: $($sha256 -replace '(..)(?=[0-9A-F])', '$1:')"
    if ($ExpectedThumbprint -ne '') {
        if ((Normalize-Thumbprint $sha256) -ne (Normalize-Thumbprint $ExpectedThumbprint)) {
            Write-Fehl 'Fingerprint weicht von -ExpectedThumbprint ab - die Datei stammt nicht von diesem Rechner (oder wurde veraendert). Nichts importiert.'
            Write-Host '    Nachfragen auf dem Linux-Rechner: openssl x509 -in ~/.local/share/llm-infra/caddy/ca/caddy-local-authority-root.crt -noout -fingerprint -sha256' -ForegroundColor Yellow
            exit 1
        }
        Write-Ok 'Fingerprint stimmt mit dem erwartetem Wert ueberein'
    } else {
        Write-Host '    HINWEIS: ohne -ExpectedThumbprint ist der Wert nur angezeigt, nicht geprueft.' -ForegroundColor Yellow
        Write-Host "    Vergleiche ihn mit dem Linux-Rechner, dann erneut aufrufen mit:" -ForegroundColor Yellow
        Write-Host "    .\windows-lan-client-setup.ps1 -LanIp $LanIp -Domain $Domain -CertPath $CertPath -ExpectedThumbprint '<Fingerprint von dort>'" -ForegroundColor Yellow
    }
    certutil -addstore -f ROOT $CertPath | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'Root importiert' } else { Write-Fehl "certutil meldete $LASTEXITCODE" }
} else {
    Write-Host '    HINWEIS: kein -CertPath angegeben - Zertifikatspruefungen schlagen dann mit TLS-Fehler fehl.' -ForegroundColor Yellow
}

# --- 3) Pruefen, wie ein normaler Client ---
Write-Schritt 'Routen pruefen'
$Erwartet = @{
    'homepage'            = @{ Pfad = '/';                Erwartet = 200 }
    'grafana'             = @{ Pfad = '/grafana/';        Erwartet = 200 }
    'littlem'             = @{ Pfad = '/v1/models';       Erwartet = 401 }
    'llm-direct'          = @{ Pfad = '/v1/models';       Erwartet = 401 }
    'dozzle'              = @{ Pfad = '/';                Erwartet = 401 }
    'direct-llm'          = @{ Pfad = '/v1/models';       Erwartet = 200 }
}
foreach ($Name in $Namen) {
    if (-not $Erwartet.ContainsKey($Name)) {
        Write-Host "    UEBERSPRUNGEN $Name - keine erwartete Antwort hinterlegt (Route in -RouteNames ergaenzen oder in \$Erwartet nachtragen)" -ForegroundColor Yellow
        continue
    }
    $url = "https://$Name.$Domain$($Erwartet[$Name].Pfad)"
    try {
        $antwort = Invoke-WebRequest -Uri $url -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
        $code = $antwort.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        else { $code = 0 }
    }
    if ($code -eq $Erwartet[$Name].Erwartet) {
        Write-Ok "$Name : $code (wie erwartet)"
    } else {
        Write-Fehl "$Name : $code statt $($Erwartet[$Name].Erwartet) - URL $url"
    }
}

Write-Schritt 'Grundseite des Portals (Zeigt der Browser denselben Titel, ist der Weg durch)'
try {
    $start = Invoke-WebRequest -Uri "https://homepage.$Domain/" -UseBasicParsing -ErrorAction Stop
    if ($start.Content -match '<title[^>]*>([^<]+)</title>') {
        Write-Ok "Titel der Startseite: $($Matches[1].Trim())"
    }
} catch {
    Write-Fehl "Startseite nicht erreichbar: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'Weiter auf dem Linux-Rechner: ./scripts/74-setup-local-proxy.sh --check' -ForegroundColor Cyan
Write-Host 'Dozzle-Zugangsdaten (einzige Basic-Auth-Route): cat ~/.config/llm-infra/proxy/lan-credentials.txt' -ForegroundColor Cyan
